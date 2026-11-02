import 'package:flutter/material.dart';

enum ChatBackgroundStyle { theme, solid, gradient, pattern }

enum ChatBackgroundTone { blue, lavender, mint }

enum ChatBackgroundPattern { dots, diagonal }

@immutable
class ChatBackgroundConfig {
  const ChatBackgroundConfig({
    this.style = ChatBackgroundStyle.theme,
    this.tone = ChatBackgroundTone.blue,
    this.pattern = ChatBackgroundPattern.dots,
  });
  final ChatBackgroundStyle style;
  final ChatBackgroundTone tone;
  final ChatBackgroundPattern pattern;
  static const defaults = ChatBackgroundConfig();

  Color base(ThemeData theme) {
    if (style == ChatBackgroundStyle.theme) {
      return theme.scaffoldBackgroundColor;
    }
    final tint = switch (tone) {
      ChatBackgroundTone.blue => const Color(0xFF3478F6),
      ChatBackgroundTone.lavender => const Color(0xFF9468CF),
      ChatBackgroundTone.mint => const Color(0xFF31947A),
    };
    return Color.alphaBlend(
      tint.withValues(alpha: theme.brightness == Brightness.dark ? .12 : .08),
      theme.scaffoldBackgroundColor,
    );
  }

  Color end(ThemeData theme) => Color.alphaBlend(
    theme.colorScheme.surface.withValues(alpha: .7),
    base(theme),
  );
  Color ink(ThemeData theme) => theme.colorScheme.onSurface.withValues(
    alpha: theme.brightness == Brightness.dark ? .035 : .045,
  );

  ChatBackgroundConfig copyWith({
    ChatBackgroundStyle? style,
    ChatBackgroundTone? tone,
    ChatBackgroundPattern? pattern,
  }) => ChatBackgroundConfig(
    style: style ?? this.style,
    tone: tone ?? this.tone,
    pattern: pattern ?? this.pattern,
  );
  @override
  bool operator ==(Object other) =>
      other is ChatBackgroundConfig &&
      style == other.style &&
      tone == other.tone &&
      pattern == other.pattern;
  @override
  int get hashCode => Object.hash(style, tone, pattern);
}
