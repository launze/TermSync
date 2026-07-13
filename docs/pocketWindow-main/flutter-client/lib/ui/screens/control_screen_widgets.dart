part of 'control_screen.dart';

class _OverlayInfo extends StatelessWidget {
  final String leftText;
  final String rightText;

  const _OverlayInfo({
    required this.leftText,
    required this.rightText,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: Text(
                leftText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 6,
              child: Text(
                rightText,
                textAlign: TextAlign.left,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  final String label;

  const _ModeBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _ActionTextButton extends StatelessWidget {
  static const double _height = _ControlScreenState._bottomButtonHeight;
  final String label;
  final double minWidth;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final VoidCallback? onLongPressStop;

  const _ActionTextButton({
    required this.label,
    required this.onPressed,
    this.onLongPress,
    this.onLongPressStop,
    this.minWidth = 64,
  });

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        onLongPress: onLongPress,
        onLongPressUp: onLongPressStop,
        onLongPressCancel: onLongPressStop,
        child: Container(
          constraints: BoxConstraints(minWidth: minWidth),
          height: _height,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12.5),
            overflow: TextOverflow.fade,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

enum _CaptureEditMode {
  none,
  create,
  move,
  resizeTopLeft,
  resizeTopRight,
  resizeBottomLeft,
  resizeBottomRight,
}

class _CaptureSelectionPainter extends CustomPainter {
  final Rect? rect;

  const _CaptureSelectionPainter({
    required this.rect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Paint()..color = Colors.black.withValues(alpha: 0.20);
    canvas.drawRect(Offset.zero & size, overlay);
    if (rect == null) {
      return;
    }

    final clearPaint = Paint()..blendMode = BlendMode.clear;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, overlay);
    canvas.drawRect(rect!, clearPaint);
    canvas.restore();

    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect!, border);

    final fill = Paint()..color = Colors.white.withValues(alpha: 0.10);
    canvas.drawRect(rect!, fill);

    final handlePaint = Paint()..color = Colors.white;
    for (final point in <Offset>[
      rect!.topLeft,
      rect!.topRight,
      rect!.bottomLeft,
      rect!.bottomRight,
    ]) {
      canvas.drawCircle(point, 7, handlePaint);
      canvas.drawCircle(
        point,
        9,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CaptureSelectionPainter oldDelegate) {
    return oldDelegate.rect != rect;
  }
}
