import io

from flask import Flask, jsonify, request
from PIL import Image
from ultralytics import YOLO

app = Flask(__name__)
model = YOLO("yolov8n.pt")


@app.get("/health")
def health():
    return jsonify({"ok": True})


@app.post("/detect")
def detect():
    image_file = request.files.get("image")
    if image_file is None:
        return jsonify({"error": "missing image file field"}), 400

    conf = float(request.form.get("conf", "0.5"))
    imgsz = int(request.form.get("imgsz", "320"))

    img_bytes = image_file.read()
    if not img_bytes:
        return jsonify({"detections": []})

    img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
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
