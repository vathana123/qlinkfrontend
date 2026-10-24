import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../datasources/attachment_picker.dart';
import '../datasources/chat_api.dart';
import '../models/chat_models.dart';
import '../realtime/chat_event.dart';
import 'chat_repository.dart';

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
  bool waiting = true;
  final cancel = CancelToken();
  final done = Completer<bool>();
}

/// Session-only queue shared by chat screens. One text and one media worker:
/// a slow upload cannot hold up text, and navigation does not cancel a send.
class OutgoingQueue {
  OutgoingQueue(this.repository) {
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
  final _updates = StreamController<OutgoingUpdate>.broadcast(sync: true);
  final _revokedRooms = StreamController<String>.broadcast(sync: true);
  Stream<OutgoingUpdate> get updates => _updates.stream;
  Stream<String> get revokedRooms => _revokedRooms.stream;
  final _jobs = <String, _SendJob>{};
  final _running = <_SendJob>{};
  bool _bound = false, _disposed = false;
  String? _account;

  static String conversationKey(String account, Conversation conversation) =>
      '$account:${conversation.isGroup ? 'room:${conversation.roomId}' : 'person:${conversation.recipient?.id}'}';
  String _id(ChatMessage message) =>
      '${message.senderId}:${message.clientMessageId}';

  void setAccount(String? account) {
    if (_disposed || (_bound && _account == account)) return;
    _bound = true;
    _account = account;
    for (final job in _jobs.values) {
      job.cancel.cancel('Account changed');
      if (!job.done.isCompleted) job.done.complete(false);
      if (job.ownsFile) unawaited(_delete(job.ownedPath));
    }
    _jobs.clear();
    _running.clear();
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
      job.cancel.cancel('Group access removed');
      if (!job.done.isCompleted) job.done.complete(false);
      if (job.ownsFile) unawaited(_delete(job.ownedPath));
      _jobs.remove(_id(job.message));
    }
  }

  Future<bool> enqueue(
    Conversation conversation,
    ChatMessage message, {
    PrepareAttachment? prepare,
    bool ownsFile = true,
  }) {
    if (!_bound) setAccount(message.senderId);
    if (_disposed || _account != message.senderId) return Future.value(false);
    final id = _id(message);
    final previous = _jobs[id];
    if (previous != null) {
      if (previous.message.isConfirmed) return Future.value(true);
      if (!previous.done.isCompleted) return previous.done.future;
      // A retry uses the most recent uploaded reference and the same client ID.
      message = previous.message;
      prepare = previous.prepare;
      ownsFile = previous.ownsFile;
    }
    final key = conversationKey(message.senderId, conversation);
    final job = _SendJob(
      key,
      conversation.recipient?.id ?? '',
      previous?.roomId ?? conversation.roomId ?? roomId(key),
      message.withDelivery(
        Delivery.sending,
        localCreatedAt: message.displayTime,
      ),
      prepare,
      ownsFile,
    );
    _jobs[id] = job;
    _publish(job);
    _pump();
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
      if (job.message.isConfirmed) {
        successful = true;
        return;
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
        job.message = job.message.withDelivery(
          Delivery.sending,
          localPath: prepared.path,
          attachment: prepared.metadata,
        );
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
          );
        }
        if (!_current(job)) return;
        job.message = job.message.withDelivery(
          Delivery.sending,
          fileId: fileId,
          progress: 1,
        );
        _publish(job);
      }
      if (!_current(job)) return;
      if (!job.message.isConfirmed) {
        message = job.message;
        final result = await repository.send(
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
          _publish(job);
        }
      }
    } finally {
      if (successful || job.cancel.isCancelled) await _delete(ownedPath);
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
    if (status == 404) return true;
    final body = error.response?.data;
    final details = body is Map ? body['data'] : null;
    return status == 403 &&
        details is Map &&
        details['code'] == 'ROOM_ACCESS_DENIED';
  }

  Future<void> dispose() async {
    setAccount(null);
    _disposed = true;
    await _events.cancel();
    await _updates.close();
    await _revokedRooms.close();
  }
}
