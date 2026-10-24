import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_realtime.dart';

void main() {
  test('native STOMP adapter sends CONNECT credentials, waits for receipt, receives JSON and unsubscribes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final frames = <String>[];
    final sockets = <WebSocket>[];
    final gotEvent = Completer<void>();
    final ready = Completer<void>();
    final message = {
      'id': 'message',
      'roomId': 'room',
      'senderId': 'bob',
      'clientMessageId': 'key',
      'senderDisplayName': 'Bob',
      'content': 'Hello',
      'createdAt': '2026-10-18T10:00:00Z',
      'type': 'TEXT',
    };
    final payload = jsonEncode({
      'eventId': 'message',
      'type': 'MESSAGE_CREATED',
      'roomId': 'room',
      'roomType': 'PERSONAL',
      'message': message,
    });
    final serverSubscription = server.listen((request) async {
      expect(request.uri.path, '/ws');
      expect(request.uri.hasQuery, isFalse);
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((data) {
        final frame = data is String ? data : utf8.decode(data as List<int>);
        frames.add(frame);
        if (frame.startsWith('CONNECT')) {
          socket.add('CONNECTED\nversion:1.2\nheart-beat:0,0\n\n\u0000');
        } else if (frame.startsWith('SUBSCRIBE')) {
          final id = RegExp(r'(?:^|\n)id:([^\n]+)').firstMatch(frame)!.group(1);
          expect(frame, contains('destination:/user/queue/chat-events'));
          socket.add('RECEIPT\nreceipt-id:chat-ready\n\n\u0000');
          socket.add(
            'MESSAGE\nsubscription:$id\nmessage-id:message\ndestination:/user/queue/chat-events\ncontent-type:application/json\ncontent-length:${utf8.encode(payload).length}\n\n$payload\u0000',
          );
        } else if (frame.startsWith('DISCONNECT')) {
          final receipt = RegExp(r'receipt:([^\n]+)')
              .firstMatch(frame)
              ?.group(1);
          if (receipt != null) {
            socket.add('RECEIPT\nreceipt-id:$receipt\n\n\u0000');
          }
        }
      });
    });
    final realtime = ChatRealtime(
      url: 'ws://127.0.0.1:${server.port}/ws',
      tokenProvider: ({String? rejectedToken}) async =>
          'application-access-token',
    );
    final events = realtime.events.listen((event) {
      expect(event.message!.content, 'Hello');
      if (!gotEvent.isCompleted) gotEvent.complete();
    });
    final states = realtime.states.listen((state) {
      if (state == ChatConnection.connected && !ready.isCompleted) {
        ready.complete();
      }
    });
    try {
      realtime.session('alice');
      await ready.future.timeout(const Duration(seconds: 5));
      await gotEvent.future.timeout(const Duration(seconds: 5));
      expect(
        frames.first,
        contains('Authorization:Bearer application-access-token'),
      );
      expect(frames.where((f) => f.startsWith('SUBSCRIBE')), hasLength(1));
      realtime.session(null);
      for (
        int n = 0;
        n < 100 && !frames.any((f) => f.startsWith('UNSUBSCRIBE'));
        n++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(frames.any((f) => f.startsWith('UNSUBSCRIBE')), isTrue);
      expect(frames.any((f) => f.startsWith('SEND')), isFalse);
    } finally {
      await events.cancel();
      await states.cancel();
      await realtime.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}
