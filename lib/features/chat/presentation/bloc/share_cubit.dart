import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../data/datasources/attachment_picker.dart';
import '../../data/datasources/chat_api.dart';
import '../../data/models/chat_models.dart';
import '../../data/models/share_draft.dart';
import '../../data/repositories/chat_repository.dart';

class ShareState {
  const ShareState({
    this.rooms = const [],
    this.loading = false,
    this.more = true,
    this.error,
  });
  final List<ChatRoom> rooms;
  final bool loading, more;
  final String? error;
}

class ShareCubit extends Cubit<ShareState> {
  ShareCubit(this.repository) : super(const ShareState());
  final ChatRepository repository;
  int _page = 0;
  Future<void> load() async {
    if (state.loading || !state.more) return;
    emit(ShareState(rooms: state.rooms, loading: true, more: state.more));
    try {
      final page = await repository.rooms(page: _page);
      if (isClosed) return;
      _page++;
      final rooms = {for (final r in state.rooms) r.id: r};
      for (final r in page.items.where((r) => r.canSend)) {
        rooms[r.id] = r;
      }
      emit(ShareState(rooms: rooms.values.toList(), more: page.hasMore));
    } catch (e) {
      if (!isClosed) {
        emit(
          ShareState(rooms: state.rooms, more: state.more, error: chatError(e)),
        );
      }
    }
  }

  /// One UUID per item is persisted by the existing outbox before transmission.
  List<Future<bool>> enqueue(
    ShareDraft draft,
    ChatRoom room,
    String account,
    String text, {
    void Function()? onRetained,
  }) {
    final conversation = Conversation.fromRoom(room);
    final pending = <Future<bool>>[];
    var retained = 0;
    final count = draft.message != null
        ? 1
        : draft.files.length + (text.trim().isEmpty ? 0 : 1);
    void saved() {
      if (++retained == count) onRetained?.call();
    }

    ChatMessage message({
      String content = '',
      String type = 'TEXT',
      SharedFile? file,
      ChatMessage? source,
    }) {
      // A replay after process death uses the same server idempotency keys.
      final item = file == null ? 'text' : 'file:${draft.files.indexOf(file)}';
      final key = draft.id == null
          ? const Uuid().v4()
          : const Uuid().v5(
              Namespace.url.value,
              'qlink-share:$account:${draft.id}:${room.id}:$item',
            );
      return ChatMessage(
        id: key,
        senderId: account,
        clientMessageId: key,
        content: content,
        createdAt: DateTime.now().toUtc(),
        delivery: Delivery.sending,
        type: type,
        fileId: source?.fileId,
        durationMs: source?.durationMs,
        audioSizeBytes: source?.audioSizeBytes,
        attachment:
            source?.attachment ??
            (file == null
                ? null
                : AttachmentMetadata(file.name, file.mime, file.size)),
        localPath: file?.path,
        forwarded: source != null,
        forwardSourceRoom: source == null ? null : draft.sourceRoom,
        forwardSourceId: source?.id,
      );
    }

    if (draft.message case final source?) {
      pending.add(
        repository.outbox.enqueue(
          conversation,
          message(content: source.content, type: source.type, source: source),
          ownsFile: false,
          onRetained: saved,
        ),
      );
    } else {
      if (text.trim().isNotEmpty) {
        pending.add(
          repository.outbox.enqueue(
            conversation,
            message(content: text),
            ownsFile: false,
            onRetained: saved,
          ),
        );
      }
      for (final file in draft.files) {
        final photo = file.mime.startsWith('image/');
        pending.add(
          repository.outbox.enqueue(
            conversation,
            message(type: photo ? 'IMAGE' : 'FILE', file: file),
            ownsFile: false,
            onRetained: saved,
            preparationSource: photo
                ? AttachmentSource.photo
                : AttachmentSource.document,
          ),
        );
      }
    }
    return pending;
  }
}
