import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class CameraFrameSnapshot {
  const CameraFrameSnapshot({
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.nv21Bytes,
  });

  final int width;
  final int height;
  final int rotationDegrees;
  final Uint8List nv21Bytes;

  Uint8List get lumaBytes =>
      Uint8List.sublistView(nv21Bytes, 0, width * height);

  Map<String, Object> toJpegPayload() => <String, Object>{
    'width': width,
    'height': height,
    'nv21': nv21Bytes,
  };
}

class CameraFrameStore {
  CameraFrameSnapshot? update(
    CameraImage image, {
    required int rotationDegrees,
  }) {
    if (image.planes.length < 3) return null;
    final width = image.width;
    final height = image.height;
    final frameSize = width * height;
    final chromaSize = frameSize ~/ 2;
    final nv21 = Uint8List(frameSize + chromaSize);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    var yOffset = 0;
    for (var row = 0; row < height; row++) {
      final srcOffset = row * yPlane.bytesPerRow;
      nv21.setRange(yOffset, yOffset + width, yPlane.bytes, srcOffset);
      yOffset += width;
    }

    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final chromaHeight = height ~/ 2;
    final chromaWidth = width ~/ 2;
    var uvOffset = frameSize;
    for (var row = 0; row < chromaHeight; row++) {
      final uRowOffset = row * uPlane.bytesPerRow;
      final vRowOffset = row * vPlane.bytesPerRow;
      for (var col = 0; col < chromaWidth; col++) {
        final uvIndex = col * uvPixelStride;
        nv21[uvOffset++] = vPlane.bytes[vRowOffset + uvIndex];
        nv21[uvOffset++] = uPlane.bytes[uRowOffset + uvIndex];
      }
    }

    return CameraFrameSnapshot(
      width: width,
      height: height,
      rotationDegrees: rotationDegrees,
      nv21Bytes: nv21,
    );
  }
}

Uint8List convertNv21ToJpeg(Map<String, Object> args) {
  final width = args['width'] as int;
  final height = args['height'] as int;
  final nv21 = args['nv21'] as Uint8List;
  final frameSize = width * height;
  final image = img.Image(width: width, height: height);

  for (var y = 0; y < height; y++) {
    final uvRow = frameSize + (y >> 1) * width;
    final yRow = y * width;
    for (var x = 0; x < width; x++) {
      final yValue = nv21[yRow + x];
      final uvIndex = uvRow + (x & ~1);
      final vValue = nv21[uvIndex];
      final uValue = nv21[uvIndex + 1];

      var r = (yValue + 1.370705 * (vValue - 128)).round();
      var g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128))
          .round();
      var b = (yValue + 1.732446 * (uValue - 128)).round();

      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: 72));
}
