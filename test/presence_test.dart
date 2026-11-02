import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/activity_event.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_realtime.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_socket.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';

import 'support/fakes.dart';

class ActivityWire implements ChatSocket, ActivitySocket {
  ActivityWire(this.callbacks);
  final SocketCallbacks callbacks;
  void Function()? ready;
  void Function()? activityReady;
  bool autoReady = true;
  void Function(String)? receive;
  final sent = <(String, Map<String, dynamic>)>[];
  @override
  void start() {}
  @override
  void close() {}
  @override
  void Function() subscribe(
    void Function(String) receive,
    void Function() ready,
  ) {
    this.ready = ready;
    return () {};
  }

  @override
  void Function() subscribeActivity(
    void Function(String) receive,
    void Function() ready,
  ) {
    this.receive = receive;
    activityReady = ready;
    if (autoReady) ready();
    return () {};
  }

  @override
  void sendActivity(String action, Map<String, dynamic> payload) =>
      sent.add((action, payload));
}

Future<void> tick([Duration delay = const Duration(milliseconds: 10)]) =>
    Future<void>.delayed(delay);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('presence watches wait for the activity subscription receipt', () async {
    late ActivityWire wire;
    final realtime = ChatRealtime(
      url: 'ws://test',
      tokenProvider: ({String? rejectedToken}) async => 'test',
      factory: (_, _, callbacks) =>
          wire = ActivityWire(callbacks)..autoReady = false,
    );
    realtime.session('alice');
    await tick();
    realtime.watch('bob', true, account: 'alice');
    wire.callbacks.connected();
    wire.ready!();
    await tick(const Duration(milliseconds: 300));
    expect(wire.sent, isEmpty);
    wire.activityReady!();
    expect(wire.sent.single.$2, {
      'userIds': ['bob'],
    });
    await realtime.dispose();
  });
  test(
    'activity rejects malformed payloads and preserves redacted presence',
    () {
      expect(ActivityEvent.parse('{}'), isNull);
      expect(
        ActivityEvent.parse(
          '{"type":"TYPING","userId":"a","roomId":"r","typing":true}',
        ),
        isNull,
      );
      final hidden = ActivityEvent.parse(
        '{"type":"PRESENCE","userId":"a","online":null,"lastSeenAt":null}',
      );
      expect(hidden!.online, isNull);
      expect(hidden.lastSeenAt, isNull);
    },
  );

  test('typing throttles, expires, isolates rooms and clears on disconnect; reconnect restores watches', () async {
    final wires = <ActivityWire>[];
    final realtime = ChatRealtime(
      url: 'ws://test',
      tokenProvider: ({String? rejectedToken}) async => 'test',
      factory: (_, _, callbacks) {
        final wire = ActivityWire(callbacks);
        wires.add(wire);
        return wire;
      },
    );
    final repo = ChatRepository(
      ChatApi(
        Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => response(envelope({'items': [], 'nextCursor': null})),
          ),
      ),
      realtime: realtime,
    );
    addTearDown(realtime.dispose);
    addTearDown(repo.dispose);
    void expectAction(String action, Map<String, dynamic> payload) {
      expect(wires.last.sent.last.$1, action);
      expect(wires.last.sent.last.$2, payload);
    }

    realtime.session('alice');
    await tick();
    wires.last.callbacks.connected();
    wires.last.ready!();
    await tick();
    final chat = ChatCubit(
      repo,
      const Conversation(PublicUser('bob', 'Bob'), roomId: 'room'),
      'alice',
    );
    await tick(const Duration(milliseconds: 300));
    expectAction('watch', {
      'userIds': ['bob'],
    });
    chat.composing(true);
    chat.composing(true);
    chat.composing(true);
    expect(wires.last.sent.where((e) => e.$1 == 'typing').length, 1);
    await tick(const Duration(seconds: 3));
    expectAction('typing', {'roomId': 'room', 'typing': false});
    void typing(String room) => wires.last.receive!(
      jsonEncode({
        'type': 'TYPING',
        'userId': 'bob',
        'roomId': room,
        'typing': true,
        'expiresAt': DateTime.now()
            .add(const Duration(seconds: 2))
            .toIso8601String(),
      }),
    );
    typing('other');
    await tick();
    expect(chat.state.typing, isFalse);
    typing('room');
    await tick();
    expect(chat.state.typing, isTrue);
    await tick(const Duration(seconds: 3));
    expect(chat.state.typing, isFalse);
    wires.last.receive!('{"type":"PRESENCE","userId":"bob","online":true}');
    await tick();
    expect(chat.state.presence!.online, isTrue);
    final stale = wires.last.receive!;
    realtime.foreground(false);
    await tick();
    expect(chat.state.presence, isNull);
    expect(chat.state.typing, isFalse);
    stale('{"type":"PRESENCE","userId":"bob","online":true}');
    await tick();
    expect(chat.state.presence, isNull);
    realtime.foreground(true);
    await tick();
    wires.last.callbacks.connected();
    wires.last.ready!();
    await tick();
    expectAction('watch', {
      'userIds': ['bob'],
    });
    await chat.close();
    await tick(const Duration(milliseconds: 300));
    expectAction('watch', {'userIds': <String>[]});
    realtime.session('another');
    await tick();
    wires.last.callbacks.connected();
    wires.last.ready!();
    await tick();
    expectAction('watch', {'userIds': <String>[]});
  });
}
