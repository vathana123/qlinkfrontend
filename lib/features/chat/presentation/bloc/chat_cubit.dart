import '../../data/datasources/attachment_picker.dart';

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
    this.contextMessageId,
    this.newerCursor,
  });
  final String? roomId, cursor, error;
  final String? contextMessageId, newerCursor;
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
    _syncRequests = repository.syncRequests.listen((room) {
      if (room == state.roomId) unawaited(synchronize());
    });
    _events = repository.events.listen(_received);
    _connections = repository.connections.listen((connection) {
      if (connection == ChatConnection.connected) unawaited(synchronize());
    });
  }
  late final StreamSubscription<String> _syncRequests;
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<OutgoingUpdate> _outgoing;
  late final StreamSubscription<String> _revokedRooms;
  late final StreamSubscription<ChatConnection> _connections;
  bool _syncing = false, _syncAgain = false;
  String? _catchupCursor;
  ChatMessage? _catchupOldest;
  Timer? _catchupTimer;
  String? _contextMessageId, _newerCursor;
  int _navigationGeneration = 0;
  void _received(ChatEvent event) {
    final draftMatch =
        state.roomId == null &&
        event.roomType == 'PERSONAL' &&
        event.room?.participant?.id == conversation.recipient?.id;
    if (event.roomId != state.roomId && !draftMatch) return;
    if (event.type == 'GROUP_REMOVED') {
      repository.outbox.revokeRoom(event.roomId);
      _accessGeneration++;
      _catchupCursor = null;
      _catchupOldest = null;
      _catchupTimer?.cancel();
      _update(
        removed: true,
        messages: [],
        error: 'You no longer have access to this group.',
      );
      return;
    }
    if (event.type == 'GROUP_UPDATED') {
      _accessGeneration++;
      _catchupCursor = null;
      _catchupOldest = null;
      _catchupTimer?.cancel();
      _update(group: event.room, removed: false, loading: false);
      unawaited(synchronize());
      return;
    }
    if (state.removed) return;
    if (_contextMessageId != null &&
        _newerCursor != null &&
        !state.messages.any(
          (m) =>
              m.id == event.message?.id ||
              m.clientMessageId == event.message?.clientMessageId,
        )) {
      // Keep this window contiguous while still invalidating quotes/hidden IDs.
      final ids = state.messages.map((m) => m.id).toSet();
      _update(
        messages: _merge([event.message!])
            .where((m) => ids.contains(m.id) || !m.isConfirmed)
            .toList(),
      );
      return;
    }
    _update(roomId: event.roomId, messages: _merge([event.message!]));
    if (draftMatch) unawaited(synchronize());
  }

  @override
  Future<void> close() async {
    _navigationGeneration++;
    _catchupTimer?.cancel();
    await _syncRequests.cancel();
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

  final _reactionRequests = <String>{};
  Future<void> react(ChatMessage message, String emoji) async {
    if (state.removed ||
        message.deleted ||
        message.hidden ||
        !message.isConfirmed ||
        state.roomId == null ||
        !_reactionRequests.add(message.id)) {
      return;
    }
    final generation = _accessGeneration;
    final original = state.messages
        .where((m) => m.id == message.id)
        .firstOrNull;
    if (original == null) {
      _reactionRequests.remove(message.id);
      return;
    }
    final old = original.reactions.where((r) => r.emoji == emoji).firstOrNull;
    final selected = !(old?.selected ?? false);
    final count = (old?.count ?? 0) + (selected ? 1 : -1);
    final reactions = original.reactions
        .where((r) => r.emoji != emoji)
        .toList();
    if (count > 0) reactions.add(MessageReaction(emoji, count, selected));
    _update(
      messages: _merge([
        original.withDelivery(original.delivery, reactions: reactions),
      ]),
    );
    try {
      final result = await repository.react(
        state.roomId!,
        message.id,
        emoji,
        selected,
        senderId,
      );
      if (!isClosed && generation == _accessGeneration) {
        _update(messages: _merge([result]));
      }
    } catch (e) {
      if (!isClosed && generation == _accessGeneration) {
        _update(messages: _merge([original]), error: chatError(e));
      }
    } finally {
      _reactionRequests.remove(message.id);
    }
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

  /// Replace the visible history with a bounded contiguous window. Never walk
  /// thousands of pages to reach an old search result.
  Future<bool> jumpToMessage(String id) async {
    if (isClosed || state.removed || state.roomId == null) return false;
    final request = ++_navigationGeneration;
    final access = ++_accessGeneration;
    _catchupTimer?.cancel();
    _catchupCursor = null;
    _catchupOldest = null;
    _syncAgain = false;
    _update(loading: true);
    try {
      final window = await repository.messageContext(state.roomId!, id);
      if (isClosed ||
          request != _navigationGeneration ||
          access != _accessGeneration ||
          state.removed) {
        return false;
      }
      final ids = window.items.map((m) => m.id).toSet();
      final newest = window.items.firstOrNull;
      final base = state.messages
          .where(
            (m) =>
                !m.isConfirmed ||
                ids.contains(m.id) ||
                (window.newerCursor == null &&
                    newest != null &&
                    (m.createdAt.isAfter(newest.createdAt) ||
                        (m.createdAt == newest.createdAt &&
                            m.id.compareTo(newest.id) > 0))),
          )
          .toList();
      _contextMessageId = id;
      _newerCursor = window.newerCursor;
      _loaded = true;
      _update(
        messages: _merge(window.items, base: base),
        loading: false,
        cursor: window.olderCursor,
        setCursor: true,
      );
      return state.messages.any((m) => m.id == id && !m.deleted && !m.hidden);
    } catch (e) {
      if (!isClosed &&
          request == _navigationGeneration &&
          access == _accessGeneration) {
        if (_contextMessageId == id) {
          _update(
            messages: state.messages.where((m) => !m.isConfirmed).toList(),
          );
        }
        // A missing target is not evidence that the whole group was revoked.
        if (e is DioException && e.response?.statusCode == 403) {
          _failure(e);
        } else {
          _update(loading: false, error: chatError(e));
        }
      }
      return false;
    } finally {
      if (!isClosed &&
          request == _navigationGeneration &&
          _syncAgain &&
          !state.loading) {
        _syncAgain = false;
        unawaited(synchronize());
      }
    }
  }

  Future<void> loadNewer() async {
    if (isClosed ||
        state.removed ||
        state.loading ||
        _newerCursor == null ||
        state.roomId == null) {
      return;
    }
    final access = _accessGeneration;
    _update(loading: true);
    try {
      final page = await repository.newerHistory(state.roomId!, _newerCursor!);
      if (isClosed || access != _accessGeneration || state.removed) return;
      _newerCursor = page.cursor;
      _update(messages: _merge(page.items), loading: false);
    } catch (e) {
      if (!isClosed && access == _accessGeneration) _failure(e);
    } finally {
      if (!isClosed &&
          access == _accessGeneration &&
          _syncAgain &&
          !state.loading) {
        _syncAgain = false;
        unawaited(synchronize());
      }
    }
  }

  Future<void> returnToLatest() async {
    if (isClosed || state.removed || state.roomId == null) return;
    final request = ++_navigationGeneration;
    final access = ++_accessGeneration;
    _update(loading: true);
    try {
      final page = await repository.history(state.roomId!);
      if (isClosed ||
          request != _navigationGeneration ||
          access != _accessGeneration ||
          state.removed) {
        return;
      }
      _contextMessageId = null;
      _newerCursor = null;
      _loaded = true;
      final ids = page.items.map((m) => m.id).toSet();
      _update(
        messages: _merge(
          page.items,
          base: state.messages
              .where((m) => !m.isConfirmed || ids.contains(m.id))
              .toList(),
        ),
        loading: false,
        cursor: page.cursor,
        setCursor: true,
      );
    } catch (e) {
      if (!isClosed &&
          request == _navigationGeneration &&
          access == _accessGeneration) {
        _failure(e);
      }
    } finally {
      if (!isClosed &&
          request == _navigationGeneration &&
          _syncAgain &&
          !state.loading) {
        _syncAgain = false;
        unawaited(synchronize());
      }
    }
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
      _catchupCursor = null;
      _catchupOldest = null;
      _catchupTimer?.cancel();
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
    if (removed == true) {
      loading = false;
      replyTo = null;
      _contextMessageId = null;
      _newerCursor = null;
      _navigationGeneration++;
    }
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
        contextMessageId: _contextMessageId,
        newerCursor: _newerCursor,
      ),
    );
  }

  List<ChatMessage> _merge(
    Iterable<ChatMessage> incoming, {
    List<ChatMessage>? base,
  }) {
    final all = [...(base ?? state.messages)];
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
      if (isClosed || generation != _accessGeneration || state.removed) {
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
      if (generation == _accessGeneration) _failure(e);
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
    if (_contextMessageId != null) {
      await jumpToMessage(_contextMessageId!);
      return;
    }
    _syncing = true;
    final generation = _accessGeneration;
    try {
      if (state.roomId == null && conversation.recipient != null) {
        final found = await repository.conversation(conversation.recipient!);
        if (isClosed || generation != _accessGeneration) return;
        if (found.roomId == null) return;
        _update(roomId: found.roomId);
      }
      if (state.roomId == null) return;
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
      final oldest = _catchupOldest ?? persisted.firstOrNull;
      final hadHistory = _loaded;
      String? cursor = _catchupCursor;
      var pages = 0;
      var reached = false;
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
        pages++;
        cursor = page.cursor;
        if (oldest == null) {
          reached = true;
          break;
        }
        if (page.items.any(
          (m) =>
              m.createdAt.isBefore(oldest.createdAt) ||
              (m.createdAt == oldest.createdAt &&
                  m.id.compareTo(oldest.id) <= 0),
        )) {
          reached = true;
          break;
        }
      } while (cursor != null && seen.add(cursor) && pages < 10);
      if (!reached && cursor != null) {
        _catchupCursor = cursor;
        _catchupOldest = oldest;
        _catchupTimer?.cancel();
        _catchupTimer = Timer(const Duration(milliseconds: 250), () {
          if (!isClosed) unawaited(synchronize());
        });
      } else {
        _catchupCursor = null;
        _catchupOldest = null;
      }
      _loaded = true;
      // Keep the user's older-history cursor when catching up at the head.
      if (!hadHistory) _update(cursor: cursor, setCursor: true);
    } catch (e) {
      if (generation == _accessGeneration) _failure(e);
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
    AttachmentSource? preparationSource,
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
    return _transmit(
      message,
      prepare: prepare,
      ownsFile: ownsFile,
      preparationSource: preparationSource,
    );
  }

  Future<void> discard(ChatMessage message) async {
    if (message.isConfirmed) return;
    await repository.outbox.discard(message);
    if (!isClosed) {
      _update(
        messages: state.messages
            .where(
              (m) =>
                  !(m.senderId == message.senderId &&
                      m.clientMessageId == message.clientMessageId),
            )
            .toList(),
      );
    }
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
    AttachmentSource? preparationSource,
  }) => repository.outbox.enqueue(
    conversation.isGroup
        ? conversation
        : Conversation(conversation.recipient, roomId: state.roomId),
    message,
    prepare: prepare,
    ownsFile: ownsFile,
    preparationSource: preparationSource,
  );
}
