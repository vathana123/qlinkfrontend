import 'package:flutter/material.dart';

import '../theme/chat_appearance.dart';

/// Only the visual shell changes with appearance. Keep media children and their
/// keys stable so changing a color/font never retires an image or audio source.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.outgoing,
    required this.child,
    this.image = false,
    this.highlighted = false,
  });
  final bool outgoing, image, highlighted;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appearance = ChatAppearance.of(context);
    final foreground = appearance.foreground(theme, outgoing: outgoing);
    return Container(
      margin: EdgeInsets.symmetric(vertical: appearance.verticalSpacing),
      padding: appearance.padding(image: image),
      constraints: BoxConstraints(
        maxWidth: (MediaQuery.sizeOf(context).width * .82).clamp(0.0, 560.0),
      ),
      decoration: BoxDecoration(
        color: appearance.background(theme, outgoing: outgoing),
        borderRadius: appearance.corners(outgoing: outgoing),
        border: Border.all(
          color: highlighted
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(alpha: .35),
          width: highlighted ? 2 : 1,
        ),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        child: DefaultTextStyle(
          style: appearance.textStyle(theme, outgoing: outgoing),
          child: child,
        ),
      ),
    );
  }
}
