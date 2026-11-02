import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/chat_screen.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/app.dart';
import 'package:qlinkfrontend/app/theme/app_theme.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:qlinkfrontend/features/auth/data/models/app_user.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_appearance_store.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_appearance_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/chat_appearance_screen.dart';
import 'package:qlinkfrontend/features/chat/presentation/theme/chat_appearance.dart';
import 'package:qlinkfrontend/features/chat/presentation/theme/chat_background_config.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/chat_appearance_preview.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/chat_bubble.dart';

import 'support/fakes.dart';

const custom = ChatAppearance(
  bubbleStyle: ChatBubbleStyle.rounded,
  outgoingColor: OutgoingBubbleColor.purple,
  fontSize: MessageFontSize.large,
  chatBackground: ChatBackgroundConfig(
    style: ChatBackgroundStyle.pattern,
    tone: ChatBackgroundTone.mint,
    pattern: ChatBackgroundPattern.diagonal,
  ),
);

class DelayedStore extends ChatAppearanceStore {
  DelayedStore(super.preferences);
  final gates = <Completer<void>>[];
  final accounts = <String>[];
  @override
  Future<void> save(String account, ChatAppearance value) async {
    accounts.add(account);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    await super.save(account, value);
  }
}

class SwitchAuth extends AuthBloc {
  SwitchAuth(super.repository);
  void account(String id) =>
      emit(AuthAuthenticated(AppUser.fromJson({...userJson, 'id': id})));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'restart restores all values; logout and accounts remain isolated',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final cubit = ChatAppearanceCubit(ChatAppearanceStore(prefs))
        ..setAccount('alice');
      final save = cubit.update(custom);
      expect(cubit.state.appearance, custom);
      await save;
      cubit.setAccount(null);
      expect(cubit.state.appearance, const ChatAppearance());
      cubit.setAccount('bob');
      expect(cubit.state.appearance, const ChatAppearance());
      await cubit.update(
        custom.copyWith(outgoingColor: OutgoingBubbleColor.ocean),
      );
      await cubit.close();
      final restarted = ChatAppearanceCubit(ChatAppearanceStore(prefs))
        ..setAccount('alice');
      expect(restarted.state.appearance, custom);
      await restarted.reset();
      expect(restarted.state.appearance, const ChatAppearance());
      restarted.setAccount('bob');
      expect(
        restarted.state.appearance.outgoingColor,
        OutgoingBubbleColor.ocean,
      );
      await restarted.close();
    },
  );
  test('invalid, unsupported and unknown values safely use defaults', () async {
    final prefs = await SharedPreferences.getInstance(),
        store = ChatAppearanceStore(await SharedPreferences.getInstance());
    for (final raw in [
      'invalid',
      '[]',
      '{"version":99}',
      '{"version":1,"bubble":"future","font":400}',
    ]) {
      await prefs.setString(ChatAppearanceStore.key('alice'), raw);
      expect(store.read('alice'), const ChatAppearance());
    }
    await prefs.setInt(ChatAppearanceStore.key('alice'), 4);
    expect(store.read('alice'), const ChatAppearance());
  });
  test('queued writes keep identity and order across account switches and report save failures', () async {
    final prefs = await SharedPreferences.getInstance(),
        store = DelayedStore(await SharedPreferences.getInstance());
    final cubit = ChatAppearanceCubit(store)..setAccount('alice');
    final first = cubit.update(custom);
    await Future<void>.delayed(Duration.zero);
    cubit.setAccount('bob');
    final second = cubit.update(
      custom.copyWith(fontSize: MessageFontSize.small),
    );
    cubit.setAccount('alice');
    expect(cubit.state.appearance, custom);
    store.gates.first.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(store.accounts, ['alice', 'bob']);
    store.gates.last.complete();
    await second;
    expect(ChatAppearanceStore(prefs).read('alice'), custom);
    expect(
      ChatAppearanceStore(prefs).read('bob').fontSize,
      MessageFontSize.small,
    );
    final failed = cubit.update(
      custom.copyWith(fontSize: MessageFontSize.small),
    );
    await Future<void>.delayed(Duration.zero);
    store.gates.last.completeError(StateError('disk'));
    await failed;
    expect(cubit.state.error, isNotNull);
    expect(cubit.state.appearance.fontSize, MessageFontSize.small);
    await cubit.close();
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'settings preview, reset confirmation and accessible controls in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final prefs = await SharedPreferences.getInstance();
        final cubit = ChatAppearanceCubit(ChatAppearanceStore(prefs))
          ..setAccount('alice');
        await tester.pumpWidget(
          BlocProvider.value(
            value: cubit,
            child: MaterialApp(
              theme: brightness == Brightness.dark
                  ? AppTheme.dark
                  : AppTheme.light,
              home: const ChatAppearanceScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChatBubble), findsNWidgets(4));
        Future<void> choose(String label) async {
          if (find.text(label).evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              find.text(label),
              400,
              scrollable: find.byType(Scrollable).first,
            );
          }
          await tester.ensureVisible(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
        }

        await choose('Rounded');
        await choose('Emerald');
        await choose('Large');
        await choose('Pattern');
        await choose('Mint');
        await choose('Diagonal');
        await tester.scrollUntilVisible(
          find.text('Live preview'),
          -500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ChatAppearancePreview>(find.byType(ChatAppearancePreview))
              .appearance,
          cubit.state.appearance,
        );
        await choose('Reset to Defaults');
        await choose('Cancel');
        expect(cubit.state.appearance.bubbleStyle, ChatBubbleStyle.rounded);
        await choose('Reset to Defaults');
        await choose('Reset');
        expect(cubit.state.appearance, const ChatAppearance());
        await choose('Reset to Defaults');
        cubit.setAccount('bob');
        await cubit.update(custom);
        await tester.pumpAndSettle();
        await choose('Reset');
        expect(cubit.state.account, 'bob');
        expect(cubit.state.appearance, custom);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(cubit.close);
      },
    );
  }
  testWidgets(
    'profile navigation applies saved preferences live through light dark system and account changes',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await ChatAppearanceStore(prefs).save('alice', custom);
      var histories = 0;
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((r) {
          if (r.path.endsWith('/messages') && r.method == 'GET') {
            histories++;
            return response(
              envelope({
                'items': [
                  {
                    'id': 'message',
                    'senderId': 'peer',
                    'clientMessageId': 'k',
                    'content': 'History remains',
                    'type': 'TEXT',
                    'createdAt': '2026-11-01T01:00:00Z',
                  },
                ],
              }),
            );
          }
          return response(
            envelope(
              r.path.endsWith('/rooms')
                  ? {'content': [], 'last': true}
                  : userJson,
            ),
          );
        });
      final auth = SwitchAuth(AuthRepository(dio, MemoryTokens(), FakeOAuth()))
        ..account('alice');
      final theme = ThemeCubit(prefs);
      await tester.pumpWidget(QLinkApp(auth: auth, theme: theme));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Your profile'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Appearance'));
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat Appearance'));
      await tester.pumpAndSettle();
      expect(
        ChatAppearance.of(tester.element(find.byType(ChatAppearancePreview))),
        custom,
      );
      final cubit = tester
          .element(find.byType(ChatAppearancePreview))
          .read<ChatAppearanceCubit>();
      await cubit.update(
        custom.copyWith(outgoingColor: OutgoingBubbleColor.emerald),
      );
      await tester.pumpAndSettle();
      for (final mode in ThemeMode.values) {
        await theme.setTheme(mode);
        await tester.pumpAndSettle();
        expect(
          ChatAppearance.of(tester.element(find.byType(ChatBubble).first))
              .outgoingColor,
          OutgoingBubbleColor.emerald,
        );
      }
      auth.account('bob');
      await tester.pumpAndSettle();
      expect(cubit.state.appearance, const ChatAppearance());
      auth.account('alice');
      await tester.pumpAndSettle();
      expect(cubit.state.appearance.outgoingColor, OutgoingBubbleColor.emerald);
      final router = GoRouter.of(
        tester.element(find.byType(ChatAppearancePreview)),
      );
      for (final group in [false, true]) {
        unawaited(
          router.push(
            '/conversation',
            extra: Conversation(
              const PublicUser('peer', 'Peer'),
              roomId: group ? 'g' : 'r',
              groupName: group ? 'Group' : null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final chat = tester
            .element(find.byType(ChatScreen))
            .read<ChatAppearanceCubit>();
        final stateContext = tester.element(find.byType(ChatBubble).first);
        final historyCubit = stateContext.read<ChatCubit>();
        final count = histories;
        await chat.update(
          chat.state.appearance.copyWith(fontSize: MessageFontSize.small),
        );
        await tester.pumpAndSettle();
        expect(
          tester.element(find.byType(ChatBubble).first).read<ChatCubit>(),
          same(historyCubit),
        );
        expect(histories, count);
        expect(find.text('History remains'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
