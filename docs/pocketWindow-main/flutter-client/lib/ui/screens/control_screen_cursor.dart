part of 'control_screen.dart';

class _MousePanelButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MousePanelButton({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteCursorOverlayV2 extends StatelessWidget {
  final double normalizedX;
  final double normalizedY;
  final int remoteWidth;
  final int remoteHeight;
  final Uint8List? cursorImageBytes;
  final int? cursorImageWidth;
  final int? cursorImageHeight;
  final int hotspotX;
  final int hotspotY;

  const _RemoteCursorOverlayV2({
    required this.normalizedX,
    required this.normalizedY,
    required this.remoteWidth,
    required this.remoteHeight,
    required this.cursorImageBytes,
    required this.cursorImageWidth,
    required this.cursorImageHeight,
    required this.hotspotX,
    required this.hotspotY,
  });

  static const ListEquality<int> _bytesEquality = ListEquality<int>();
  static Uint8List? _lastDecodedBytes;
  static Future<ui.Image?>? _lastDecodedFuture;

  static Future<ui.Image?> _decodeCursorImage(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return Future<ui.Image?>.value(null);
    }
    if (_lastDecodedBytes != null &&
        _lastDecodedBytes!.length == bytes.length &&
        _bytesEquality.equals(_lastDecodedBytes!, bytes)) {
      return _lastDecodedFuture ?? Future<ui.Image?>.value(null);
    }
    _lastDecodedBytes = Uint8List.fromList(bytes);
    _lastDecodedFuture =
        decodeImageFromList(bytes).then<ui.Image?>((image) => image);
    return _lastDecodedFuture!;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image?>(
      future: _decodeCursorImage(cursorImageBytes),
      builder: (context, snapshot) {
        return CustomPaint(
          painter: _RemoteCursorPainterV2(
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            remoteWidth: remoteWidth,
            remoteHeight: remoteHeight,
            cursorImage: snapshot.data,
            cursorImageWidth: cursorImageWidth,
            cursorImageHeight: cursorImageHeight,
            hotspotX: hotspotX,
            hotspotY: hotspotY,
          ),
        );
      },
    );
  }
}

class _RemoteCursorPainterV2 extends CustomPainter {
  final double normalizedX;
  final double normalizedY;
  final int remoteWidth;
  final int remoteHeight;
  final ui.Image? cursorImage;
  final int? cursorImageWidth;
  final int? cursorImageHeight;
  final int hotspotX;
  final int hotspotY;

  const _RemoteCursorPainterV2({
    required this.normalizedX,
    required this.normalizedY,
    required this.remoteWidth,
    required this.remoteHeight,
    required this.cursorImage,
    required this.cursorImageWidth,
    required this.cursorImageHeight,
    required this.hotspotX,
    required this.hotspotY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (remoteWidth <= 0 || remoteHeight <= 0) return;

    final scale =
        math.min(size.width / remoteWidth, size.height / remoteHeight);
    final drawW = remoteWidth * scale;
    final drawH = remoteHeight * scale;
    final offsetX = (size.width - drawW) / 2;
    final offsetY = (size.height - drawH) / 2;
    final x = offsetX + (normalizedX * drawW);
    final y = offsetY + (normalizedY * drawH);

    if (cursorImage != null &&
        cursorImageWidth != null &&
        cursorImageHeight != null &&
        cursorImageWidth! > 0 &&
        cursorImageHeight! > 0) {
      final dst = Rect.fromLTWH(
        x - (hotspotX * scale),
        y - (hotspotY * scale),
        cursorImageWidth! * scale,
        cursorImageHeight! * scale,
      );
      final src = Rect.fromLTWH(
        0,
        0,
        cursorImage!.width.toDouble(),
        cursorImage!.height.toDouble(),
      );
      canvas.drawImageRect(
        cursorImage!,
        src,
        dst,
        Paint()..filterQuality = FilterQuality.none,
      );
      return;
    }

    const cursorScale = 0.82;
    final stroke = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final fill = Paint()..color = Colors.white;
    final accent = Paint()..color = const Color(0xFFFF5A5A);

    final path = Path()
      ..moveTo(x, y)
      ..lineTo(x, y + (24 * cursorScale))
      ..lineTo(x + (6 * cursorScale), y + (18 * cursorScale))
      ..lineTo(x + (11 * cursorScale), y + (30 * cursorScale))
      ..lineTo(x + (16 * cursorScale), y + (28 * cursorScale))
      ..lineTo(x + (11 * cursorScale), y + (16 * cursorScale))
      ..lineTo(x + (22 * cursorScale), y + (16 * cursorScale))
      ..close();

    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
    canvas.drawCircle(Offset(x, y), 4.0, Paint()..color = Colors.black);
    canvas.drawCircle(Offset(x, y), 2.3, accent);
  }

  @override
  bool shouldRepaint(covariant _RemoteCursorPainterV2 oldDelegate) {
    return oldDelegate.normalizedX != normalizedX ||
        oldDelegate.normalizedY != normalizedY ||
        oldDelegate.remoteWidth != remoteWidth ||
        oldDelegate.remoteHeight != remoteHeight ||
        oldDelegate.cursorImage != cursorImage ||
        oldDelegate.cursorImageWidth != cursorImageWidth ||
        oldDelegate.cursorImageHeight != cursorImageHeight ||
        oldDelegate.hotspotX != hotspotX ||
        oldDelegate.hotspotY != hotspotY;
  }
}
