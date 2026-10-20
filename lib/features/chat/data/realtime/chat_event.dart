import 'dart:convert';

import '../models/chat_models.dart';

class ChatEvent {
  const ChatEvent(
    this.eventId,
    this.roomId,
    this.roomType,
    this.message, {
    this.room,
  });
  final String eventId, roomId, roomType;
  final ChatMessage message;
  final ChatRoom? room;
  static ChatEvent? parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map<String, dynamic> || j['type'] != 'MESSAGE_CREATED') {
        return null;
      }
      bool text(dynamic value) => value is String && value.isNotEmpty;
      if (!text(j['eventId']) ||
          !text(j['roomId']) ||
          !{
            'PERSONAL',
            'GROUP_PRIVATE',
            'GROUP_PUBLIC',
          }.contains(j['roomType'])) {
        return null;
      }
      final m = j['message'];
      if (m is! Map<String, dynamic> ||
          m['roomId'] != j['roomId'] ||
          ![
            'id',
            'senderId',
            'clientMessageId',
            'content',
            'createdAt',
          ].every((key) => text(m[key])) ||
          (m['content'] as String).length > 4000 ||
          (m['type'] != null && m['type'] != 'TEXT') ||
          DateTime.tryParse(m['createdAt'] as String) == null) {
        return null;
      }
      ChatRoom? room;
      if (j['room'] != null) {
        if (j['room'] is! Map<String, dynamic>) return null;
        room = ChatRoom.fromJson(j['room'] as Map<String, dynamic>);
        if (room.id != j['roomId'] ||
            room.type != j['roomType'] ||
            (!room.isGroup && room.participant == null) ||
            (room.isGroup && (room.name ?? '').isEmpty)) {
          return null;
        }
      }
      return ChatEvent(
        j['eventId'] as String,
        j['roomId'] as String,
        j['roomType'] as String,
        ChatMessage.fromJson(m),
        room: room,
      );
    } catch (_) {
      return null;
    }
  }
}
