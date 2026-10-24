import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/realtime/chat_event.dart';
import '../../data/realtime/chat_realtime.dart';

import 'package:uuid/uuid.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/repositories/outgoing_queue.dart';
import '../../data/datasources/chat_api.dart';

class ChatState {
  const ChatState({
    this.roomId,
    this.group,
    this.removed = false,
    this.messages = const [],
    this.loading = false,
    this.sending = false,
    this.cursor,
    this.error,
  });
  final String? roomId, cursor, error;
  final ChatRoom? group;
  final bool removed;
  bool get canSend => !removed && (group?.canSend ?? true);
  final List<ChatMessage> messages;
  final bool loading, sending;
}

class ChatCubit extends Cubit<ChatState> {
  ChatCubit(this.repository, this.conversation, this.senderId)
    : super(
        ChatState(roomId: conversation.roomId, group: conversation.groupRoom),
      ) {
    final drafts = repository.outbox.messages(_draftKey);
    emit(
      ChatState(
        roomId: conversation.roomId ?? repository.outbox.roomId(_draftKey),
        group: conversation.groupRoom,
        messages: _merge(drafts),
        sending: drafts.any((m) => m.delivery == Delivery.sending),
      ),
    );
    _outgoing = repository.outbox.updates.listen((update) {
      if (update.conversationKey != _draftKey) return;
      _update(roomId: update.roomId, messages: _merge([update.message]));
    });
    _revokedRooms = repository.outbox.revokedRooms.listen((roomId) {
      if (conversation.isGroup && roomId == state.roomId) {
        _accessGeneration++;
        _update(
          removed: true,
          messages: [],
          error: 'You no longer have access to this group.',
        );
      }
    });
    _events = repository.events.listen(_received);
    _connections = repository.connections.listen((connection) {
      if (connection == ChatConnection.connected) unawaited(synchronize());
    });
  }
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<OutgoingUpdate> _outgoing;
  late final StreamSubscription<String> _revokedRooms;
  late final StreamSubscription<ChatConnection> _connections;
  bool _syncing = false, _syncAgain = false;
  void _received(ChatEvent event) {
    final draftMatch =
        state.roomId == null &&
        event.roomType == 'PERSONAL' &&
        event.room?.participant?.id == conversation.recipient?.id;
    if (event.roomId != state.roomId && !draftMatch) return;
    if (event.type == 'GROUP_REMOVED') {
      repository.outbox.revokeRoom(event.roomId);
      _accessGeneration++;
      _update(
        removed: true,
        messages: [],
        error: 'You no longer have access to this group.',
      );
      return;
    }
    if (event.type == 'GROUP_UPDATED') {
      _accessGeneration++;
      _update(group: event.room, removed: false);
      unawaited(synchronize());
      return;
    }
    if (state.removed) return;
    _update(roomId: event.roomId, messages: _merge([event.message!]));
    if (draftMatch) unawaited(synchronize());
  }

  @override
  Future<void> close() async {
    await _events.cancel();
    await _outgoing.cancel();
    await _revokedRooms.cancel();
    await _connections.cancel();
    return super.close();
  }

  final ChatRepository repository;
  final Conversation conversation;
  final String senderId;
  String get _draftKey => OutgoingQueue.conversationKey(senderId, conversation);
  ChatMessage? replyTo;
  void selectReply(ChatMessage? message) {
    replyTo = message;
    _update();
  }

  Future<bool> editMessage(ChatMessage message, String content) async {
    if (state.roomId == null) return false;
    try {
      final updated = await repository.editMessage(
        state.roomId!,
        message,
        content,
      );
      if (!isClosed) _update(messages: _merge([updated]));
      return true;
    } catch (e) {
      _update(error: chatError(e));
      return false;
    }
  }

  Future<void> deleteMessage(
    ChatMessage message, {
    required bool everyone,
  }) async {
    if (state.roomId == null) return;
    try {
      final updated = await repository.deleteMessage(
        state.roomId!,
        message,
        everyone: everyone,
      );
      if (!isClosed) _update(messages: _merge([updated]));
    } catch (e) {
      _update(error: chatError(e));
    }
  }

  Future<bool> findOriginal(String id) async {
    while (!isClosed && !state.removed) {
      if (state.messages.any((m) => m.id == id)) return true;
      if (state.cursor == null || state.loading || _syncing) return false;
      final cursor = state.cursor;
      await load();
      if (cursor == state.cursor) return false;
    }
    return false;
  }

  final _hiddenIds = <String>{};
  bool _loaded = false;
  int _accessGeneration = 0;
  void _failure(Object e) {
    if (conversation.isGroup &&
        e is DioException &&
        [403, 404].contains(e.response?.statusCode)) {
      if (state.roomId != null) repository.outbox.revokeRoom(state.roomId!);
      _accessGeneration++;
      _update(removed: true, messages: [], loading: false, error: chatError(e));
    } else {
      _update(loading: false, error: chatError(e));
    }
  }

  void _update({
    String? roomId,
    ChatRoom? group,
    bool? removed,
    List<ChatMessage>? messages,
    bool? loading,
    String? cursor,
    bool setCursor = false,
    String? error,
  }) {
    if (isClosed) return;
    if (removed == true) replyTo = null;
    emit(
      ChatState(
        roomId: roomId ?? state.roomId,
        group: group ?? state.group,
        removed: removed ?? state.removed,
        messages: messages ?? state.messages,
        loading: loading ?? state.loading,
        sending: (messages ?? state.messages).any(
          (m) => m.delivery == Delivery.sending,
        ),
        cursor: setCursor ? cursor : state.cursor,
        error: error,
      ),
    );
  }

  List<ChatMessage> _merge(Iterable<ChatMessage> incoming) {
    final all = [...state.messages];
    final changes = incoming.toList();
    for (var m in changes) {
      if (m.hidden) _hiddenIds.add(m.id);
      final index = all.indexWhere(
        (old) =>
            old.id == m.id ||
            (old.senderId == m.senderId &&
                old.clientMessageId == m.clientMessageId),
      );
      if (index >= 0) m = reconcileMessage(all[index], m);
      all.removeWhere(
        (old) =>
            old.id == m.id ||
            (old.senderId == m.senderId &&
                old.clientMessageId == m.clientMessageId),
      );
      all.add(m);
    }
    all.removeWhere((m) => _hiddenIds.contains(m.id));
    for (var i = 0; i < all.length; i++) {
      if (_hiddenIds.contains(all[i].replyToId)) {
        all[i] = all[i].withDelivery(
          all[i].delivery,
          reply: ReplyPreview(
            all[i].replyToId!,
            'Message unavailable',
            unavailable: true,
          ),
        );
        continue;
      }
      final original =
          all.where((m) => m.id == all[i].replyToId).firstOrNull ??
          changes.where((m) => m.id == all[i].replyToId).firstOrNull;
      if (original != null) {
        final current =
            all.where((m) => m.id == original.id).firstOrNull ?? original;
        all[i] = all[i].withDelivery(
          all[i].delivery,
          reply: ReplyPreview.fromMessage(current),
        );
      }
    }
    if (replyTo != null) {
      final changed = changes.where((m) => m.id == replyTo!.id).firstOrNull;
      if (changed != null) {
        replyTo = changed.deleted || changed.hidden ? null : changed;
      }
    }
    return all..sort((a, b) {
      final c = b.displayTime.compareTo(a.displayTime);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
  }

  Future<void> load({bool refresh = false}) async {
    if (_syncing ||
        state.loading ||
        state.roomId == null ||
        (!refresh && _loaded && state.cursor == null)) {
      return;
    }
    _update(loading: true);
    final generation = _accessGeneration;
    try {
      final page = await repository.history(
        state.roomId!,
        cursor: refresh ? null : state.cursor,
      );
      if (generation != _accessGeneration || state.removed) {
        _update(loading: false);
        return;
      }
      _loaded = true;
      for (final message in page.items) {
        repository.outbox.confirm(message, state.roomId!);
      }
      _update(
        messages: _merge(page.items),
        loading: false,
        cursor: page.cursor,
        setCursor: true,
      );
    } catch (e) {
      _failure(e);
    } finally {
      if (_syncAgain && !isClosed) {
        _syncAgain = false;
        unawaited(synchronize());
      }
    }
  }

  Future<void> synchronize() async {
    if (isClosed) return;
    if (_syncing || state.loading) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    try {
      if (state.roomId == null && conversation.recipient != null) {
        final found = await repository.conversation(conversation.recipient!);
        if (isClosed) return;
        if (found.roomId == null) return;
        _update(roomId: found.roomId);
      }
      if (state.roomId == null) return;
      final generation = _accessGeneration;
      if (conversation.isGroup) {
        final group = await repository.group(state.roomId!);
        if (generation != _accessGeneration || isClosed) return;
        _update(group: group, removed: false);
      }
      final persisted = state.messages.where((m) => m.isConfirmed).toList();
      persisted.sort((a, b) {
        final order = a.createdAt.compareTo(b.createdAt);
        return order != 0 ? order : a.id.compareTo(b.id);
      });
      final oldest = persisted.firstOrNull;
      final hadHistory = _loaded;
      String? cursor;
      final seen = <String>{};
      do {
        final page = await repository.history(state.roomId!, cursor: cursor);
        if (isClosed || generation != _accessGeneration || state.removed) {
          return;
        }
        for (final message in page.items) {
          repository.outbox.confirm(message, state.roomId!);
        }
        _update(messages: _merge(page.items));
        cursor = page.cursor;
        if (oldest != null &&
            page.items.any(
              (m) =>
                  m.createdAt.isBefore(oldest.createdAt) ||
                  (m.createdAt == oldest.createdAt &&
                      m.id.compareTo(oldest.id) <= 0),
            )) {
          break;
        }
      } while (cursor != null && seen.add(cursor));
      _loaded = true;
      // Keep the user's older-history cursor when catching up at the head.
      if (!hadHistory) _update(cursor: cursor, setCursor: true);
    } catch (e) {
      _failure(e);
    } finally {
      _syncing = false;
      if (_syncAgain && !isClosed) {
        _syncAgain = false;
        unawaited(synchronize());
      }
    }
  }

  Future<bool> send(String text) async {
    if (isClosed ||
        !state.canSend ||
        text.trim().isEmpty ||
        text.length > 4000) {
      return false;
    }
    final key = const Uuid().v4();
    final message = ChatMessage(
      id: key,
      senderId: senderId,
      clientMessageId: key,
      content: text,
      createdAt: DateTime.now().toUtc(),
      delivery: Delivery.sending,
      replyToId: replyTo?.id,
      reply: replyTo == null ? null : ReplyPreview.fromMessage(replyTo!),
    );
    replyTo = null;
    _update(messages: _merge([message]));
    return _transmit(message);
  }

  Future<bool> sendVoice(String path, int durationMs) async {
    if (isClosed || !state.canSend) {
      try {
        await File(path).delete();
      } catch (_) {}
      return false;
    }
    final key = const Uuid().v4();
    final message = ChatMessage(
      id: key,
      senderId: senderId,
      clientMessageId: key,
      content: '',
      createdAt: DateTime.now().toUtc(),
      delivery: Delivery.sending,
      replyToId: replyTo?.id,
      reply: replyTo == null ? null : ReplyPreview.fromMessage(replyTo!),
      type: 'VOICE',
      durationMs: durationMs,
      localPath: path,
    );
    replyTo = null;
    _update(messages: _merge([message]));
    return _transmit(message);
  }

  Future<bool> sendAttachment(
    String path,
    AttachmentMetadata metadata, {
    PrepareAttachment? prepare,
    bool ownsFile = true,
  }) async {
    if (!state.canSend) {
      if (ownsFile) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      return false;
    }
    // The session queue also accepts files selected before navigation.
    final key = const Uuid().v4();
    final message = ChatMessage(
      id: key,
      senderId: senderId,
      clientMessageId: key,
      content: '',
      createdAt: DateTime.now().toUtc(),
      delivery: Delivery.sending,
      replyToId: replyTo?.id,
      reply: replyTo == null ? null : ReplyPreview.fromMessage(replyTo!),
      type: metadata.contentType.startsWith('image/') ? 'IMAGE' : 'FILE',
      localPath: path,
      attachment: metadata,
    );
    replyTo = null;
    _update(messages: _merge([message]));
    return _transmit(message, prepare: prepare, ownsFile: ownsFile);
  }

  Future<bool> retry(ChatMessage message) async {
    if (isClosed || !state.canSend || message.delivery != Delivery.failed) {
      return false;
    }
    return _transmit(message);
  }

  Future<bool> _transmit(
    ChatMessage message, {
    PrepareAttachment? prepare,
    bool ownsFile = true,
  }) => repository.outbox.enqueue(
    conversation.isGroup
        ? conversation
        : Conversation(conversation.recipient, roomId: state.roomId),
    message,
    prepare: prepare,
    ownsFile: ownsFile,
  );
}
