import io
from pathlib import Path

from flask import Flask, jsonify, request
from PIL import Image, UnidentifiedImageError
from ultralytics import YOLO

app = Flask(__name__)
MODEL_PATH = Path(__file__).with_name("yolov8n.pt")
model = YOLO(str(MODEL_PATH))


def _parse_conf(raw_value: str) -> float:
    try:
        value = float(raw_value)
    except (TypeError, ValueError) as exc:
        raise ValueError("conf must be a number between 0 and 1") from exc
    if not 0.0 <= value <= 1.0:
        raise ValueError("conf must be between 0 and 1")
    return value


def _parse_imgsz(raw_value: str) -> int:
    try:
        value = int(raw_value)
    except (TypeError, ValueError) as exc:
        raise ValueError("imgsz must be an integer between 32 and 2048") from exc
    if not 32 <= value <= 2048:
        raise ValueError("imgsz must be between 32 and 2048")
    return value


@app.get("/health")
def health():
    return jsonify({"ok": True})


@app.post("/detect")
def detect():
    image_file = request.files.get("image")
    if image_file is None:
        return jsonify({"error": "missing image file field"}), 400

    try:
        conf = _parse_conf(request.form.get("conf", "0.5"))
        imgsz = _parse_imgsz(request.form.get("imgsz", "320"))
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    img_bytes = image_file.read()
    if not img_bytes:
        return jsonify({"detections": []})

    try:
        img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    except (UnidentifiedImageError, OSError):
        return jsonify({"error": "image must be a valid image file"}), 400
    results = model(img, imgsz=imgsz, conf=conf)

    detections = []
    for result in results:
        names = result.names
        for box in result.boxes:
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            detections.append(
                {
                    "class": names[int(box.cls[0])],
                    "confidence": float(box.conf[0]),
                    "bbox": {
                        "x": float(x1),
                        "y": float(y1),
                        "w": float(x2 - x1),
                        "h": float(y2 - y1),
                    },
                }
            )

    return jsonify({"detections": detections})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8090, debug=False)
