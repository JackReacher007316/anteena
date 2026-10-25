#!/usr/bin/env python3
"""Train the local antenna topology image classifier from labeled folders.

Dataset layout:
  data/antenna_images/patch/image_001.jpg
  data/antenna_images/yagi/image_001.png
  data/antenna_images/helix/image_001.jpg

Use real antenna design images, diagrams, or photos; each class needs at least
five examples. More varied examples (different views/backgrounds) are needed for
reliable results. The saved model stays local in data/models/.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"}


def load_examples(dataset: Path):
    try:
        import numpy as np
        from antenna_image_classifier import image_features
    except ImportError as exc:
        raise SystemExit("Missing image dependencies. Install: pip install -r python/requirements.txt") from exc
    features, labels, skipped = [], [], []
    for folder in sorted(p for p in dataset.iterdir() if p.is_dir()):
        label = folder.name.replace("_", " ").strip()
        if not label:
            continue
        for path in sorted(folder.iterdir()):
            if path.suffix.lower() not in IMAGE_EXTENSIONS:
                continue
            try:
                features.append(image_features(path.read_bytes()))
                labels.append(label)
            except (OSError, ValueError, RuntimeError) as exc:
                skipped.append(f"{path}: {exc}")
    if not features:
        raise SystemExit(f"No readable images found under {dataset}/<antenna_type>/.")
    return np.asarray(features, dtype=np.float32), labels, skipped


def train(dataset: Path, output_dir: Path):
    try:
        import joblib
        from sklearn.calibration import CalibratedClassifierCV
        from sklearn.metrics import accuracy_score, classification_report, confusion_matrix
        from sklearn.model_selection import train_test_split
        from sklearn.pipeline import make_pipeline
        from sklearn.preprocessing import StandardScaler
        from sklearn.svm import SVC
    except ImportError as exc:
        raise SystemExit("Missing ML dependencies. Install: pip install -r python/requirements.txt") from exc

    X, y, skipped = load_examples(dataset)
    counts = Counter(y)
    insufficient = {label: count for label, count in counts.items() if count < 5}
    if insufficient:
        listing = ", ".join(f"{k}={v}" for k, v in sorted(insufficient.items()))
        raise SystemExit(f"Need at least 5 labeled images per class; currently: {listing}")
    if len(counts) < 2:
        raise SystemExit("Need at least two antenna-type folders to train a classifier.")

    test_count = max(len(counts), math.ceil(len(y) * 0.2))
    if test_count >= len(y) - len(counts):
        test_count = len(counts)
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=test_count, random_state=42, stratify=y
    )
    classifier = make_pipeline(
        StandardScaler(),
        CalibratedClassifierCV(
            SVC(C=4.0, kernel="rbf", gamma="scale", class_weight="balanced", random_state=42),
            method="sigmoid", cv=3,
        ),
    )
    classifier.fit(X_train, y_train)
    predictions = classifier.predict(X_test)
    accuracy = float(accuracy_score(y_test, predictions))
    labels = sorted(counts)
    report = classification_report(y_test, predictions, labels=labels, output_dict=True, zero_division=0)
    matrix = confusion_matrix(y_test, predictions, labels=labels).tolist()
    trained_at = datetime.now(timezone.utc).isoformat()
    artifact = {
        "classifier": classifier,
        "classes": labels,
        "model_name": "HOG image features + RBF-SVM",
        "trained_at": trained_at,
        "image_count": len(y),
        "class_counts": dict(counts),
        "test_accuracy": accuracy,
        "test_report": report,
        "confusion_labels": labels,
        "confusion_matrix": matrix,
        "feature_type": "96x96 grayscale HOG + coarse luminance + aspect ratio",
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    model_path = output_dir / "antenna_image_classifier.joblib"
    metadata_path = output_dir / "antenna_image_classifier.json"
    joblib.dump(artifact, model_path)
    metadata = {k: v for k, v in artifact.items() if k != "classifier"}
    metadata["dataset_dir"] = str(dataset.resolve())
    metadata["model_file"] = model_path.name
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    print(f"Trained model: {model_path}")
    print(f"Images: {len(y)} across {len(labels)} classes")
    print(f"Holdout accuracy: {accuracy:.3f} (holdout has {len(y_test)} images)")
    print("Classes: " + ", ".join(f"{k} ({counts[k]})" for k in labels))
    print("Confusion matrix labels: " + ", ".join(labels))
    print(json.dumps(matrix))
    if skipped:
        print(f"Skipped {len(skipped)} unreadable files:")
        for item in skipped[:20]:
            print(" - " + item)
    print("IMPORTANT: holdout accuracy is a small-dataset estimate, not a guarantee on new camera images.")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=ROOT / "data" / "antenna_images")
    parser.add_argument("--output", type=Path, default=ROOT / "data" / "models")
    args = parser.parse_args()
    train(args.dataset, args.output)


if __name__ == "__main__":
    main()
