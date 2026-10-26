import 'dart:convert';

import '../models/chat_models.dart';

class ChatEvent {
  const ChatEvent(
    this.eventId,
    this.roomId,
    this.roomType,
    this.message, {
    this.room,
    this.type = 'MESSAGE_CREATED',
  });
  final String eventId, roomId, roomType;
  final ChatMessage? message;
  final String type;
  bool get isGroupChange => type.startsWith('GROUP_');
  final ChatRoom? room;
  static ChatEvent? parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map<String, dynamic> ||
          !{
            'MESSAGE_CREATED',
            'MESSAGE_UPDATED',
            'MESSAGE_RECEIPT',
            'MESSAGE_HIDDEN',
            'GROUP_UPDATED',
            'GROUP_REMOVED',
          }.contains(j['type'])) {
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
      if ((j['type'] as String).startsWith('GROUP_')) {
        if (j['roomType'] == 'PERSONAL') return null;
        ChatRoom? room;
        if (j['type'] == 'GROUP_UPDATED') {
          if (j['room'] is! Map<String, dynamic>) return null;
          room = ChatRoom.fromJson(j['room'] as Map<String, dynamic>);
          if (room.id != j['roomId'] ||
              room.type != j['roomType'] ||
              room.myRole == null) {
            return null;
          }
        }
        return ChatEvent(
          j['eventId'] as String,
          j['roomId'] as String,
          j['roomType'] as String,
          null,
          room: room,
          type: j['type'] as String,
        );
      }
      if (m is! Map<String, dynamic> ||
          m['roomId'] != j['roomId'] ||
          ![
            'id',
            'senderId',
            'clientMessageId',
            'createdAt',
          ].every((key) => text(m[key])) ||
          m['content'] is! String ||
          (m['content'] as String).length > 4000 ||
          DateTime.tryParse(m['createdAt'] as String) == null) {
        return null;
      }
      bool positiveInt(dynamic value) => value is int && value > 0;
      final content = m['content'] as String;
      // Missing type retains the existing legacy TEXT behavior.
      if (m['hidden'] != true && m['removedAt'] == null) {
        switch (m['type'] ?? 'TEXT') {
          case 'TEXT':
            if (content.trim().isEmpty) return null;
          case 'VOICE':
            if (content.isNotEmpty ||
                !text(m['fileId']) ||
                !positiveInt(m['durationMs']) ||
                !text(m['audioContentType']) ||
                !positiveInt(m['audioSizeBytes'])) {
              return null;
            }
          case 'IMAGE':
          case 'FILE':
            final attachment = m['attachment'];
            if (content.isNotEmpty ||
                !text(m['fileId']) ||
                attachment is! Map<String, dynamic> ||
                !text(attachment['originalName']) ||
                !text(attachment['contentType']) ||
                !positiveInt(attachment['sizeBytes'])) {
              return null;
            }
          default:
            return null;
        }
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
        type: j['type'] as String,
        room: room,
      );
    } catch (_) {
      return null;
    }
  }
}
