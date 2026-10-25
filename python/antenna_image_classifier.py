"""Trainable antenna-image classifier used by the local dashboard bridge.

The artifact is deliberately local. The repository contains no labeled antenna
photos, so the classifier reports NOT TRAINED until the owner supplies images
in data/antenna_images/<antenna_type>/ and runs the training CLI.
"""
from __future__ import annotations

import io
import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATASET_DIR = ROOT / "data" / "antenna_images"
MODEL_DIR = ROOT / "data" / "models"
MODEL_PATH = MODEL_DIR / "antenna_image_classifier.joblib"
METADATA_PATH = MODEL_DIR / "antenna_image_classifier.json"
IMAGE_SIZE = (96, 96)
MAX_IMAGE_BYTES = 12 * 1024 * 1024
MODEL_NAME = "HOG + RBF-SVM antenna topology classifier"
_LOCK = threading.Lock()
_CACHE = {"mtime": None, "artifact": None}


def _vision_imports():
    try:
        import numpy as np
        from PIL import Image, ImageOps
    except ImportError as exc:
        raise RuntimeError("Image AI dependencies are missing. Install python/requirements.txt (Pillow, NumPy, scikit-learn, joblib).") from exc
    return np, Image, ImageOps


def image_features(image_bytes: bytes):
    """Convert any Pillow-decodable image into a compact HOG-like descriptor."""
    if not image_bytes or len(image_bytes) > MAX_IMAGE_BYTES:
        raise ValueError("Image is empty or larger than 12 MB.")
    np, Image, ImageOps = _vision_imports()
    try:
        image = Image.open(io.BytesIO(image_bytes)).convert("L")
        original_size = image.size
        image = ImageOps.fit(image, IMAGE_SIZE, method=Image.Resampling.LANCZOS)
        gray = np.asarray(image, dtype=np.float32) / 255.0
    except Exception as exc:
        raise ValueError(f"Unsupported or invalid image: {exc}") from exc

    # Gradients, unsigned orientations, 9-bin histograms in 8x8-pixel cells.
    gx = np.zeros_like(gray)
    gy = np.zeros_like(gray)
    gx[:, 1:-1] = gray[:, 2:] - gray[:, :-2]
    gy[1:-1, :] = gray[2:, :] - gray[:-2, :]
    magnitude = np.sqrt(gx * gx + gy * gy)
    angle = (np.degrees(np.arctan2(gy, gx)) + 180.0) % 180.0
    bins = 9
    cell = 8
    cell_hist = np.zeros((IMAGE_SIZE[0] // cell, IMAGE_SIZE[1] // cell, bins), dtype=np.float32)
    for cy in range(cell_hist.shape[0]):
        for cx in range(cell_hist.shape[1]):
            ys = slice(cy * cell, (cy + 1) * cell)
            xs = slice(cx * cell, (cx + 1) * cell)
            hist, _ = np.histogram(angle[ys, xs], bins=bins, range=(0, 180), weights=magnitude[ys, xs])
            cell_hist[cy, cx] = hist
    blocks = []
    for y in range(cell_hist.shape[0] - 1):
        for x in range(cell_hist.shape[1] - 1):
            block = cell_hist[y:y + 2, x:x + 2].ravel()
            blocks.extend(block / (np.linalg.norm(block) + 1e-6))
    # Add low-resolution grayscale appearance and aspect ratio to preserve broad geometry cues.
    coarse = gray.reshape(12, 8, 12, 8).mean(axis=(1, 3)).ravel()
    aspect = np.asarray([original_size[0] / max(original_size[1], 1)], dtype=np.float32)
    return np.concatenate((np.asarray(blocks, dtype=np.float32), coarse, aspect))


def dataset_counts() -> dict:
    counts = {}
    if DATASET_DIR.is_dir():
        for folder in DATASET_DIR.iterdir():
            if folder.is_dir():
                counts[folder.name] = sum(1 for p in folder.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"})
    return {k: v for k, v in sorted(counts.items()) if v}


def model_status() -> dict:
    """Return model readiness without loading/unpickling the artifact."""
    metadata = {}
    try:
        metadata = json.loads(METADATA_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    ready = MODEL_PATH.is_file() and bool(metadata.get("trained_at"))
    counts = dataset_counts()
    return {
        "ready": ready,
        "model_name": metadata.get("model_name", MODEL_NAME),
        "trained_at": metadata.get("trained_at"),
        "classes": metadata.get("classes", []),
        "image_count": metadata.get("image_count", 0),
        "test_accuracy": metadata.get("test_accuracy"),
        "dataset_dir": "data/antenna_images", 
        "class_counts": counts,
        "labeled_image_count": sum(counts.values()),
        "minimum_per_class": 5,
        "training_command": "python python/train_antenna_image_classifier.py --dataset data/antenna_images",
        "message": "Trained image model ready." if ready else "No trained image model yet. Add labeled antenna images and run the training command.",
    }


def _load_artifact():
    if not MODEL_PATH.is_file():
        raise RuntimeError("Antenna image model is not trained yet. Add labeled images under data/antenna_images/<type>/ and run python python/train_antenna_image_classifier.py.")
    try:
        import joblib
    except ImportError as exc:
        raise RuntimeError("joblib is missing; install python/requirements.txt.") from exc
    mtime = MODEL_PATH.stat().st_mtime
    with _LOCK:
        if _CACHE["artifact"] is None or _CACHE["mtime"] != mtime:
            _CACHE["artifact"] = joblib.load(MODEL_PATH)
            _CACHE["mtime"] = mtime
        return _CACHE["artifact"]


def classify_image(image_bytes: bytes) -> dict:
    artifact = _load_artifact()
    features = image_features(image_bytes).reshape(1, -1)
    classifier = artifact["classifier"]
    probabilities = classifier.predict_proba(features)[0]
    order = probabilities.argsort()[::-1]
    top = [{"type": str(artifact["classes"][i]), "probability": float(probabilities[i])} for i in order[:3]]
    return {
        "ready": True,
        "model_name": artifact.get("model_name", MODEL_NAME),
        "predicted_type": top[0]["type"],
        "confidence": top[0]["probability"],
        "top_predictions": top,
        "test_accuracy": artifact.get("test_accuracy"),
        "image_count": artifact.get("image_count", 0),
        "trained_at": artifact.get("trained_at"),
        "warning": "Prediction quality depends on representative, correctly labeled training images. Confirm this result before relying on it.",
    }


def save_labeled_image(image_bytes: bytes, label: str) -> dict:
    """Validate and store a user-confirmed labeled example in the local dataset."""
    label = str(label or "").strip().lower()
    if not label or len(label) > 48 or not all(c.isalnum() or c in "-_ " for c in label):
        raise ValueError("Label must contain only letters, digits, spaces, hyphens, or underscores.")
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise ValueError("Image is larger than 12 MB.")
    np, Image, _ = _vision_imports()
    del np
    try:
        with Image.open(io.BytesIO(image_bytes)) as im:
            im.verify()
        with Image.open(io.BytesIO(image_bytes)) as im:
            canonical = im.convert("RGB")
            label_dir = DATASET_DIR / label.replace(" ", "_")
            label_dir.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            path = label_dir / f"{stamp}.jpg"
            canonical.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
            canonical.save(path, format="JPEG", quality=92, optimize=True)
    except Exception as exc:
        raise ValueError(f"Could not decode/save image: {exc}") from exc
    count = sum(1 for p in label_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp", ".bmp"})
    counts = dataset_counts()
    return {"saved": True, "label": label_dir.name, "examples_for_label": count, "class_counts": counts, "dataset_dir": "data/antenna_images"}
