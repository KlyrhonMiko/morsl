"""GPU-independent validation and cropped RGBA mask serialization."""
import base64
import io
import warnings

import numpy as np
from PIL import Image, UnidentifiedImageError

MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_IMAGE_EDGE = 1600
MAX_PLATES = 12


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
