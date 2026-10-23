import 'dart:async';
import 'dart:io';

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
    this.messages = const [],
    this.loading = false,
    this.sending = false,
    this.cursor,
    this.error,
  });
  final String? roomId, cursor, error;
  final List<ChatMessage> messages;
  final bool loading, sending;
}

class ChatCubit extends Cubit<ChatState> {
  ChatCubit(this.repository, this.conversation, this.senderId)
    : super(ChatState(roomId: conversation.roomId)) {
    final drafts = repository.outbox.messages(_draftKey);
    emit(
      ChatState(
        roomId: conversation.roomId ?? repository.outbox.roomId(_draftKey),
        messages: _merge(drafts),
        sending: drafts.any((m) => m.delivery == Delivery.sending),
      ),
    );
    _outgoing = repository.outbox.updates.listen((update) {
      if (update.conversationKey != _draftKey) return;
      _update(roomId: update.roomId, messages: _merge([update.message]));
    });
    _events = repository.events.listen(_received);
    _connections = repository.connections.listen((connection) {
      if (connection == ChatConnection.connected) unawaited(synchronize());
    });
  }
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<OutgoingUpdate> _outgoing;
  late final StreamSubscription<ChatConnection> _connections;
  bool _syncing = false, _syncAgain = false;
  void _received(ChatEvent event) {
    final draftMatch =
        state.roomId == null &&
        event.roomType == 'PERSONAL' &&
        event.room?.participant?.id == conversation.recipient?.id;
    if (event.roomId != state.roomId && !draftMatch) return;
    _update(roomId: event.roomId, messages: _merge([event.message]));
    if (draftMatch) unawaited(synchronize());
  }

  @override
  Future<void> close() async {
    await _events.cancel();
    await _outgoing.cancel();
    await _connections.cancel();
    return super.close();
  }

  final ChatRepository repository;
  final Conversation conversation;
  final String senderId;
  String get _draftKey => OutgoingQueue.conversationKey(senderId, conversation);
  bool _loaded = false;
  void _update({
    String? roomId,
    List<ChatMessage>? messages,
    bool? loading,
    String? cursor,
    bool setCursor = false,
    String? error,
  }) {
    if (isClosed) return;
    emit(
      ChatState(
        roomId: roomId ?? state.roomId,
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
    for (var m in incoming) {
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
    try {
      final page = await repository.history(
        state.roomId!,
        cursor: refresh ? null : state.cursor,
      );
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
      _update(loading: false, error: chatError(e));
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
        if (isClosed) return;
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
      _update(error: chatError(e));
    } finally {
      _syncing = false;
      if (_syncAgain && !isClosed) {
        _syncAgain = false;
        unawaited(synchronize());
      }
    }
  }

  Future<bool> send(String text) async {
    if (isClosed || text.trim().isEmpty || text.length > 4000) {
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
    );
    _update(messages: _merge([message]));
    return _transmit(message);
  }

  Future<bool> sendVoice(String path, int durationMs) async {
    if (isClosed) {
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
      type: 'VOICE',
      durationMs: durationMs,
      localPath: path,
    );
    _update(messages: _merge([message]));
    return _transmit(message);
  }

  Future<bool> sendAttachment(
    String path,
    AttachmentMetadata metadata, {
    PrepareAttachment? prepare,
    bool ownsFile = true,
  }) async {
    // The session queue also accepts files selected before navigation.
    final key = const Uuid().v4();
    final message = ChatMessage(
      id: key,
      senderId: senderId,
      clientMessageId: key,
      content: '',
      createdAt: DateTime.now().toUtc(),
      delivery: Delivery.sending,
      type: metadata.contentType.startsWith('image/') ? 'IMAGE' : 'FILE',
      localPath: path,
      attachment: metadata,
    );
    _update(messages: _merge([message]));
    return _transmit(message, prepare: prepare, ownsFile: ownsFile);
  }

  Future<bool> retry(ChatMessage message) async {
    if (isClosed || message.delivery != Delivery.failed) return false;
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
