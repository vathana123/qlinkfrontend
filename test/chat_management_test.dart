import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/home/presentation/screens/home_screen.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/rooms_cubit.dart';
import 'package:qlinkfrontend/features/home/presentation/widgets/chat_list_tile.dart';

import 'support/fakes.dart';
import 'support/media.dart';
import 'privacy_test.dart' show SignedInAuth;

Map<String, dynamic> room(
  String id, {
  bool pinned = false,
  bool archived = false,
}) => {
  'id': id,
  'participant': {'id': 'peer', 'displayName': 'Peer'},
  'pinned': pinned,
  'archived': archived,
  'unreadCount': 3,
  'lastMessageAt': id == 'old'
      ? '2026-01-01T00:00:00Z'
      : '2026-02-01T00:00:00Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('long-press actions persist and archived chats can be restored', (
    tester,
  ) async {
    final auth = SignedInAuth();
    var saved = room('old');
    final adapter = FakeAdapter((r) {
      if (r.method == 'PUT') {
        saved = {...saved, ...Map<String, dynamic>.from(r.data as Map)};
        return response(envelope(saved));
      }
      if (r.path.endsWith('/rooms/old')) return response(envelope(saved));
      return response(
        envelope({
          'content': r.queryParameters['archived'] == saved['archived']
              ? [saved]
              : [],
          'last': true,
        }),
      );
    });
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter))
      ..setAccount('user-1');
    final router = GoRouter(
      initialLocation: '/chats',
      routes: [
        GoRoute(path: '/chats', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/chats/archived',
          builder: (_, _) => const HomeScreen(archived: true),
        ),
      ],
    );
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: repo,
        child: BlocProvider<AuthBloc>.value(
          value: auth,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> action(String label) async {
      await tester.longPress(find.text('Peer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await action('Pin');
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    await action('Mute');
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    await action('Archive');
    expect(find.text('Peer'), findsNothing);
    await tester.tap(find.text('Archived Chats'));
    await tester.pumpAndSettle();
    expect(find.text('Peer'), findsOneWidget);
    await action('Unarchive');
    expect(find.text('Peer'), findsNothing);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('Peer'), findsOneWidget);
    await action('Unpin');
    await action('Unmute');
    expect(saved['pinned'], false);
    expect(saved['muted'], false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    await runMediaTask(tester, repo.dispose);
    await tester.runAsync(auth.close);
  });
  test('pin order, optimistic archive rollback retains concurrent message, mute uses existing API', () async {
    final pending = Completer<ResponseBody>();
    final events = StreamController<ChatEvent>.broadcast(sync: true);
    final adapter = FakeAdapter((r) {
      if (r.method == 'PUT') return pending.future;
      return response(
        envelope({
          'content': [room('new'), room('old', pinned: true)],
          'last': true,
        }),
      );
    });
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      events: events.stream,
    );
    final cubit = RoomsCubit(repo);
    await cubit.load();
    expect(cubit.state.items.map((r) => r.id), ['old', 'new']);
    final original = cubit.state.items.first;
    final update = cubit.update(original, archived: true);
    expect(cubit.state.items.map((r) => r.id), ['new']);
    final message = ChatMessage.fromJson({
      'id': 'm',
      'roomId': 'old',
      'senderId': 'peer',
      'clientMessageId': 'key',
      'type': 'TEXT',
      'content': 'new message',
      'createdAt': '2026-03-01T00:00:00Z',
    });
    events.add(
      ChatEvent(
        'e',
        'old',
        'PERSONAL',
        message,
        room: original.withMessage(message),
      ),
    );
    expect(cubit.state.items.map((r) => r.id), ['new']);
    pending.complete(response({'message': 'Failed'}, status: 500));
    await update;
    expect(cubit.state.items.first.pinned, true);
    expect(cubit.state.items.first.archived, false);
    expect(cubit.state.items.first.lastMessage?.id, 'm');
    expect(cubit.state.error, isNotNull);
    await cubit.update(cubit.state.items.first, muted: true);
    expect(adapter.requests.last.path, endsWith('/notifications'));
    expect(cubit.state.items.first.muted, false);
    await cubit.close();
    await repo.dispose();
    await events.close();
  });

  test(
    'archived pagination and settings events remain private room state',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      final adapter = FakeAdapter(
        (r) => response(
          envelope({
            'content': [room('old', archived: true)],
            'last': true,
          }),
        ),
      );
      final repo = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      );
      final cubit = RoomsCubit(repo, archived: true);
      await cubit.load();
      expect(adapter.requests.single.queryParameters['archived'], true);
      final event = ChatEvent.parse(
        jsonEncode({
          'eventId': 'e',
          'roomId': 'old',
          'roomType': 'PERSONAL',
          'type': 'ROOM_SETTINGS_UPDATED',
          'room': room('old'),
        }),
      );
      expect(event, isNotNull);
      events.add(event!);
      expect(cubit.state.items, isEmpty);
      await cubit.close();
      await repo.dispose();
      await events.close();
    },
  );

  testWidgets(
    'chat tiles expose long press, pin, mute and unread state in both themes',
    (tester) async {
      for (final brightness in Brightness.values) {
        var pressed = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: brightness,
              ),
            ),
            home: Scaffold(
              body: ChatListTile(
                chat: const ChatPreview(
                  'Peer',
                  'Hello',
                  '12:00',
                  pinned: true,
                  muted: true,
                  unread: 3,
                ),
                onTap: () {},
                onLongPress: () {
                  pressed = true;
                },
              ),
            ),
          ),
        );
        await tester.longPress(find.text('Peer'));
        expect(pressed, true);
        expect(find.byIcon(Icons.push_pin), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
      }
    },
  );
}
