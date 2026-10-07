"""GPU-independent validation and cropped RGBA mask serialization."""
import base64
import io
import warnings

import numpy as np
from PIL import Image, ImageDraw, UnidentifiedImageError
from scipy.ndimage import binary_erosion, binary_fill_holes

MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_IMAGE_EDGE = 1600
MAX_PLATES = 12
MIN_DISH_AREA = 0.01
MIN_FOOD_COVERAGE = 0.01
MIN_FOOD_CONTAINMENT = 0.5
# Corner-clipped dishes can contain real food yet be incidental to the photo.
MAX_CORNER_DISH_AREA = 0.12
MAX_CORNER_DISH_RELATIVE_AREA = 0.25


def dish_silhouette(mask):
    """Retain food inside a dish, including rims cut off at the photo edge.

    Plate/bowl prompts can identify only exposed ceramic. Fill enclosed holes
    without changing the outer edge. For sparse/open rims, use the convex dish
    envelope as a fallback; this stays within the observed mask's bounds.
    This is for automatic dish detection, never user-edited alpha masks.
    """
    mask = np.asarray(mask, dtype=bool)
    bounds = _mask_bounds(mask)
    if bounds is None:
        return mask.copy()
    return _dish_silhouette_from_bounds(mask, bounds)


def _mask_bounds(mask):
    # Reductions avoid allocating an (x, y) pair for every foreground pixel.
    rows = np.flatnonzero(mask.any(axis=1))
    if not rows.size:
        return None
    columns = np.flatnonzero(mask.any(axis=0))
    return int(rows[0]), int(rows[-1]) + 1, int(columns[0]), int(columns[-1]) + 1


def _dish_silhouette_from_bounds(mask, bounds):
    top, bottom, left, right = bounds
    result = np.zeros_like(mask)
    result[top:bottom, left:right] = _complete_dish_crop(mask[top:bottom, left:right])
    return result


def _complete_dish_crop(mask):
    # Work within the dish bounds: flood filling the whole photograph for
    # every candidate wastes time on large areas of unrelated background.
    height, width = mask.shape
    # Compiled flood propagation replaces Pillow's Python per-pixel traversal.
    # Default four-neighbour connectivity matches the previous flood fill,
    # including one-pixel rims and holes that touch the exterior diagonally.
    filled = binary_fill_holes(mask)

    # Row extrema suffice to construct the convex hull; avoid sorting millions
    # of interior pixels for a full-resolution photograph.
    rows = np.flatnonzero(mask.any(axis=1))
    left_edges = mask.argmax(axis=1)
    right_edges = width - 1 - mask[:, ::-1].argmax(axis=1)
    points = sorted({(int(x), int(y)) for y in rows for x in (
        left_edges[y], right_edges[y],
    )})

    def cross(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    def half(sequence):
        result = []
        for point in sequence:
            while len(result) >= 2 and cross(result[-2], result[-1], point) <= 0:
                result.pop()
            result.append(point)
        return result

    hull = half(points)[:-1] + half(reversed(points))[:-1]
    if len(hull) < 3:
        return filled
    envelope = Image.new("L", (width, height))
    ImageDraw.Draw(envelope).polygon(hull, fill=255)
    convex = np.asarray(envelope) != 0
    if filled.sum() < 0.85 * convex.sum():
        return convex | filled
    return filled


def prepare_dish_candidates(candidates, width, height, food_candidates=None):
    """Keep substantial dishes supported by food inside their completed outline.

    None preserves geometry-only cleanup for callers without food inference.
    The GPU worker always supplies food candidates, including an empty list;
    no food evidence must never fall back to accepting empty dishes.
    """
    foods = None
    if food_candidates is not None:
        foods = []
        for mask, score in food_candidates:
            mask = np.asarray(mask, dtype=bool)
            if mask.shape != (height, width) or not np.isfinite(score):
                raise ValueError("Model mask dimensions do not match the image")
            if score >= 0.5 and mask.any():
                foods.append((mask, int(mask.sum())))
    completed = []
    for mask, score in candidates:
        mask = np.asarray(mask, dtype=bool)
        if mask.shape != (height, width) or not np.isfinite(score):
            raise ValueError("Model mask dimensions do not match the image")
        if score < 0.5:
            continue
        bounds = _mask_bounds(mask)
        if bounds is None:
            continue
        top, bottom, left, right = bounds
        if (right - left) * (bottom - top) < width * height * MIN_DISH_AREA:
            continue
        # Do not turn a sliver at the photo border into a completed dish.
        touches_edge = left == 0 or top == 0 or right == width or bottom == height
        if touches_edge and min(right - left, bottom - top) < 0.12 * max(
                right - left, bottom - top):
            continue
        silhouette = _dish_silhouette_from_bounds(mask, bounds)
        # A screenshot's gallery thumbnails otherwise become extra dishes.
        # Measure the complete dish, so thin rims of large plates survive.
        if silhouette.sum() < width * height * MIN_DISH_AREA:
            continue
        if foods is not None:
            # Food must be inside the dish, rather than merely touching a rim.
            # Erode only the crop; edge-clipped, food-filled dishes still survive.
            crop = silhouette[top:bottom, left:right]
            inset = max(1, min(8, round(min(crop.shape) * 0.01)))
            interior = binary_erosion(crop, iterations=inset)
            interior_area = int(interior.sum())
            supported = any(
                (overlap := int(np.count_nonzero(
                    interior & food[top:bottom, left:right])))
                >= max(1, interior_area * MIN_FOOD_COVERAGE)
                and overlap >= food_area * MIN_FOOD_CONTAINMENT
                for food, food_area in foods
            )
            if not supported:
                continue
        completed.append((silhouette, score))
    return completed


def prepare_serving_boards(candidates, width, height, food_candidates, vessels):
    """A board may group bowls only if food is also served directly on it.

    A wooden table falsely matching the board prompt must not be promoted
    merely because it surrounds food-filled bowls. Favor separate bowls when
    all food evidence is contained in vessels.
    """
    covered = np.zeros((height, width), bool)
    for vessel, _ in vessels:
        covered |= vessel
    direct_food = []
    for mask, score in food_candidates:
        mask = np.asarray(mask, dtype=bool)
        if mask.shape != (height, width) or not np.isfinite(score):
            raise ValueError("Model mask dimensions do not match the image")
        area = int(mask.sum())
        if score >= 0.5 and area:
            exposed = mask & ~covered
            if exposed.sum() >= area * 0.5:
                direct_food.append((exposed, score))
    return prepare_dish_candidates(candidates, width, height, food_candidates=direct_food)


def group_serving_boards(dishes, boards, components):
    """Keep each food-bearing board and its contents as a single serving.

    Association uses the original completed board, never a growing union, so
    nearby dishes cannot pull unrelated dishes into the serving. Components
    may include condiment bowls omitted by standalone food filtering.
    """
    grouped = []
    assigned = set()
    for board, score in sorted(boards, key=lambda item: item[1], reverse=True):
        # Board prompts can produce duplicates too; avoid two copies of a meal.
        if any(np.count_nonzero(board & other) / np.count_nonzero(board | other)
               > 0.7 for other, _ in grouped):
            continue
        outline = board.copy()
        board_area = int(board.sum())
        for component, _ in components:
            area = int(component.sum())
            if 0 < area <= board_area * 0.8 and np.count_nonzero(
                    component & board) >= area * 0.6:
                # Keep bowls/food protruding over the edge; never convex-fill
                # the combined serving, which would capture the table between.
                outline |= component
        for index, (dish, _) in enumerate(dishes):
            area = int(dish.sum())
            if area and np.count_nonzero(dish & board) >= area * 0.6:
                outline |= dish
                assigned.add(index)
        grouped.append((outline, score))
    return grouped + [dish for index, dish in enumerate(dishes) if index not in assigned]


def open_photo(data):
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ValueError("Invalid image size")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as photo:
                if max(photo.size) > MAX_IMAGE_EDGE or photo.n_frames != 1:
                    raise ValueError("Image must be a single frame up to 1600 pixels")
                return photo.convert("RGB")
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError,
            Image.DecompressionBombWarning) as error:
        raise ValueError("Image could not be decoded") from error


def encode_plates(candidates, width, height):
    """Bounds come from occupied mask pixels. Suppress cross-prompt mask IoU duplicates."""
    plates, selected = [], []
    valid = []
    for mask, score in candidates:
        mask = np.asarray(mask, dtype=bool)
        if mask.shape != (height, width) or not np.isfinite(score):
            raise ValueError("Model mask dimensions do not match the image")
        if score < 0.5 or not mask.any():
            continue
        valid.append((mask, score, int(mask.sum())))
    # Apply after board grouping so the whole serving defines the main subject.
    # Fully visible sides, single-edge dishes, and large clipped meals survive.
    largest_area = max((area for _, _, area in valid), default=0)
    retained = []
    edge_x, edge_y = max(1, round(width * 0.003)), max(1, round(height * 0.003))
    for mask, score, area in valid:
        top, bottom, left, right = _mask_bounds(mask)
        corner_clipped = ((left <= edge_x or right >= width - edge_x)
                          and (top <= edge_y or bottom >= height - edge_y))
        if (corner_clipped and area <= width * height * MAX_CORNER_DISH_AREA
                and area <= largest_area * MAX_CORNER_DISH_RELATIVE_AREA):
            continue
        retained.append((mask, score, area))
    valid = retained
    # IoU alone misses a high-confidence rim fragment inside a full dish.
    # Prefer the full dish regardless of fragment confidence. The area ratio
    # keeps similarly sized, overlapping dishes out of this containment rule.
    valid = [(mask, score, area) for mask, score, area in valid
             if not any(other_area >= area * 2
                        and np.count_nonzero(mask & other) >= area * 0.9
                        for other, _, other_area in valid)]
    for mask, score, _ in sorted(valid, key=lambda item: item[1], reverse=True):
        if any(np.count_nonzero(mask & other) / np.count_nonzero(mask | other)
               > 0.7 for other in selected):
            continue
        ys, xs = np.nonzero(mask)
        left, top = int(xs.min()), int(ys.min())
        right, bottom = int(xs.max()) + 1, int(ys.max()) + 1
        alpha = Image.fromarray(mask[top:bottom, left:right].astype(np.uint8) * 255)
        rgba = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
        rgba.putalpha(alpha)
        rgba.thumbnail((768, 768), Image.Resampling.LANCZOS)
        output = io.BytesIO()
        rgba.save(output, format="PNG")
        plates.append({
            "bounds": [left / width, top / height,
                       (right - left) / width, (bottom - top) / height],
            "mask": base64.b64encode(output.getvalue()).decode("ascii"),
            "score": float(score),
        })
        selected.append(mask)
        if len(plates) == MAX_PLATES:
            break
    return {"version": 1, "model": "sam3", "maskFormat": "cropped-rgba",
            "imageSize": [width, height], "plates": plates}
