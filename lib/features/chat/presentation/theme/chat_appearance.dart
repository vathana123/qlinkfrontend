import 'package:flutter/material.dart';

import 'chat_background_config.dart';

enum ChatBubbleStyle { standard, rounded, compact }

enum OutgoingBubbleColor { qlinkBlue, ocean, purple, emerald }

enum MessageFontSize { small, medium, large }

/// Immutable presentation values installed through ThemeData.extensions.
/// Account persistence is handled separately by ChatAppearanceStore.
@immutable
class ChatAppearance extends ThemeExtension<ChatAppearance> {
  static final _palettes = <(OutgoingBubbleColor, Brightness), ColorScheme>{};
  const ChatAppearance({
    this.bubbleStyle = ChatBubbleStyle.standard,
    this.outgoingColor = OutgoingBubbleColor.qlinkBlue,
    this.fontSize = MessageFontSize.medium,
    this.chatBackground = ChatBackgroundConfig.defaults,
  });

  final ChatBubbleStyle bubbleStyle;
  final OutgoingBubbleColor outgoingColor;
  final MessageFontSize fontSize;
  final ChatBackgroundConfig chatBackground;
  ChatAppearance restoreBackground() =>
      copyWith(chatBackground: ChatBackgroundConfig.defaults);

  static ChatAppearance of(BuildContext context) =>
      Theme.of(context).extension<ChatAppearance>() ?? const ChatAppearance();

  double get messageFontSize => switch (fontSize) {
    MessageFontSize.small => 14,
    MessageFontSize.medium => 16,
    MessageFontSize.large => 18,
  };
  double get captionFontSize => switch (fontSize) {
    MessageFontSize.small => 11,
    MessageFontSize.medium => 12,
    MessageFontSize.large => 13,
  };
  double get verticalSpacing => bubbleStyle == ChatBubbleStyle.compact ? 2 : 4;
  double get mediaRadius => switch (bubbleStyle) {
    ChatBubbleStyle.standard => 16,
    ChatBubbleStyle.rounded => 22,
    ChatBubbleStyle.compact => 10,
  };
  EdgeInsets padding({bool image = false}) => image
      ? EdgeInsets.all(bubbleStyle == ChatBubbleStyle.compact ? 3 : 4)
      : switch (bubbleStyle) {
          ChatBubbleStyle.standard => const EdgeInsets.fromLTRB(14, 10, 14, 8),
          ChatBubbleStyle.rounded => const EdgeInsets.fromLTRB(16, 12, 16, 10),
          ChatBubbleStyle.compact => const EdgeInsets.fromLTRB(10, 6, 10, 6),
        };
  BorderRadius corners({required bool outgoing}) {
    final radius = switch (bubbleStyle) {
      ChatBubbleStyle.standard => 20.0,
      ChatBubbleStyle.rounded => 26.0,
      ChatBubbleStyle.compact => 12.0,
    };
    final tail = bubbleStyle == ChatBubbleStyle.rounded ? radius : 6.0;
    return BorderRadius.only(
      topLeft: Radius.circular(radius),
      topRight: Radius.circular(radius),
      bottomLeft: Radius.circular(outgoing ? radius : tail),
      bottomRight: Radius.circular(outgoing ? tail : radius),
    );
  }

  ColorScheme palette(ThemeData theme) =>
      outgoingColor == OutgoingBubbleColor.qlinkBlue
      ? theme.colorScheme
      : _palettes.putIfAbsent(
          (outgoingColor, theme.brightness),
          () => ColorScheme.fromSeed(
            seedColor: switch (outgoingColor) {
              OutgoingBubbleColor.qlinkBlue => const Color(0xFF3478F6),
              OutgoingBubbleColor.ocean => const Color(0xFF007C91),
              OutgoingBubbleColor.purple => const Color(0xFF7551B8),
              OutgoingBubbleColor.emerald => const Color(0xFF18754A),
            },
            brightness: theme.brightness,
          ),
        );
  Color background(ThemeData theme, {required bool outgoing}) => outgoing
      ? palette(theme).primaryContainer
      : theme.colorScheme.surfaceContainer;
  Color foreground(ThemeData theme, {required bool outgoing}) => outgoing
      ? palette(theme).onPrimaryContainer
      : theme.colorScheme.onSurface;
  TextStyle textStyle(ThemeData theme, {required bool outgoing}) =>
      (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
        fontSize: messageFontSize,
        height: 1.5,
        color: foreground(theme, outgoing: outgoing),
      );

  @override
  ChatAppearance copyWith({
    ChatBubbleStyle? bubbleStyle,
    OutgoingBubbleColor? outgoingColor,
    MessageFontSize? fontSize,
    ChatBackgroundConfig? chatBackground,
  }) => ChatAppearance(
    bubbleStyle: bubbleStyle ?? this.bubbleStyle,
    outgoingColor: outgoingColor ?? this.outgoingColor,
    fontSize: fontSize ?? this.fontSize,
    chatBackground: chatBackground ?? this.chatBackground,
  );
  @override
  ChatAppearance lerp(covariant ChatAppearance? other, double t) =>
      other == null || t < .5 ? this : other;
  @override
  bool operator ==(Object other) =>
      other is ChatAppearance &&
      other.bubbleStyle == bubbleStyle &&
      other.outgoingColor == outgoingColor &&
      other.fontSize == fontSize &&
      other.chatBackground == chatBackground;
  @override
  int get hashCode =>
      Object.hash(bubbleStyle, outgoingColor, fontSize, chatBackground);
}
