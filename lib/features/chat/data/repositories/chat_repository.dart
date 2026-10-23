import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../datasources/chat_api.dart';
import 'outgoing_queue.dart';
import '../realtime/chat_event.dart';
import '../realtime/chat_realtime.dart';
import '../models/chat_models.dart';

class ChatRepository {
  ChatRepository(
    this.api, {
    ChatRealtime? realtime,
    Stream<ChatEvent>? events,
    Stream<ChatConnection>? connections,
  }) : events = events ?? realtime?.events ?? const Stream.empty(),
       connections = connections ?? realtime?.states ?? const Stream.empty();
  final Stream<ChatEvent> events;
  final Stream<ChatConnection> connections;
  final ChatApi api;
  late final outbox = OutgoingQueue(this);
  void setAccount(String? account) => outbox.setAccount(account);
  Future<void> dispose() => outbox.dispose();

  Future<Uint8List> imageBytes(String fileId, CancelToken cancel) async {
    final response = await api.dio.get<List<int>>(
      '/api/v1/storage/files/$fileId/download',
      options: Options(responseType: ResponseType.bytes),
      cancelToken: cancel,
    );
    return Uint8List.fromList(response.data!);
  }

  Future<void> downloadFile(
    String fileId,
    String path,
    CancelToken cancel,
  ) async {
    await api.dio.download(
      '/api/v1/storage/files/$fileId/download',
      path,
      cancelToken: cancel,
    );
  }

  Future<ResultPage<PublicUser>> search(String keyword, {int page = 0}) async {
    final j = await api.get('users/search', {
      'q': keyword,
      'page': page,
      'size': 20,
    });
    return ResultPage(
      (j['content'] as List)
          .map((v) => PublicUser.fromJson(v as Map<String, dynamic>))
          .toList(),
      j['last'] == false,
    );
  }

  Future<ResultPage<PublicUser>> contacts({int page = 0}) async {
    final j = await api.get('contacts', {'page': page, 'size': 20});
    return ResultPage(
      (j['content'] as List)
          .map((v) => PublicUser.fromJson(v as Map<String, dynamic>))
          .toList(),
      j['last'] == false,
    );
  }

  Future<ChatRoom> createGroup({
    required String name,
    required bool isPublic,
    required bool viewAllMessages,
    required Iterable<String> memberIds,
  }) async => ChatRoom.fromJson(
    await api.post('chat/groups', {
      'name': name.trim(),
      'type': isPublic ? 'GROUP_PUBLIC' : 'GROUP_PRIVATE',
      'messageHistoryVisibility': viewAllMessages
          ? 'VIEW_ALL_MESSAGES'
          : 'VIEW_AFTER_JOIN',
      'memberIds': memberIds.toList(),
    }),
  );

  Future<PublicUser> resolve(String id) async =>
      PublicUser.fromJson(await api.get('users/$id/public'));
  Future<Conversation> conversation(PublicUser user) async {
    final j = await api.get('chat/personal/with/${user.id}');
    return Conversation(
      user,
      roomId: j['exists'] == true ? (j['room'] as Map)['id'] as String : null,
    );
  }

  Future<ResultPage<ChatRoom>> rooms({int page = 0}) async {
    final j = await api.get('chat/rooms', {'page': page, 'size': 20});
    return ResultPage(
      (j['content'] as List)
          .map((v) => ChatRoom.fromJson(v as Map<String, dynamic>))
          .toList(),
      j['last'] == false,
    );
  }

  Future<MessagePage> history(String room, {String? cursor}) async {
    final j = await api.get('chat/rooms/$room/messages', {
      'size': 30,
      'cursor': ?cursor,
    });
    return MessagePage(
      (j['items'] as List)
          .map((v) => ChatMessage.fromJson(v as Map<String, dynamic>))
          .toList(),
      j['nextCursor'] as String?,
    );
  }

  Future<SendResult> send({
    String? roomId,
    required String recipientId,
    required String key,
    required String content,
    String? fileId,
    int? durationMs,
    String type = 'VOICE',
    CancelToken? cancelToken,
  }) async {
    final j = await api.post(
      roomId == null ? 'chat/personal/messages' : 'chat/rooms/$roomId/messages',
      {
        if (roomId == null) 'recipientId': recipientId,
        'clientMessageId': key,
        'content': content,
        if (fileId != null) ...{
          'type': type,
          'fileId': fileId,
          'durationMs': durationMs,
        },
      },
      cancelToken: cancelToken,
    );
    return SendResult(
      ChatRoom.fromJson(j['room'] as Map<String, dynamic>),
      ChatMessage.fromJson(j['message'] as Map<String, dynamic>),
    );
  }
}
