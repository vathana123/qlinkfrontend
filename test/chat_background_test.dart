import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/app/theme/app_theme.dart';
import 'package:qlinkfrontend/features/chat/presentation/theme/chat_appearance.dart';
import 'package:qlinkfrontend/features/chat/presentation/theme/chat_background_config.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/chat_background.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/chat_appearance_preview.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/chat_bubble.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  test('restore default background preserves bubble preferences', () {
    const appearance = ChatAppearance(
      bubbleStyle: ChatBubbleStyle.compact,
      outgoingColor: OutgoingBubbleColor.emerald,
      fontSize: MessageFontSize.large,
      chatBackground: ChatBackgroundConfig(
        style: ChatBackgroundStyle.gradient,
        tone: ChatBackgroundTone.mint,
      ),
    );
    final reset = appearance.restoreBackground();
    expect(reset.chatBackground, ChatBackgroundConfig.defaults);
    expect(reset.bubbleStyle, appearance.bubbleStyle);
    expect(reset.outgoingColor, appearance.outgoingColor);
    expect(reset.fontSize, appearance.fontSize);
    expect(reset.copyWith(), reset);
    expect(appearance, isNot(reset));
    expect(appearance.lerp(reset, 1), reset);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'backgrounds, patterns and preview adapt to $brightness with readable bubbles',
      (tester) async {
        final theme = brightness == Brightness.dark
            ? AppTheme.dark
            : AppTheme.light;
        for (final style in ChatBackgroundStyle.values) {
          for (final tone in ChatBackgroundTone.values) {
            for (final pattern in ChatBackgroundPattern.values) {
              final config = ChatBackgroundConfig(
                style: style,
                tone: tone,
                pattern: pattern,
              );
              for (final color in OutgoingBubbleColor.values) {
                final appearance = ChatAppearance(
                  outgoingColor: color,
                  chatBackground: config,
                );
                for (final outgoing in [false, true]) {
                  expect(
                    contrast(
                      appearance.foreground(theme, outgoing: outgoing),
                      appearance.background(theme, outgoing: outgoing),
                    ),
                    greaterThanOrEqualTo(4.5),
                  );
                }
              }
              expect(
                contrast(theme.colorScheme.onSurface, config.base(theme)),
                greaterThanOrEqualTo(4.5),
              );
              expect(
                contrast(theme.colorScheme.onSurface, config.end(theme)),
                greaterThanOrEqualTo(4.5),
              );
              await tester.pumpWidget(
                MaterialApp(
                  themeAnimationDuration: Duration.zero,
                  theme: theme,
                  home: MediaQuery(
                    data: const MediaQueryData(
                      size: Size(320, 800),
                      textScaler: TextScaler.linear(2),
                    ),
                    child: Scaffold(
                      body: SizedBox(
                        width: 320,
                        child: ChatAppearancePreview(
                          appearance: ChatAppearance(
                            chatBackground: config,
                            fontSize: MessageFontSize.large,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              expect(find.byType(ChatBubble), findsNWidgets(2));
              final decoration =
                  tester
                          .widget<DecoratedBox>(
                            find
                                .descendant(
                                  of: find.byType(ChatBackground),
                                  matching: find.byType(DecoratedBox),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration;
              expect(decoration.color, config.base(theme));
              expect(
                decoration.gradient != null,
                style == ChatBackgroundStyle.gradient,
              );
              final painters = tester
                  .widgetList<CustomPaint>(find.byType(CustomPaint))
                  .where((w) => w.painter is ChatPatternPainter);
              expect(
                painters.length,
                style == ChatBackgroundStyle.pattern ? 1 : 0,
              );
              if (style == ChatBackgroundStyle.theme) {
                expect(config.base(theme), theme.scaffoldBackgroundColor);
              }
              expect(tester.takeException(), isNull);
            }
          }
        }
      },
    );
  }
  test(
    'pattern painter repaints only when pattern or resolved color changes',
    () {
      const painter = ChatPatternPainter(
        ChatBackgroundPattern.dots,
        Colors.blue,
      );
      expect(
        painter.shouldRepaint(
          const ChatPatternPainter(ChatBackgroundPattern.dots, Colors.blue),
        ),
        false,
      );
      expect(
        painter.shouldRepaint(
          const ChatPatternPainter(ChatBackgroundPattern.diagonal, Colors.blue),
        ),
        true,
      );
      expect(
        painter.shouldRepaint(
          const ChatPatternPainter(ChatBackgroundPattern.dots, Colors.red),
        ),
        true,
      );
    },
  );
  testWidgets(
    'background changes preserve list position, child state and taps',
    (tester) async {
      final scroll = ScrollController();
      var taps = 0;
      final list = ListView.builder(
        key: const ValueKey('history'),
        controller: scroll,
        itemCount: 1000,
        itemExtent: 60,
        itemBuilder: (_, i) =>
            ListTile(title: Text('Message $i'), onTap: () => taps++),
      );
      for (final style in ChatBackgroundStyle.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatBackground(
                configuration: ChatBackgroundConfig(style: style),
                child: list,
              ),
            ),
          ),
        );
        if (style == ChatBackgroundStyle.theme) {
          await tester.drag(find.byType(ListView), const Offset(0, -500));
          await tester.pumpAndSettle();
        } else {
          expect(scroll.offset, greaterThan(400));
        }
        final offset = scroll.offset;
        await tester.tap(find.byType(ListTile).at(2));
        await tester.pump();
        expect(scroll.offset, offset);
        expect(tester.takeException(), isNull);
      }
      expect(taps, 4);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
