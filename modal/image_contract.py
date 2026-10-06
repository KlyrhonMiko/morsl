"""GPU-independent validation and cropped RGBA mask serialization."""
import base64
import io
import warnings

import numpy as np
from PIL import Image, ImageDraw, UnidentifiedImageError
from scipy.ndimage import binary_fill_holes

MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_IMAGE_EDGE = 1600
MAX_PLATES = 12
MIN_DISH_AREA = 0.01


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


def prepare_dish_candidates(candidates, width, height):
    """Complete silhouettes before deduplication and discard tiny detections."""
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
        silhouette = _dish_silhouette_from_bounds(mask, bounds)
        # A screenshot's gallery thumbnails otherwise become extra dishes.
        # Measure the complete dish, so thin rims of large plates survive.
        if silhouette.sum() < width * height * MIN_DISH_AREA:
            continue
        completed.append((silhouette, score))
    return completed


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
    for mask, score in sorted(candidates, key=lambda item: item[1], reverse=True):
        mask = np.asarray(mask, dtype=bool)
        if mask.shape != (height, width) or not np.isfinite(score):
            raise ValueError("Model mask dimensions do not match the image")
        if score < 0.5 or not mask.any():
            continue
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
