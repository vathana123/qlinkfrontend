import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:dio/dio.dart';

import '../datasources/chat_api.dart';
import 'outgoing_queue.dart';
import 'outbox_store.dart';
import 'private_media_cache.dart';
import 'voice_playback_controller.dart';
import '../realtime/chat_event.dart';
import '../realtime/chat_realtime.dart';
import '../models/chat_models.dart';
import '../models/search_models.dart';

class ChatRepository {
  ChatRepository(
    this.api, {
    ChatRealtime? realtime,
    OutboxStore? outboxStore,
    Stream<ChatEvent>? events,
    Stream<ChatConnection>? connections,
    Future<Directory> Function()? mediaDirectory,
  }) : outboxStore = outboxStore ?? MemoryOutboxStore(),
       events = events ?? realtime?.events ?? const Stream.empty(),
       connections = connections ?? realtime?.states ?? const Stream.empty() {
    media = PrivateMediaCache(api.dio, directory: mediaDirectory);
    _mediaEvents = this.events.listen((event) {
      if (event.type == 'GROUP_REMOVED') media.invalidateRoom(event.roomId);
      final message = event.message;
      if (message != null && (message.hidden || message.deleted)) {
        media.invalidateMessage(message.id);
      }
    });
    _mediaConnections = this.connections.listen((connection) {
      if (connection == ChatConnection.connected) media.clear();
    });
    _deliveryEvents = this.events.listen((event) {
      final m = event.message;
      if (m != null && event.type != 'MESSAGE_RECEIPT') {
        acknowledge(event.roomId, [m]);
      }
    });
  }
  final Stream<ChatEvent> events;
  final Stream<ChatConnection> connections;
  final _syncRequests = StreamController<String>.broadcast();
  Stream<String> get syncRequests => _syncRequests.stream;
  void requestSynchronization(String room) {
    _syncRequests.add(room);
  }

  void acknowledgeId(String room, String id) {
    if (_account == null) return;
    if (_acknowledged['$room:$id'] == true) return;
    _receipts.putIfAbsent(room, () => {}).putIfAbsent(id, () => false);
    _receiptRetry ??= Timer(const Duration(milliseconds: 150), _flushReceipts);
  }

  Future<ChatRoom> roomById(String id) async =>
      ChatRoom.fromJson(await api.get('chat/rooms/$id'));
  final ChatApi api;
  late final PrivateMediaCache media;
  VoicePlaybackController? _voicePlayback;
  VoicePlaybackController get voicePlayback =>
      _voicePlayback ??= VoicePlaybackController(media);
  void pauseVoiceForRoom(String? roomId) => _voicePlayback?.pauseRoom(roomId);
  late final StreamSubscription<ChatEvent> _mediaEvents;
  late final StreamSubscription<ChatConnection> _mediaConnections;
  Future<SearchPage<T>> _search<T>(
    String path,
    String query,
    T Function(Map<String, dynamic>) parse, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final response = await api.dio.get<dynamic>(
      '/api/v1/$path',
      queryParameters: {'q': query, 'size': 20, 'cursor': ?cursor},
      cancelToken: cancelToken,
      options: Options(extra: {'expectedAccountId': ?_account}),
    );
    final data = Map<String, dynamic>.from(response.data['data'] as Map);
    return SearchPage(
      (data['items'] as List)
          .map((item) => parse(Map<String, dynamic>.from(item as Map)))
          .toList(),
      data['nextCursor'] as String?,
    );
  }

  Future<SearchPage<ChatRoom>> searchRooms(
    String query, {
    String? cursor,
    CancelToken? cancelToken,
  }) => _search(
    'chat/search/rooms',
    query,
    ChatRoom.fromJson,
    cursor: cursor,
    cancelToken: cancelToken,
  );

  Future<SearchPage<MessageMatch>> searchMessages(
    String query, {
    String? roomId,
    String? cursor,
    CancelToken? cancelToken,
  }) => _search(
    roomId == null ? 'chat/search/messages' : 'chat/rooms/$roomId/search',
    query,
    MessageMatch.fromJson,
    cursor: cursor,
    cancelToken: cancelToken,
  );

  Future<MessageContext> messageContext(String room, String message) async {
    final data = await api.get('chat/rooms/$room/messages/$message/context');
    final items = (data['items'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
    _observeMedia(items);
    acknowledge(room, items);
    return MessageContext(
      items,
      data['nextCursor'] as String?,
      data['newerCursor'] as String?,
    );
  }

  Future<MessagePage> newerHistory(String room, String cursor) async {
    final data = await api.get('chat/rooms/$room/messages/newer', {
      'cursor': cursor,
    });
    final items = (data['items'] as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
    _observeMedia(items);
    acknowledge(room, items);
    return MessagePage(items, data['nextCursor'] as String?);
  }

  final OutboxStore outboxStore;
  late final outbox = OutgoingQueue(this);
  late final StreamSubscription<ChatEvent> _deliveryEvents;
  String? _account;
  int _receiptGeneration = 0, _receiptFailures = 0;
  bool _receiptBusy = false;
  Timer? _receiptRetry;
  CancelToken _receiptCancel = CancelToken();
  final _receipts = <String, Map<String, bool>>{};
  final _acknowledged = <String, bool>{};
  void setAccount(String? account) {
    api.dio.options.extra['authenticatedAccountId'] = account;
    if (_account != account) {
      _receiptGeneration++;
      _receiptCancel.cancel('Account changed');
      _receiptCancel = CancelToken();
      _receiptRetry?.cancel();
      _receiptRetry = null;
      _receipts.clear();
      _acknowledged.clear();
      _account = account;
      media.setAccount(account);
    }
    outbox.setAccount(account);
  }

  void _observeMedia(Iterable<ChatMessage> messages) {
    for (final message in messages) {
      if (message.hidden || message.deleted) {
        media.invalidateMessage(message.id);
      }
    }
  }

  void acknowledge(
    String room,
    Iterable<ChatMessage> messages, {
    bool seen = false,
  }) {
    if (_account == null) return;
    for (final m in messages) {
      if (!m.isConfirmed || m.senderId == _account || m.hidden || m.deleted) {
        continue;
      }
      final key = '$room:${m.id}';
      if (_acknowledged[key] == true ||
          (!seen && _acknowledged.containsKey(key))) {
        continue;
      }
      final pending = _receipts.putIfAbsent(room, () => {});
      pending[m.id] = seen || (pending[m.id] ?? false);
    }
    _receiptRetry ??= Timer(const Duration(milliseconds: 150), _flushReceipts);
  }

  Future<void> _flushReceipts() async {
    _receiptRetry = null;
    if (_receiptBusy || _account == null || _receipts.isEmpty) return;
    _receiptBusy = true;
    final generation = _receiptGeneration;
    final account = _account;
    try {
      final room = _receipts.keys.first;
      final pending = _receipts[room]!;
      final seen = pending.values.first;
      final ids = pending.entries
          .where((e) => e.value == seen)
          .take(50)
          .map((e) => e.key)
          .toList();
      try {
        await api.dio.post<dynamic>(
          '/api/v1/chat/rooms/$room/receipts',
          data: {'messageIds': ids, 'seen': seen},
          options: Options(extra: {'expectedAccountId': account}),
          cancelToken: _receiptCancel,
        );
        if (generation != _receiptGeneration) return;
        for (final id in ids) {
          _acknowledged['$room:$id'] = seen;
          if (pending[id] == seen) pending.remove(id);
        }
        if (pending.isEmpty) _receipts.remove(room);
        if (_acknowledged.length > 5000) {
          _acknowledged.remove(_acknowledged.keys.first);
        }
        _receiptFailures = 0;
      } on DioException catch (e) {
        if (generation != _receiptGeneration) return;
        if ([400, 403, 404].contains(e.response?.statusCode)) {
          for (final id in ids) {
            pending.remove(id);
          }
          if (pending.isEmpty) _receipts.remove(room);
        } else {
          _receiptFailures++;
        }
      }
    } finally {
      _receiptBusy = false;
      if (_account != null && _receipts.isNotEmpty) {
        _receiptRetry = Timer(
          Duration(
            seconds: _receiptFailures == 0
                ? 0
                : 1 << _receiptFailures.clamp(1, 6),
          ),
          _flushReceipts,
        );
      }
    }
  }

  Future<void> dispose() async {
    setAccount(null);
    _receiptRetry?.cancel();
    _receiptCancel.cancel();
    await _deliveryEvents.cancel();
    await _mediaEvents.cancel();
    await _mediaConnections.cancel();
    await _voicePlayback?.close();
    await media.dispose();
    await _syncRequests.close();
    await outbox.dispose();
  }

  Future<Uint8List> imageBytes(String fileId, CancelToken cancel) async {
    final photo = await media.photo(fileId);
    if (cancel.isCancelled) throw cancel.cancelError!;
    return photo.bytes;
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
  Future<ChatRoom> group(String id) async =>
      ChatRoom.fromJson(await api.get('chat/groups/$id'));
  Future<List<Map<String, dynamic>>> groupMembers(String id) async {
    final response = await api.dio.get<dynamic>(
      '/api/v1/chat/groups/$id/members',
    );
    return (response.data['data'] as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<void> groupAction(
    String id,
    String method,
    String suffix, [
    Map<String, dynamic>? body,
  ]) async {
    await api.dio.request<dynamic>(
      '/api/v1/chat/groups/$id$suffix',
      data: body,
      options: Options(method: method),
    );
  }

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
    final messages = (j['items'] as List)
        .map((v) => ChatMessage.fromJson(v as Map<String, dynamic>))
        .toList();
    _observeMedia(messages);
    acknowledge(room, messages);
    return MessagePage(messages, j['nextCursor'] as String?);
  }

  Future<SendResult?> committed(
    String key,
    String account,
    CancelToken cancel,
  ) async {
    try {
      final r = await api.dio.get<dynamic>(
        '/api/v1/chat/messages/client/$key',
        options: Options(extra: {'expectedAccountId': account}),
        cancelToken: cancel,
      );
      final j = Map<String, dynamic>.from(r.data['data'] as Map);
      if (j['message'] == null || j['room'] == null) return null;
      return SendResult(
        ChatRoom.fromJson(Map<String, dynamic>.from(j['room'] as Map)),
        ChatMessage.fromJson(Map<String, dynamic>.from(j['message'] as Map)),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        final body = e.response?.data;
        final details = body is Map ? body['data'] : null;
        if (details is Map && details['code'] == 'ROOM_NOT_FOUND') rethrow;
        return null;
      }
      rethrow;
    }
  }

  Future<ChatMessage> editMessage(
    String room,
    ChatMessage message,
    String content,
  ) async {
    final response = await api.dio.patch<dynamic>(
      '/api/v1/chat/rooms/$room/messages/${message.id}',
      data: {'content': content, 'revision': message.revision},
    );
    return ChatMessage.fromJson(
      Map<String, dynamic>.from(response.data['data'] as Map),
    );
  }

  Future<ChatMessage> deleteMessage(
    String room,
    ChatMessage message, {
    required bool everyone,
  }) async {
    final response = await api.dio.delete<dynamic>(
      '/api/v1/chat/rooms/$room/messages/${message.id}',
      queryParameters: {'everyone': everyone},
    );
    media.invalidateMessage(message.id);
    return ChatMessage.fromJson(
      Map<String, dynamic>.from(response.data['data'] as Map),
    );
  }

  Future<SendResult> send({
    String? roomId,
    required String recipientId,
    required String key,
    required String content,
    String? fileId,
    String? replyToId,
    String? expectedAccountId,
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
        'replyToId': ?replyToId,
        if (fileId != null) ...{
          'type': type,
          'fileId': fileId,
          'durationMs': durationMs,
        },
      },
      cancelToken: cancelToken,
      expectedAccountId: expectedAccountId,
    );
    return SendResult(
      ChatRoom.fromJson(j['room'] as Map<String, dynamic>),
      ChatMessage.fromJson(j['message'] as Map<String, dynamic>),
    );
  }
}
