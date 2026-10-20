import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/app.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/core/config/app_config.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_realtime.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_socket.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/realtime_session.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/rooms_cubit.dart';

import 'support/fakes.dart';

String token(int seconds) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + seconds})))}.signature';
Future<void> until(bool Function() done) async {
  for (var n = 0; n < 200 && !done(); n++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 10));
Map<String, dynamic> msg(
  String id, {
  String? client,
  String sender = 'bob',
  int minute = 1,
}) => {
  'id': id,
  'roomId': 'room',
  'senderId': sender,
  'clientMessageId': client ?? id,
  'content': 'message $id',
  'senderDisplayName': 'Bob',
  'type': 'TEXT',
  'createdAt': DateTime.utc(2026, 10, 18, 1, minute).toIso8601String(),
};
Map<String, dynamic> room({
  String id = 'room',
  String type = 'PERSONAL',
  Map<String, dynamic>? message,
}) => {
  'id': id,
  'type': type,
  'name': type == 'PERSONAL' ? null : 'Friends',
  'memberCount': 3,
  'participant': type == 'PERSONAL'
      ? {'id': 'bob', 'displayName': 'Bob'}
      : null,
  'lastMessage': message,
  'lastMessageAt': message?['createdAt'],
};
Map<String, dynamic> eventJson(
  Map<String, dynamic> m, {
  String type = 'PERSONAL',
}) => {
  'eventId': m['id'],
  'type': 'MESSAGE_CREATED',
  'roomId': 'room',
  'roomType': type,
  'message': m,
  'room': room(type: type, message: m),
};
ChatEvent event(Map<String, dynamic> m, {String type = 'PERSONAL'}) =>
    ChatEvent.parse(jsonEncode(eventJson(m, type: type)))!;

class FakeSocket implements ChatSocket {
  FakeSocket(this.token, this.callbacks);
  final String token;
  final SocketCallbacks callbacks;
  int starts = 0, closes = 0, subscriptions = 0, unsubscriptions = 0;
  void Function(String)? receive;
  void Function()? ready;
  @override
  void start() {
    starts++;
  }

  @override
  void close() {
    closes++;
  }

  @override
  void Function() subscribe(
    void Function(String) receive,
    void Function() ready,
  ) {
    subscriptions++;
    this.receive = receive;
    this.ready = ready;
    return () {
      unsubscriptions++;
    };
  }
}

class Harness {
  final sockets = <FakeSocket>[];
  String access = token(3600);
  String? rejected;
  late final ChatRealtime realtime = ChatRealtime(
    url: 'ws://localhost/ws',
    retryBase: const Duration(milliseconds: 2),
    retryMax: const Duration(milliseconds: 8),
    jitter: () => 1,
    tokenProvider: ({String? rejectedToken}) async {
      rejected = rejectedToken;
      if (rejectedToken != null) access = token(7200);
      return access;
    },
    factory: (_, token, callbacks) {
      final socket = FakeSocket(token, callbacks);
      sockets.add(socket);
      return socket;
    },
  );
  Future<FakeSocket> connect() async {
    realtime.session('alice');
    await until(() => sockets.isNotEmpty);
    final socket = sockets.last;
    socket.callbacks.connected();
    socket.ready!();
    await tick();
    return socket;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'URL derives emulator WS and production WSS without credentials or query',
    () {
      expect(AppConfig.socketUrl(), 'ws://10.0.2.2:8080/ws');
      expect(
        AppConfig.socketUrl('https://api.example.com/'),
        'wss://api.example.com/ws',
      );
      expect(
        AppConfig.socketUrl(
          'https://api.example.com/base?token=secret#fragment',
        ),
        'wss://api.example.com/base/ws',
      );
      expect(
        () => AppConfig.socketUrl('https://user:password@example.com'),
        throwsArgumentError,
      );
    },
  );
  test(
    'typed events reject malformed, unsupported, and inconsistent payloads',
    () {
      expect(
        ChatEvent.parse(jsonEncode(eventJson(msg('one'))))?.message.id,
        'one',
      );
      for (final body in [
        'not json',
        '[]',
        '{}',
        jsonEncode({'type': 'UNKNOWN'}),
        jsonEncode({...eventJson(msg('one')), 'roomId': 'other'}),
        jsonEncode(eventJson({...msg('one'), 'createdAt': 'invalid'})),
        jsonEncode(eventJson({...msg('one'), 'senderId': null})),
        jsonEncode(eventJson({...msg('one'), 'content': 42})),
        jsonEncode({...eventJson(msg('one')), 'room': room(id: 'wrong')}),
      ]) {
        expect(ChatEvent.parse(body), isNull);
      }
    },
  );
  test('one authenticated connection, subscription readiness, duplicates, logout and stale events', () async {
    final h = Harness();
    final received = <ChatEvent>[];
    final subscription = h.realtime.events.listen(received.add);
    expect(h.sockets, isEmpty);
    h.realtime.session('alice');
    await until(() => h.sockets.isNotEmpty);
    final socket = h.sockets.single;
    socket.callbacks.connected();
    expect(h.realtime.state, ChatConnection.reconnecting);
    socket.callbacks.connected();
    expect(socket.subscriptions, 1);
    socket.ready!();
    expect(h.realtime.state, ChatConnection.connected);
    h.realtime.session('alice');
    expect(h.sockets, hasLength(1));
    socket.receive!(jsonEncode(eventJson(msg('one'))));
    await tick();
    expect(received, hasLength(1));
    h.realtime.session(null);
    expect(socket.closes, 1);
    expect(socket.unsubscriptions, 1);
    socket.callbacks.closed();
    socket.receive!(jsonEncode(eventJson(msg('stale'))));
    await tick();
    expect(received, hasLength(1));
    expect(h.sockets, hasLength(1));
    await subscription.cancel();
    await h.realtime.dispose();
  });
  test('network reconnect resubscribes once; rejected token refreshes; background and account changes stop old sockets', () async {
    final h = Harness();
    final first = await h.connect();
    first.callbacks.closed();
    first.callbacks.closed();
    await until(() => h.sockets.length == 2);
    final second = h.sockets.last;
    second.callbacks.connected();
    second.ready!();
    expect(first.closes, 1);
    expect(second.subscriptions, 1);
    second.callbacks.rejected();
    await until(() => h.sockets.length == 3);
    expect(h.rejected, second.token);
    expect(h.sockets.last.token, isNot(second.token));
    final third = h.sockets.last;
    third.callbacks.connected();
    third.ready!();
    h.realtime.foreground(false);
    expect(third.closes, 1);
    await tick();
    expect(h.sockets, hasLength(3));
    h.realtime.foreground(true);
    await until(() => h.sockets.length == 4);
    h.realtime.session('another');
    await until(() => h.sockets.length == 5);
    expect(h.sockets[3].closes, 1);
    await h.realtime.dispose();
  });
  test('logout while acquiring a token prevents stale connection', () async {
    final pending = Completer<String>();
    int connections = 0;
    final realtime = ChatRealtime(
      url: 'ws://localhost/ws',
      tokenProvider: ({String? rejectedToken}) => pending.future,
      factory: (_, token, callbacks) {
        connections++;
        return FakeSocket(token, callbacks);
      },
    );
    realtime.session('alice');
    realtime.session(null);
    pending.complete(token(3600));
    await tick();
    expect(connections, 0);
    await realtime.dispose();
  });
  test(
    'REST token rotation reconnects a live socket using the new token',
    () async {
      final changes = StreamController<String>.broadcast();
      String access = token(3600);
      final sockets = <FakeSocket>[];
      final realtime = ChatRealtime(
        url: 'ws://localhost/ws',
        tokenChanges: changes.stream,
        tokenProvider: ({String? rejectedToken}) async => access,
        factory: (_, token, callbacks) {
          final s = FakeSocket(token, callbacks);
          sockets.add(s);
          return s;
        },
      );
      realtime.session('alice');
      await until(() => sockets.isNotEmpty);
      sockets.single.callbacks.connected();
      sockets.single.ready!();
      access = token(7200);
      changes.add(access);
      await until(() => sockets.length == 2);
      expect(sockets.first.closes, 1);
      expect(sockets.last.token, access);
      await realtime.dispose();
      await changes.close();
    },
  );
  test(
    'authentication and app lifecycle drive the shared connection',
    () async {
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage)
        ..dio.httpClientAdapter = FakeAdapter(
          (_) => response(envelope(userJson)),
        );
      final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
      final h = Harness();
      final lifecycle = RealtimeSession(auth, h.realtime);
      expect(h.sockets, isEmpty);
      auth.add(const AuthStarted());
      await until(() => h.sockets.isNotEmpty);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(h.sockets.first.closes, 1);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await until(() => h.sockets.length == 2);
      auth.add(const AuthSignOutRequested());
      await until(() => auth.state is AuthUnauthenticated);
      expect(h.realtime.state, ChatConnection.disconnected);
      lifecycle.dispose();
      await auth.close();
    },
  );
  test(
    'socket and concurrent REST 401 share the existing single-flight refresh',
    () async {
      final old = token(-100);
      final fresh = token(3600);
      final storage = MemoryTokens()..tokens = TokenPair(old, 'refresh');
      final client = DioClient(storage);
      final pending = Completer<ResponseBody>();
      int refreshes = 0;
      client.dio.httpClientAdapter = FakeAdapter((r) {
        if (r.path.endsWith('/refresh')) {
          refreshes++;
          return pending.future;
        }
        return r.headers['Authorization'] == 'Bearer $fresh'
            ? response(envelope(userJson))
            : response({}, status: 401);
      });
      final socket = client.auth.socketAccessToken();
      final rest = client.dio.get<dynamic>('/api/v1/auth/me');
      await until(() => refreshes == 1);
      pending.complete(response(envelope(sessionJson(fresh, 'next-refresh'))));
      expect(await socket, fresh);
      await rest;
      expect(refreshes, 1);
    },
  );
  test(
    'late refresh after account change cannot erase the new account',
    () async {
      final storage = MemoryTokens()
        ..tokens = TokenPair(token(-100), 'old-refresh');
      final client = DioClient(storage);
      final pending = Completer<ResponseBody>();
      bool started = false;
      client.dio.httpClientAdapter = FakeAdapter((r) {
        started = true;
        return pending.future;
      });
      final refreshing = client.auth.socketAccessToken();
      final expected = expectLater(refreshing, throwsStateError);
      await until(() => started);
      storage.tokens = TokenPair(token(3600), 'other-account');
      pending.complete(
        response(envelope(sessionJson(token(5000), 'rotated-old'))),
      );
      await expected;
      expect(storage.tokens?.refreshToken, 'other-account');
    },
  );

  for (final type in ['PERSONAL', 'GROUP_PRIVATE', 'GROUP_PUBLIC']) {
    test(
      '$type receives and deduplicates events while preserving another pending message',
      () async {
        final events = StreamController<ChatEvent>.broadcast();
        final pending = Completer<ResponseBody>();
        Map? sentBody;
        final adapter = FakeAdapter((r) {
          if (r.method == 'POST') {
            sentBody = r.data as Map;
            return pending.future;
          }
          return response(envelope({'items': [], 'nextCursor': null}));
        });
        final repository = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          events: events.stream,
        );
        final cubit = ChatCubit(
          repository,
          Conversation.fromRoom(ChatRoom.fromJson(room(type: type))),
          'alice',
        );
        final sending = cubit.send('hello');
        await until(() => sentBody != null);
        events.add(event(msg('incoming'), type: type));
        await tick();
        expect(
          cubit.state.messages.where((m) => m.delivery == Delivery.sending),
          hasLength(1),
        );
        final saved = msg(
          'saved',
          sender: 'alice',
          client: sentBody!['clientMessageId'] as String,
        );
        events.add(event(saved, type: type));
        events.add(event(saved, type: type));
        await tick();
        pending.complete(response({'message': 'Response lost'}, status: 503));
        expect(await sending, isTrue);
        expect(cubit.state.messages, hasLength(2));
        expect(
          cubit.state.messages.every((m) => m.delivery == Delivery.sent),
          isTrue,
        );
        expect(cubit.state.error, isNull);
        await cubit.close();
        await events.close();
      },
    );
  }
  test(
    'reconnect catches up multiple pages and retains the older-history cursor',
    () async {
      final connections = StreamController<ChatConnection>.broadcast();
      bool catchup = false;
      final adapter = FakeAdapter((r) {
        if (!catchup) {
          return response(
            envelope({
              'items': [msg('old', minute: 0)],
              'nextCursor': 'older',
            }),
          );
        }
        final cursor = r.queryParameters['cursor'];
        return response(
          envelope(
            cursor == null
                ? {
                    'items': [msg('new3', minute: 3), msg('new2', minute: 2)],
                    'nextCursor': 'gap',
                  }
                : {
                    'items': [msg('new1'), msg('old', minute: 0)],
                    'nextCursor': 'older',
                  },
          ),
        );
      });
      final cubit = ChatCubit(
        ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          connections: connections.stream,
        ),
        const Conversation(PublicUser('bob', 'Bob'), roomId: 'room'),
        'alice',
      );
      await cubit.load();
      expect(cubit.state.cursor, 'older');
      catchup = true;
      connections.add(ChatConnection.connected);
      await until(() => cubit.state.messages.length == 4);
      expect(cubit.state.messages.map((m) => m.id), [
        'new3',
        'new2',
        'new1',
        'old',
      ]);
      expect(cubit.state.cursor, 'older');
      await cubit.synchronize();
      expect(cubit.state.messages, hasLength(4));
      await cubit.close();
      await connections.close();
    },
  );
  test(
    'first personal event resolves an open draft and inserts a new Home room',
    () async {
      final events = StreamController<ChatEvent>.broadcast();
      final adapter = FakeAdapter(
        (r) => response(
          envelope(
            r.path.endsWith('/messages')
                ? {
                    'items': [msg('first')],
                    'nextCursor': null,
                  }
                : {'content': [], 'last': true},
          ),
        ),
      );
      final repository = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      );
      final chat = ChatCubit(
        repository,
        const Conversation(PublicUser('bob', 'Bob')),
        'alice',
      );
      final rooms = RoomsCubit(repository);
      await rooms.load();
      events.add(event(msg('first')));
      await until(
        () => chat.state.roomId == 'room' && rooms.state.items.length == 1,
      );
      expect(chat.state.messages.single.id, 'first');
      expect(rooms.state.items.single.lastMessage?.id, 'first');
      events.add(event(msg('first')));
      await tick();
      expect(chat.state.messages, hasLength(1));
      expect(rooms.state.items, hasLength(1));
      await chat.close();
      await rooms.close();
      await events.close();
    },
  );
  test('Home events preserve pages, move previews, and ignore older duplicate events', () async {
    final events = StreamController<ChatEvent>.broadcast();
    final adapter = FakeAdapter(
      (r) => response(
        envelope({
          'content': [
            room(id: r.queryParameters['page'] == 0 ? 'other' : 'room'),
          ],
          'last': false,
        }),
      ),
    );
    final rooms = RoomsCubit(
      ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      ),
    );
    await rooms.load();
    await rooms.load();
    events.add(event(msg('new', minute: 5)));
    await tick();
    expect(rooms.state.items.first.id, 'room');
    expect(rooms.state.items, hasLength(2));
    events.add(event(msg('old', minute: 1)));
    await tick();
    expect(rooms.state.items.first.lastMessage?.id, 'new');
    await rooms.synchronize();
    expect(rooms.state.items, hasLength(2));
    await rooms.load();
    expect(adapter.requests.last.queryParameters['page'], 2);
    await rooms.close();
    await events.close();
  });

  test(
    'a REST-confirmed message stays unique after its WebSocket event',
    () async {
      final events = StreamController<ChatEvent>.broadcast();
      late Map<String, dynamic> saved;
      final adapter = FakeAdapter((r) {
        saved = msg(
          'persisted',
          sender: 'alice',
          client: r.data['clientMessageId'] as String,
        );
        return response(
          envelope({'room': room(message: saved), 'message': saved}),
        );
      });
      final cubit = ChatCubit(
        ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          events: events.stream,
        ),
        const Conversation(PublicUser('bob', 'Bob'), roomId: 'room'),
        'alice',
      );
      expect(await cubit.send('Hello'), isTrue);
      events.add(event(saved));
      events.add(event(saved));
      await tick();
      expect(cubit.state.messages, hasLength(1));
      expect(cubit.state.messages.single.delivery, Delivery.sent);
      await cubit.close();
      await events.close();
    },
  );

  testWidgets(
    'incoming messages scroll only when already near the latest message',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      client.dio.httpClientAdapter = FakeAdapter((r) {
        if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
        if (r.path == '/api/v1/chat/rooms') {
          return response(
            envelope({
              'content': [room(type: 'GROUP_PRIVATE')],
              'last': true,
            }),
          );
        }
        return response(
          envelope({
            'items': List.generate(40, (i) => msg('history$i', minute: 40 - i)),
            'nextCursor': null,
          }),
        );
      });
      final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
      final h = Harness();
      await tester.pumpWidget(
        QLinkApp(
          auth: auth,
          theme: ThemeCubit(await SharedPreferences.getInstance()),
          realtime: h.realtime,
        ),
      );
      auth.add(const AuthStarted());
      await tester.pumpAndSettle();
      expect(h.sockets, hasLength(1));
      h.sockets.single.callbacks.connected();
      h.sockets.single.ready!();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Friends'));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(find.byType(ListView));
      final scroll = list.controller!;
      scroll.jumpTo(500);
      await tester.pump();
      h.sockets.single.receive!(
        jsonEncode(eventJson(msg('new', minute: 50), type: 'GROUP_PRIVATE')),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      scroll.jumpTo(20);
      await tester.pump();
      h.sockets.single.receive!(
        jsonEncode(eventJson(msg('newer', minute: 51), type: 'GROUP_PRIVATE')),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(find.text('message newer'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
