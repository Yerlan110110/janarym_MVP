from pathlib import Path

from ultralytics import YOLO

MODEL_PATH = Path(__file__).with_name("yolov8n.pt")

model = YOLO(str(MODEL_PATH))
model.export(format='tflite', imgsz=640)
