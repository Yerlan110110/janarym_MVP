import 'package:flutter/material.dart';

import '../runtime/perception_event_bus.dart';

enum BBoxSeverity { danger, medium, safe }

class BBoxOverlayEntry {
  const BBoxOverlayEntry({
    required this.bbox,
    required this.label,
    required this.confidence,
    required this.severity,
    this.distanceM,
  });

  final BoundingBox bbox;
  final String label;
  final double confidence;
  final BBoxSeverity severity;
  final double? distanceM;

  Color get color {
    switch (severity) {
      case BBoxSeverity.danger:
        return const Color(0xFFEF4444);
      case BBoxSeverity.medium:
        return const Color(0xFFF97316);
      case BBoxSeverity.safe:
        return const Color(0xFF22C55E);
    }
  }
}

class BBoxPainter extends CustomPainter {
  const BBoxPainter({required this.entries, this.mirrorHorizontally = false});

  final List<BBoxOverlayEntry> entries;
  final bool mirrorHorizontally;

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.isEmpty || size.isEmpty) return;

    for (final entry in entries) {
      final safeRect = _scaleBoxToCanvas(entry.bbox, size);
      final color = entry.color;
      final strokeWidth = switch (entry.severity) {
        BBoxSeverity.danger => 4.2,
        BBoxSeverity.medium => 3.6,
        BBoxSeverity.safe => 3.0,
      };
      final fillPaint = Paint()
        ..color = color.withValues(
          alpha: switch (entry.severity) {
            BBoxSeverity.danger => 0.18,
            BBoxSeverity.medium => 0.14,
            BBoxSeverity.safe => 0.10,
          },
        )
        ..style = PaintingStyle.fill;
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      final shadowPaint = Paint()
        ..color = const Color(0xC0000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

      final box = RRect.fromRectAndRadius(safeRect, const Radius.circular(18));
      canvas.drawRRect(box, fillPaint);
      canvas.drawRRect(box, shadowPaint);
      canvas.drawRRect(box, glowPaint);
      canvas.drawRRect(box, boxPaint);
      _drawCornerAccents(canvas, safeRect, color, strokeWidth);

      final confidence = (entry.confidence * 100).clamp(0, 100).round();
      final label = entry.distanceM == null
          ? '${entry.label} $confidence%'
          : '${entry.label} $confidence% ${entry.distanceM!.toStringAsFixed(1)}m';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            shadows: [
              Shadow(
                color: Color(0xE6000000),
                blurRadius: 10,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width - 24);

      final tagPadding = const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 8,
      );
      final tagWidth = textPainter.width + tagPadding.horizontal;
      final tagHeight = textPainter.height + tagPadding.vertical;
      final tagLeft = safeRect.left.clamp(12.0, size.width - tagWidth - 12.0);
      final tagTop = (safeRect.top - tagHeight - 8).clamp(
        12.0,
        size.height - tagHeight - 12.0,
      );
      final tagRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(tagLeft, tagTop, tagWidth, tagHeight),
        const Radius.circular(999),
      );
      final tagPaint = Paint()..color = const Color(0xCC020617);
      final tagBorder = Paint()
        ..color = color.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      canvas.drawRRect(tagRect, tagPaint);
      canvas.drawRRect(tagRect, tagBorder);
      textPainter.paint(
        canvas,
        Offset(tagLeft + tagPadding.left, tagTop + tagPadding.top),
      );
    }
  }

  void _drawCornerAccents(
    Canvas canvas,
    Rect rect,
    Color color,
    double strokeWidth,
  ) {
    final accentPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 0.8
      ..strokeCap = StrokeCap.round;
    final corner = rect.shortestSide * 0.16;
    final length = corner.clamp(14.0, 26.0);

    canvas.drawLine(
      rect.topLeft,
      Offset(rect.left + length, rect.top),
      accentPaint,
    );
    canvas.drawLine(
      rect.topLeft,
      Offset(rect.left, rect.top + length),
      accentPaint,
    );

    canvas.drawLine(
      Offset(rect.right - length, rect.top),
      rect.topRight,
      accentPaint,
    );
    canvas.drawLine(
      rect.topRight,
      Offset(rect.right, rect.top + length),
      accentPaint,
    );

    canvas.drawLine(
      Offset(rect.left, rect.bottom - length),
      rect.bottomLeft,
      accentPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      Offset(rect.left + length, rect.bottom),
      accentPaint,
    );

    canvas.drawLine(
      Offset(rect.right - length, rect.bottom),
      rect.bottomRight,
      accentPaint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.bottom - length),
      rect.bottomRight,
      accentPaint,
    );
  }

  Rect _scaleBoxToCanvas(BoundingBox bbox, Size size) {
    final normalizedLeft = mirrorHorizontally
        ? (1 - bbox.left - bbox.width)
        : bbox.left;
    final normalizedTop = bbox.top;
    final normalizedRight = normalizedLeft + bbox.width;
    final normalizedBottom = normalizedTop + bbox.height;

    final left = (normalizedLeft * size.width).clamp(0.0, size.width);
    final top = (normalizedTop * size.height).clamp(0.0, size.height);
    final right = (normalizedRight * size.width).clamp(0.0, size.width);
    final bottom = (normalizedBottom * size.height).clamp(0.0, size.height);

    final clampedRight = right <= left
        ? (left + 12).clamp(0.0, size.width)
        : right;
    final clampedBottom = bottom <= top
        ? (top + 12).clamp(0.0, size.height)
        : bottom;

    return Rect.fromLTRB(left, top, clampedRight, clampedBottom);
  }

  @override
  bool shouldRepaint(covariant BBoxPainter oldDelegate) {
    if (identical(oldDelegate.entries, entries) &&
        oldDelegate.mirrorHorizontally == mirrorHorizontally) {
      return false;
    }
    if (oldDelegate.mirrorHorizontally != mirrorHorizontally) return true;
    if (oldDelegate.entries.length != entries.length) return true;
    for (var i = 0; i < entries.length; i++) {
      final next = entries[i];
      final prev = oldDelegate.entries[i];
      if (next.label != prev.label ||
          next.confidence != prev.confidence ||
          next.severity != prev.severity ||
          next.distanceM != prev.distanceM ||
          next.bbox.left != prev.bbox.left ||
          next.bbox.top != prev.bbox.top ||
          next.bbox.width != prev.bbox.width ||
          next.bbox.height != prev.bbox.height) {
        return true;
      }
    }
    return false;
  }
}
