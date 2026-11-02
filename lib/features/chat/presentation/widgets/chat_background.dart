import 'package:flutter/material.dart';

import '../theme/chat_appearance.dart';
import '../theme/chat_background_config.dart';

/// One stationary viewport layer, independent of the lazy message list. The
/// decorative subtree has no hit targets or accessibility announcements.
class ChatBackground extends StatelessWidget {
  const ChatBackground({super.key, required this.child, this.configuration});
  final Widget child;
  final ChatBackgroundConfig? configuration;
  @override
  Widget build(BuildContext context) {
    final config = configuration ?? ChatAppearance.of(context).chatBackground;
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: config.base(theme),
                    gradient: config.style == ChatBackgroundStyle.gradient
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [config.base(theme), config.end(theme)],
                          )
                        : null,
                  ),
                  child: CustomPaint(
                    painter: config.style == ChatBackgroundStyle.pattern
                        ? ChatPatternPainter(config.pattern, config.ink(theme))
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class ChatPatternPainter extends CustomPainter {
  const ChatPatternPainter(this.pattern, this.color);
  final ChatBackgroundPattern pattern;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    if (pattern == ChatBackgroundPattern.dots) {
      for (double y = 16; y < size.height; y += 32) {
        for (double x = 16; x < size.width; x += 32) {
          canvas.drawCircle(Offset(x, y), 1.3, paint);
        }
      }
    } else {
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      final path = Path();
      for (double x = -size.height; x < size.width; x += 48) {
        path.moveTo(x, 0);
        path.lineTo(x + size.height, size.height);
      }
      paint.style = PaintingStyle.stroke;
      canvas.drawPath(path, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant ChatPatternPainter oldDelegate) =>
      oldDelegate.pattern != pattern || oldDelegate.color != color;
}
