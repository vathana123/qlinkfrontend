import 'package:file_selector/file_selector.dart';
import 'package:uuid/uuid.dart';

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../datasources/attachment_picker.dart';
import '../datasources/chat_api.dart';
import '../models/chat_models.dart';
import '../realtime/chat_event.dart';
import '../realtime/chat_realtime.dart';
import 'chat_repository.dart';
import 'outbox_store.dart';

typedef PrepareAttachment = Future<PreparedAttachment> Function(
  CancelToken cancel,
);

class OutgoingUpdate {
  const OutgoingUpdate(this.conversationKey, this.message, this.roomId);
  final String conversationKey;
  final ChatMessage message;
  final String? roomId;
}

class _SendJob {
  _SendJob(
    this.conversationKey,
    this.recipientId,
    this.roomId,
    this.message,
    this.prepare,
    this.ownsFile,
  ) : ownedPath = ownsFile ? message.localPath : null;
  final String conversationKey, recipientId;
  String? roomId;
  ChatMessage message;
  PrepareAttachment? prepare;
  bool ownsFile;
  String? ownedPath;
  bool waiting = true, recoverable = true, discarded = false;
  int attempts = 0;
  String? uploadKey;
  AttachmentSource? preparationSource;
  Timer? retry;
  final cancel = CancelToken();
  final done = Completer<bool>();
}

/// Session-only queue shared by chat screens. One text and one media worker:
/// a slow upload cannot hold up text, and navigation does not cancel a send.
class OutgoingQueue {
  OutgoingQueue(this.repository) {
    _connections = repository.connections.listen((state) {
      if (state == ChatConnection.connected) resume();
    });
    _events = repository.events.listen((event) {
      if (event.type == 'GROUP_REMOVED') {
        revokeRoom(event.roomId);
      } else if (event.message != null) {
        confirm(event.message!, event.roomId);
      }
    });
  }
  final ChatRepository repository;
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<ChatConnection> _connections;
  Future<void> _ready = Future.value();
  Future<void>? _writes;
  int _generation = 0;
  final _updates = StreamController<OutgoingUpdate>.broadcast(sync: true);
  final _revokedRooms = StreamController<String>.broadcast(sync: true);
  Stream<OutgoingUpdate> get updates => _updates.stream;
  Stream<String> get revokedRooms => _revokedRooms.stream;
  final _jobs = <String, _SendJob>{};
  final _running = <_SendJob>{};
  bool _bound = false, _disposed = false, _restoreFailed = false;
  String? _account;

  static String conversationKey(String account, Conversation conversation) =>
      '$account:${conversation.isGroup ? 'room:${conversation.roomId}' : 'person:${conversation.recipient?.id}'}';
  String _id(ChatMessage message) =>
      '${message.senderId}:${message.clientMessageId}';

  void setAccount(String? account) {
    if (_disposed || (_bound && _account == account && !_restoreFailed)) return;
    _bound = true;
    _account = account;
    final generation = ++_generation;
    for (final job in _jobs.values) {
      job.retry?.cancel();
      job.cancel.cancel('Account changed');
      if (!job.done.isCompleted) job.done.complete(false);
    }
    _jobs.clear();
    _running.clear();
    _ready = account == null ? Future.value() : _restore(account, generation);
  }

  Future<void> _restore(String account, int generation) async {
    try {
      if (_writes != null) await _writes;
      final rows = await repository.outboxStore.read(account);
      if (_disposed || generation != _generation) return;
      _restoreFailed = false;
      for (final row in rows) {
        final json = Map<String, dynamic>.from(row['message'] as Map);
        if (json['senderId'] != account) continue;
        var message = ChatMessage.fromJson(json).withDelivery(
          Delivery.failed,
          localPath: json['localPath'] as String?,
          error: json['sendError'] as String? ?? 'Waiting to retry.',
        );
        final job =
            _SendJob(
                row['conversationKey'] as String,
                row['recipientId'] as String,
                row['roomId'] as String?,
                message,
                null,
                true,
              )
              ..recoverable = row['recoverable'] != false
              ..attempts = (row['attempts'] as int? ?? 0)
              ..uploadKey = row['uploadKey'] as String?
              ..preparationSource = AttachmentSource.values
                  .where((v) => v.name == row['preparationSource'])
                  .firstOrNull;
        job.waiting = job.recoverable;
        _jobs[_id(message)] = job;
        _publish(job);
      }
      _pump();
    } catch (_) {
      // Keep the encrypted record intact. A new enqueue must not overwrite it.
      if (generation == _generation && !_disposed) _restoreFailed = true;
    }
  }

  Future<void> _persist() {
    final account = _account;
    if (account == null) return Future.value();
    final snapshot = _jobs.values
        .where((j) => !j.message.isConfirmed)
        .map(
          (j) => <String, dynamic>{
            'conversationKey': j.conversationKey,
            'recipientId': j.recipientId,
            'roomId': j.roomId,
            'uploadKey': j.uploadKey,
            'preparationSource': j.preparationSource?.name,
            'recoverable': j.recoverable,
            'attempts': j.attempts,
            'message': j.message.toPendingJson(),
          },
        )
        .toList();
    final previous = _writes;
    Future<void> save() async {
      if (previous != null) await previous.catchError((_) {});
      await repository.outboxStore.write(account, snapshot);
    }

    final write = save();
    _writes = write;
    return write;
  }

  void resume() {
    if (_disposed) return;
    if (_restoreFailed && _account != null) {
      _ready = _restore(_account!, _generation);
      return;
    }
    for (final job in _jobs.values.toList()) {
      if (job.message.delivery == Delivery.failed &&
          job.recoverable &&
          !_running.contains(job)) {
        _retry(job);
      }
    }
  }

  void _retry(_SendJob job) {
    if (!_current(job)) return;
    job.retry?.cancel();
    final next =
        _SendJob(
            job.conversationKey,
            job.recipientId,
            job.roomId,
            job.message.withDelivery(Delivery.sending),
            job.prepare,
            job.ownsFile,
          )
          ..attempts = job.attempts
          ..uploadKey = job.uploadKey
          ..preparationSource = job.preparationSource;
    _jobs[_id(job.message)] = next;
    _publish(next);
    _pump();
  }

  Future<void> discard(ChatMessage message) async {
    final job = _jobs.remove(_id(message));
    if (job == null) return;
    job.discarded = true;
    job.retry?.cancel();
    job.cancel.cancel('Discarded');
    await _persist();
    if (job.ownsFile) await _delete(job.ownedPath);
    if (!job.done.isCompleted) job.done.complete(false);
  }

  List<ChatMessage> messages(String key) => _jobs.values
      .where((job) => job.conversationKey == key)
      .map((job) => job.message)
      .toList();
  String? roomId(String key) => _jobs.values
      .where((job) => job.conversationKey == key && job.roomId != null)
      .map((job) => job.roomId)
      .firstOrNull;

  void revokeRoom(String roomId) {
    _revokedRooms.add(roomId);
    for (final job in _jobs.values.where((j) => j.roomId == roomId).toList()) {
      job.retry?.cancel();
      job.cancel.cancel('Group access removed');
      job.recoverable = false;
      job.waiting = false;
      job.message = job.message.withDelivery(
        Delivery.failed,
        error: 'Conversation unavailable. Pending message retained.',
      );
      if (!job.done.isCompleted) job.done.complete(false);
    }
    unawaited(_persist().catchError((_) {}));
  }

  Future<bool> enqueue(
    Conversation conversation,
    ChatMessage message, {
    PrepareAttachment? prepare,
    bool ownsFile = true,
    AttachmentSource? preparationSource,
    void Function()? onRetained,
  }) async {
    if (!_bound) {
      setAccount(message.senderId);
    } else if (_restoreFailed && _account == message.senderId) {
      setAccount(_account);
    }
    try {
      await _ready;
    } catch (_) {
      return false;
    }
    if (_disposed || _account != message.senderId) return Future.value(false);
    if (_restoreFailed) {
      _updates.add(
        OutgoingUpdate(
          conversationKey(message.senderId, conversation),
          message.withDelivery(
            Delivery.failed,
            error: 'Secure storage unavailable. Tap Retry.',
          ),
          conversation.roomId,
        ),
      );
      return false;
    }
    final id = _id(message);
    final previous = _jobs[id];
    if (previous != null) {
      if (previous.message.isConfirmed) return Future.value(true);
      if (!previous.done.isCompleted) return previous.done.future;
      // A retry uses the most recent uploaded reference and the same client ID.
      message = previous.message;
      prepare = previous.prepare;
      ownsFile = previous.ownsFile;
      preparationSource = previous.preparationSource;
    }
    final key = conversationKey(message.senderId, conversation);
    final job =
        _SendJob(
            key,
            conversation.recipient?.id ?? '',
            previous?.roomId ?? conversation.roomId ?? roomId(key),
            message.withDelivery(
              Delivery.sending,
              localCreatedAt: message.displayTime,
            ),
            prepare,
            ownsFile,
          )
          ..uploadKey = previous?.uploadKey
          ..preparationSource = preparationSource;
    final originalOwnedPath = job.ownsFile ? job.ownedPath : null;
    job.waiting = false;
    _jobs[id] = job;
    _publish(job);
    try {
      if (message.localPath != null && message.fileId == null) {
        final retained = await repository.outboxStore.retain(
          message.senderId,
          message.clientMessageId,
          message.localPath!,
        );
        if (!_current(job)) return false;
        job.ownsFile = job.ownsFile || retained != message.localPath;
        job.ownedPath = retained;
        job.message = job.message.withDelivery(
          Delivery.sending,
          localPath: retained,
        );
      }
      await _persist();
      if (!_current(job)) return false;
      onRetained?.call();
      if (originalOwnedPath != null && originalOwnedPath != job.ownedPath) {
        await _delete(originalOwnedPath);
      }
      job.waiting = true;
      _pump();
    } catch (_) {
      job.recoverable = false;
      job.message = job.message.withDelivery(
        Delivery.failed,
        error: 'Unable to save pending message. Tap Retry.',
      );
      _publish(job);
      if (!job.done.isCompleted) job.done.complete(false);
    }
    return job.done.future;
  }

  bool _current(_SendJob job) =>
      !_disposed &&
      !job.cancel.isCancelled &&
      identical(_jobs[_id(job.message)], job);
  void _publish(_SendJob job) {
    if (_current(job)) {
      _updates.add(
        OutgoingUpdate(job.conversationKey, job.message, job.roomId),
      );
    }
  }

  void confirm(ChatMessage message, String roomId) {
    final job = _jobs[_id(message)];
    if (job == null || !_current(job)) return;
    job.message = reconcileMessage(job.message, message);
    for (final other in _jobs.values.where(
      (j) => j.conversationKey == job.conversationKey,
    )) {
      other.roomId = roomId;
    }
    _publish(job);
    job.retry?.cancel();
    unawaited(_persist().catchError((_) {}));
    // A response may time out before a socket echo or history proves success.
    // The worker has already exited in that case, so release its retained file.
    if (job.done.isCompleted && job.message.isConfirmed && job.ownsFile) {
      unawaited(_delete(job.ownedPath));
    }
  }

  void _pump() {
    if (_disposed) return;
    for (final media in [false, true]) {
      if (_running.any(
        (j) => (j.message.isVoice || j.message.isAttachment) == media,
      )) {
        continue;
      }
      final job = _jobs.values
          .where(
            (j) =>
                j.waiting &&
                (j.message.isVoice || j.message.isAttachment) == media,
          )
          .firstOrNull;
      if (job == null) continue;
      job.waiting = false;
      _running.add(job);
      unawaited(_run(job));
    }
  }

  Future<void> _run(_SendJob job) async {
    var successful = false;
    String? ownedPath = job.ownedPath;
    try {
      if (job.attempts > 0) {
        final committed = await repository.committed(
          job.message.clientMessageId,
          job.message.senderId,
          job.cancel,
        );
        if (!_current(job)) return;
        if (committed != null) {
          if ((job.roomId != null && job.roomId != committed.room.id) ||
              (job.recipientId.isNotEmpty &&
                  committed.room.participant?.id != job.recipientId)) {
            throw StateError(
              'Message identifier belongs to another conversation.',
            );
          }
          confirm(committed.message, committed.room.id);
          successful = true;
          return;
        }
      }
      if (job.attempts > 0 &&
          job.message.fileId == null &&
          (job.message.isVoice || job.message.isAttachment)) {
        final uploaded = await repository.api.findUpload(
          job.uploadKey ?? job.message.clientMessageId,
          job.message.senderId,
          job.cancel,
        );
        if (!_current(job)) return;
        if (uploaded != null) {
          job.message = job.message.withDelivery(
            Delivery.sending,
            fileId: uploaded,
            progress: 1,
          );
          job.prepare = null;
          job.preparationSource = null;
          await _persist();
        }
      }
      // Copy picker/cache files before any network request. All later retries use
      // this account's private copy, including after process death.
      if (job.message.localPath != null && job.message.fileId == null) {
        final retained = await repository.outboxStore.retain(
          job.message.senderId,
          job.message.clientMessageId,
          job.message.localPath!,
        );
        if (!_current(job)) return;
        job.ownsFile = job.ownsFile || retained != job.message.localPath;
        job.message = job.message.withDelivery(
          Delivery.sending,
          localPath: retained,
        );
        job.ownedPath = retained;
      }
      await _persist();
      if (!_current(job)) return;
      if (job.message.isConfirmed) {
        successful = true;
        return;
      }
      if (job.prepare == null &&
          job.preparationSource != null &&
          job.message.fileId == null) {
        job.prepare = (cancel) async {
          final policy = await repository.api.uploadPolicy(cancelToken: cancel);
          return AttachmentPicker().prepare(
            XFile(
              job.message.localPath!,
              name: job.message.attachment!.originalName,
            ),
            job.preparationSource!,
            policy['maxSizeBytes'] as int,
            Map<String, dynamic>.from(policy['extensions'] as Map),
          );
        };
      }
      if (job.prepare != null) {
        final prepared = await job.prepare!(job.cancel);
        ownedPath = prepared.path;
        if (!_current(job)) {
          await _delete(ownedPath);
          return;
        }
        job.ownsFile = true;
        job.ownedPath = prepared.path;
        job.prepare = null;
        job.preparationSource = null;
        job.message = job.message.withDelivery(
          Delivery.sending,
          localPath: prepared.path,
          attachment: prepared.metadata,
        );
        final retained = await repository.outboxStore.retain(
          job.message.senderId,
          job.message.clientMessageId,
          prepared.path,
        );
        job.message = job.message.withDelivery(
          Delivery.sending,
          localPath: retained,
        );
        job.ownedPath = retained;
        if (retained != prepared.path) await _delete(prepared.path);
        await _persist();
        _publish(job);
      }
      var message = job.message;
      if ((message.isVoice || message.isAttachment) && message.fileId == null) {
        if (message.localPath == null) {
          throw StateError('Local file unavailable. Please select it again.');
        }
        final file = File(message.localPath!);
        final size = await file.length();
        if (!_current(job)) return;
        void progress(int sent, int total) {
          if (!_current(job) || job.message.isConfirmed) return;
          job.message = job.message.withDelivery(
            Delivery.sending,
            progress: total > 0 ? (sent / total).clamp(0, 1) : 0,
          );
          _publish(job);
        }

        String fileId;
        if (message.isVoice) {
          if (size <= 44 || size > 4000000) {
            throw StateError('Invalid recording size.');
          }
          fileId = await repository.api.uploadVoice(
            file.path,
            progress,
            cancelToken: job.cancel,
            uploadKey: job.uploadKey ?? message.clientMessageId,
            expectedAccountId: message.senderId,
          );
        } else {
          final policy = await repository.api.uploadPolicy(
            cancelToken: job.cancel,
          );
          if (!_current(job)) return;
          final metadata = message.attachment!;
          final extension = metadata.originalName.split('.').last.toLowerCase();
          if (size == 0 ||
              size > (policy['maxSizeBytes'] as int) ||
              !(policy['extensions'] as Map).containsKey(extension)) {
            throw StateError(
              'Unsupported file type or file exceeds the upload limit.',
            );
          }
          fileId = await repository.api.uploadAttachment(
            file.path,
            metadata.originalName,
            metadata.contentType,
            progress,
            cancelToken: job.cancel,
            uploadKey: job.uploadKey ?? message.clientMessageId,
            expectedAccountId: message.senderId,
          );
        }
        if (!_current(job)) return;
        job.message = job.message.withDelivery(
          Delivery.sending,
          fileId: fileId,
          progress: 1,
        );
        await _persist();
        _publish(job);
      }
      if (!_current(job)) return;
      if (!job.message.isConfirmed) {
        message = job.message;
        final result = message.forwardSourceId != null
            ? await repository.forward(job.roomId!, message, job.cancel)
            : await repository.send(
                expectedAccountId: message.senderId,
                replyToId: job.message.replyToId,
                roomId: job.roomId,
                recipientId: job.recipientId,
                key: message.clientMessageId,
                content: message.content,
                fileId: message.fileId,
                durationMs: message.durationMs,
                type: message.type,
                cancelToken: job.cancel,
              );
        if (!_current(job)) return;
        confirm(result.message, result.room.id);
      }
      successful = true;
    } catch (error) {
      if (_current(job)) {
        if (job.roomId != null && _roomAccessDenied(error)) {
          revokeRoom(job.roomId!);
        } else {
          successful = job.message.isConfirmed;
        }
        if (!successful && _current(job)) {
          job.message = job.message.withDelivery(
            Delivery.failed,
            error: chatError(error),
          );
          final errorBody = error is DioException ? error.response?.data : null;
          final details = errorBody is Map ? errorBody['data'] : null;
          final code = details is Map ? details['code'] : null;
          final expiredUpload =
              error is DioException &&
              (code == 'FILE_NOT_FOUND' || code == 'UPLOAD_CONFLICT') &&
              job.message.localPath != null &&
              (job.message.isAttachment || job.message.isVoice);
          if (expiredUpload) {
            job.uploadKey = const Uuid().v4();
            job.message = job.message.withDelivery(
              Delivery.failed,
              clearFileId: true,
              error: 'Upload expired. Retrying retained file.',
            );
          }
          job.recoverable =
              expiredUpload ||
              error is DioException &&
                  (error.response == null ||
                      [
                        401,
                        408,
                        409,
                        425,
                        429,
                      ].contains(error.response?.statusCode) ||
                      (error.response?.statusCode ?? 0) >= 500);
          job.attempts++;
          _publish(job);
          try {
            await _persist();
          } catch (_) {
            job.recoverable = false;
          }
          if (job.recoverable) {
            final delay = Duration(seconds: 1 << job.attempts.clamp(1, 6));
            job.retry = Timer(delay, () => _retry(job));
          }
        }
      }
    } finally {
      if (successful || job.discarded) {
        if (job.ownsFile) await _delete(job.ownedPath);
        if (ownedPath != job.ownedPath && job.ownsFile) {
          await _delete(ownedPath);
        }
      }
      if (_current(job)) {
        try {
          await _persist();
        } catch (_) {}
      }
      if (!job.done.isCompleted) job.done.complete(successful);
      _running.remove(job);
      // Keep a bounded set of recent confirmations for navigating back before
      // history loads. Pending and failed drafts remain available for retry.
      final completed = _jobs.entries
          .where((e) => e.value.done.isCompleted && e.value.message.isConfirmed)
          .toList();
      for (final entry in completed.take(
        (completed.length - 200).clamp(0, completed.length),
      )) {
        _jobs.remove(entry.key);
      }
      _pump();
    }
  }

  Future<void> _delete(String? path) async {
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  bool _roomAccessDenied(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;

    final body = error.response?.data;
    final details = body is Map ? body['data'] : null;
    return details is Map &&
        ((status == 403 && details['code'] == 'ROOM_ACCESS_DENIED') ||
            (status == 404 && details['code'] == 'ROOM_NOT_FOUND'));
  }

  Future<void> dispose() async {
    setAccount(null);
    _disposed = true;
    await _events.cancel();
    await _connections.cancel();
    if (repository.outboxStore is! MemoryOutboxStore) {
      await _writes?.catchError((_) {});
    }
    await _updates.close();
    await _revokedRooms.close();
  }
}
