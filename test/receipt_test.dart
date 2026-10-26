import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';

void main() {
  test(
    'receipt updates preserve Seen across older socket and REST messages',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      final repo = ChatRepository(ChatApi(Dio()), events: events.stream);
      final chat = ChatCubit(
        repo,
        const Conversation(PublicUser('bob', 'Bob'), roomId: 'room'),
        'alice',
      );
      Map<String, dynamic> message(String status) => {
        'id': 'm',
        'roomId': 'room',
        'senderId': 'alice',
        'clientMessageId': 'key',
        'content': 'hello',
        'createdAt': '2026-10-24T01:00:00Z',
        'delivery': status,
      };
      for (final status in ['SENT', 'DELIVERED', 'SEEN', 'SENT']) {
        final e = ChatEvent.parse(
          jsonEncode({
            'eventId': status,
            'type': 'MESSAGE_RECEIPT',
            'roomId': 'room',
            'roomType': 'PERSONAL',
            'message': message(status),
          }),
        )!;
        expect(e.isGroupChange, isFalse);
        events.add(e);
      }
      expect(chat.state.messages.single.delivery, Delivery.seen);
      expect(chat.state.messages.single.statusText, 'Seen');
      await chat.close();
      await repo.dispose();
      await events.close();
    },
  );
}
