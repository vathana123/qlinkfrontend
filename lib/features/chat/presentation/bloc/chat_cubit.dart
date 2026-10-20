import 'dart:async';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/realtime/chat_event.dart';
import '../../data/realtime/chat_realtime.dart';

import 'package:uuid/uuid.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
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
    final drafts = repository.voiceDrafts[_draftKey];
    if (drafts != null) {
      emit(ChatState(roomId: conversation.roomId, messages: drafts));
    }
    _events = repository.events.listen(_received);
    _connections = repository.connections.listen((connection) {
      if (connection == ChatConnection.connected) unawaited(synchronize());
    });
  }
  late final StreamSubscription<ChatEvent> _events;
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
    await _connections.cancel();
    return super.close();
  }

  final ChatRepository repository;
  final Conversation conversation;
  final String senderId;
  String get _draftKey =>
      '$senderId:${conversation.isGroup ? conversation.roomId : conversation.recipient?.id}';
  bool _loaded = false;
  void _update({
    String? roomId,
    List<ChatMessage>? messages,
    bool? loading,
    bool? sending,
    String? cursor,
    bool setCursor = false,
    String? error,
  }) {
    final pending = (messages ?? state.messages)
        .where(
          (m) => (m.isVoice || m.isAttachment) && m.delivery != Delivery.sent,
        )
        .toList();
    if (pending.isEmpty) {
      repository.voiceDrafts.remove(_draftKey);
    } else {
      repository.voiceDrafts[_draftKey] = pending;
    }
    if (isClosed) return;
    emit(
      ChatState(
        roomId: roomId ?? state.roomId,
        messages: messages ?? state.messages,
        loading: loading ?? state.loading,
        sending: sending ?? state.sending,
        cursor: setCursor ? cursor : state.cursor,
        error: error,
      ),
    );
  }

  List<ChatMessage> _merge(Iterable<ChatMessage> incoming) {
    final all = [...state.messages];
    for (final m in incoming) {
      final index = all.indexWhere(
        (old) =>
            old.id == m.id ||
            (old.senderId == m.senderId &&
                old.clientMessageId == m.clientMessageId),
      );
      if (index >= 0 &&
          all[index].delivery == Delivery.sent &&
          m.delivery != Delivery.sent) {
        continue;
      }
      all.removeWhere(
        (old) =>
            old.id == m.id ||
            (old.senderId == m.senderId &&
                old.clientMessageId == m.clientMessageId),
      );
      all.add(m);
    }
    return all..sort((a, b) {
      final c = b.createdAt.compareTo(a.createdAt);
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
      final persisted = state.messages
          .where((m) => m.delivery == Delivery.sent)
          .toList();
      final oldest = persisted.isEmpty ? null : persisted.last;
      final hadHistory = _loaded;
      String? cursor;
      final seen = <String>{};
      do {
        final page = await repository.history(state.roomId!, cursor: cursor);
        if (isClosed) return;
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
    if (state.sending || text.trim().isEmpty || text.length > 4000) {
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
    if (isClosed || state.sending) {
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

  Future<bool> sendAttachment(String path, AttachmentMetadata metadata) async {
    if (isClosed || state.sending) return false;
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
    return _transmit(message);
  }

  Future<bool> retry(ChatMessage message) async {
    if (state.sending || message.delivery != Delivery.failed) return false;
    return _transmit(message);
  }

  Future<bool> _transmit(ChatMessage message) async {
    _update(
      sending: true,
      messages: _merge([message.withDelivery(Delivery.sending)]),
    );
    try {
      if (message.isVoice && message.fileId == null) {
        final file = File(message.localPath!);
        final size = await file.length();
        if (size <= 44 || size > 4000000) {
          throw StateError('Invalid recording size');
        }
        final id = await repository.api.uploadVoice(file.path, (sent, total) {
          if (!isClosed) {
            _update(
              messages: _merge([
                message.withDelivery(
                  Delivery.sending,
                  progress: total > 0 ? sent / total : 0,
                ),
              ]),
            );
          }
        });
        message = message.withDelivery(
          Delivery.sending,
          fileId: id,
          progress: 1,
        );
        _update(messages: _merge([message]));
      }
      if (message.isAttachment && message.fileId == null) {
        final file = File(message.localPath!);
        final policy = await repository.api.get('storage/files/policy');
        final metadata = message.attachment!;
        final extension = metadata.originalName.split('.').last.toLowerCase();
        final size = await file.length();
        if (size == 0 ||
            size > (policy['maxSizeBytes'] as int) ||
            !(policy['extensions'] as Map).containsKey(extension)) {
          throw StateError(
            'Unsupported file type or file exceeds the upload limit.',
          );
        }
        final id = await repository.api.uploadAttachment(
          file.path,
          metadata.originalName,
          metadata.contentType,
          (sent, total) {
            if (!isClosed) {
              _update(
                messages: _merge([
                  message.withDelivery(
                    Delivery.sending,
                    progress: total > 0 ? (sent / total).clamp(0, 1) : 0,
                  ),
                ]),
              );
            }
          },
        );
        message = message.withDelivery(
          Delivery.sending,
          fileId: id,
          progress: 1,
        );
        _update(messages: _merge([message]));
      }
      final wasDraft = state.roomId == null;
      final result = await repository.send(
        roomId: state.roomId,
        recipientId: conversation.recipient?.id ?? '',
        key: message.clientMessageId,
        content: message.content,
        fileId: message.fileId,
        durationMs: message.durationMs,
        type: message.type,
      );
      _update(
        roomId: result.room.id,
        messages: _merge([result.message]),
        sending: false,
      );
      if (message.localPath != null) {
        try {
          await File(message.localPath!).delete();
        } catch (_) {}
      }
      if (wasDraft) await load(refresh: true);
      return true;
    } catch (e) {
      final confirmed = state.messages.any(
        (m) =>
            m.senderId == message.senderId &&
            m.clientMessageId == message.clientMessageId &&
            m.delivery == Delivery.sent,
      );
      _update(
        messages: _merge([message.withDelivery(Delivery.failed)]),
        sending: false,
        error: confirmed ? null : chatError(e),
      );
      if (confirmed && message.localPath != null) {
        try {
          await File(message.localPath!).delete();
        } catch (_) {}
      }
      return confirmed;
    }
  }
}
