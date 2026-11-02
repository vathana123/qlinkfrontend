import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qlinkfrontend/app/theme/app_theme.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/chat_screen.dart';
import 'package:qlinkfrontend/features/chat/presentation/theme/chat_appearance.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/chat_bubble.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/attachment_bubble.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/voice_bubble.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/search_highlight.dart';

import 'privacy_test.dart' show SignedInAuth;
import 'voice_test.dart' show FakePlayer;
import 'support/fakes.dart';
import 'support/media.dart';

const bilingual =
    'សួស្តី! តើអ្នកសុខសប្បាយទេ?\nHello! English and ខ្មែរ wrap together.';
ThemeData themed(Brightness brightness, ChatAppearance appearance) =>
    (brightness == Brightness.dark ? AppTheme.dark : AppTheme.light).copyWith(
      extensions: [appearance],
    );

void main() {
  test(
    'configuration is immutable, copies values and keeps theme defaults',
    () {
      const original = ChatAppearance();
      final copy = original.copyWith(bubbleStyle: ChatBubbleStyle.rounded);
      expect(original.bubbleStyle, ChatBubbleStyle.standard);
      expect(copy.copyWith(), copy);
      expect(original.lerp(copy, 1), copy);
      expect(AppTheme.dark.extension<ChatAppearance>(), original);
      expect(AppTheme.light.extension<ChatAppearance>(), original);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'all styles, colors and sizes render Khmer and English at accessible scales in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final style in ChatBubbleStyle.values) {
          for (final color in OutgoingBubbleColor.values) {
            for (final size in MessageFontSize.values) {
              for (final scale in [1.0, 2.0]) {
                final appearance = ChatAppearance(
                  bubbleStyle: style,
                  outgoingColor: color,
                  fontSize: size,
                );
                final theme = themed(brightness, appearance);
                await tester.pumpWidget(
                  MaterialApp(
                    themeAnimationDuration: Duration.zero,
                    theme: theme,
                    home: MediaQuery(
                      data: MediaQueryData(
                        size: const Size(320, 1400),
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: const Scaffold(
                        body: SingleChildScrollView(
                          child: Column(
                            children: [
                              Align(
                                alignment: Alignment.centerRight,
                                child: ChatBubble(
                                  outgoing: true,
                                  child: Text(bilingual),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: ChatBubble(
                                  outgoing: false,
                                  highlighted: true,
                                  child: SearchHighlight(
                                    bilingual,
                                    'ខ្មែរ',
                                    maxLines: 6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                final surface = tester.widget<Container>(
                  find
                      .descendant(
                        of: find.byType(ChatBubble).first,
                        matching: find.byType(Container),
                      )
                      .first,
                );
                final decoration = surface.decoration! as BoxDecoration;
                expect(
                  decoration.borderRadius,
                  appearance.corners(outgoing: true),
                );
                expect(surface.padding, appearance.padding());
                final textContext = tester.element(find.text(bilingual).first);
                expect(
                  DefaultTextStyle.of(textContext).style.fontSize,
                  appearance.messageFontSize,
                );
                expect(
                  MediaQuery.textScalerOf(textContext).scale(10),
                  10 * scale,
                );
                final foreground = appearance
                    .foreground(theme, outgoing: true)
                    .computeLuminance();
                final background = decoration.color!.computeLuminance();
                final contrast = (foreground > background
                    ? (foreground + .05) / (background + .05)
                    : (background + .05) / (foreground + .05));
                expect(contrast, greaterThanOrEqualTo(4.5));
                expect(
                  tester.getSize(find.byType(ChatBubble).first).width,
                  lessThanOrEqualTo(320 * .82 + .1),
                );
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$style/$color/$size/$scale',
                );
              }
            }
          }
        }
      },
    );
  }

  for (final style in ChatBubbleStyle.values) {
    testWidgets(
      'chat decorations and action menus remain available with $style',
      (tester) async {
        final auth = SignedInAuth();
        final adapter = FakeAdapter(
          (r) => response(
            envelope(
              r.path.endsWith('/relationship')
                  ? {'canMessage': true}
                  : {
                      'items': [
                        {
                          'id': 'm',
                          'roomId': 'r',
                          'senderId': 'user-1',
                          'clientMessageId': 'key',
                          'type': 'TEXT',
                          'content': bilingual,
                          'createdAt': '2026-11-01T01:00:00Z',
                          'editedAt': '2026-11-01T01:01:00Z',
                          'delivery': 'SEEN',
                          'forwarded': true,
                          'replyToId': 'original',
                          'reply': {
                            'id': 'original',
                            'content': 'Original quote',
                            'unavailable': false,
                          },
                          'reactions': [
                            {'emoji': '👍', 'count': 2, 'selected': true},
                          ],
                          'canDeleteForEveryone': true,
                        },
                      ],
                    },
            ),
          ),
        );
        final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter))
          ..setAccount('user-1');
        await tester.pumpWidget(
          RepositoryProvider.value(
            value: repo,
            child: BlocProvider<AuthBloc>.value(
              value: auth,
              child: MaterialApp(
                themeAnimationDuration: Duration.zero,
                theme: themed(
                  Brightness.dark,
                  ChatAppearance(
                    bubbleStyle: style,
                    outgoingColor: OutgoingBubbleColor.emerald,
                    fontSize: MessageFontSize.large,
                  ),
                ),
                home: const ChatScreen(
                  conversation: Conversation(
                    PublicUser('peer', 'Peer'),
                    roomId: 'r',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(bilingual), findsOneWidget);
        expect(find.text('Forwarded'), findsOneWidget);
        expect(find.text('Original quote'), findsOneWidget);
        expect(find.text('👍 2'), findsOneWidget);
        expect(find.textContaining('Edited'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'before menu');
        await tester.longPress(find.text(bilingual));
        await tester.pumpAndSettle();
        for (final action in [
          'Reply',
          'Edit',
          'Forward',
          'Delete for Me',
          'Delete for Everyone',
        ]) {
          expect(find.text(action), findsOneWidget);
        }
        expect(tester.takeException(), isNull, reason: 'menu');
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Cancel reply'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await runMediaTask(tester, repo.dispose);
        await tester.runAsync(auth.close);
      },
    );
  }

  testWidgets(
    'appearance changes preserve mounted photo state and the active audio source',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('qlink-appearance-'),
      ))!;
      final bytes = img.encodePng(img.Image(width: 20, height: 10));
      final adapter = FakeAdapter(
        (r) => ResponseBody.fromBytes(
          r.path.contains('photo') ? bytes : [1, 2, 3],
          200,
        ),
      );
      final repo = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        mediaDirectory: () async => directory,
      )..setAccount('me');
      final photo = ChatMessage(
        id: 'p',
        senderId: 'peer',
        clientMessageId: 'p',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'IMAGE',
        fileId: 'photo',
        attachment: AttachmentMetadata('photo.png', 'image/png', bytes.length),
      );
      final voice = ChatMessage(
        id: 'v',
        senderId: 'peer',
        clientMessageId: 'v',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'VOICE',
        fileId: 'voice',
        durationMs: 1000,
      );
      final player = FakePlayer();
      await runMediaTask(tester, () async {
        await repo.media.photo('photo');
        await repo.voicePlayback.toggle(voice, createPlayer: () => player);
      });
      Widget app(ChatAppearance appearance) => RepositoryProvider.value(
        value: repo,
        child: MaterialApp(
          themeAnimationDuration: Duration.zero,
          theme: themed(Brightness.light, appearance),
          home: Scaffold(
            body: Column(
              children: [
                ChatBubble(
                  outgoing: true,
                  image: true,
                  child: AttachmentBubble(message: photo),
                ),
                ChatBubble(outgoing: false, child: VoiceBubble(message: voice)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(const ChatAppearance()));
      await tester.pump();
      final photoState = tester.state(find.byType(AttachmentBubble));
      final cached = repo.media.peekPhoto('photo');
      for (final style in ChatBubbleStyle.values) {
        await tester.pumpWidget(
          app(
            ChatAppearance(
              bubbleStyle: style,
              outgoingColor: OutgoingBubbleColor.purple,
              fontSize: MessageFontSize.large,
            ),
          ),
        );
        await tester.pump();
        expect(tester.state(find.byType(AttachmentBubble)), same(photoState));
        expect(repo.media.peekPhoto('photo'), same(cached));
        expect(player.loads, 1);
        expect(player.active, true);
        expect(adapter.requests.length, 2);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      await runMediaTask(tester, repo.dispose);
      await tester.runAsync(() => directory.delete(recursive: true));
    },
  );
}
