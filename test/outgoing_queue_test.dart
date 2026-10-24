import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/network/api_endpoints.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';

import 'support/fakes.dart';

const conversation = Conversation(PublicUser('recipient', 'Alex'));

ChatMessage saved(ChatMessage draft) => ChatMessage(
  id: 'server-${draft.clientMessageId}',
  senderId: draft.senderId,
  clientMessageId: draft.clientMessageId,
  content: draft.content,
  createdAt: DateTime.utc(2026),
  type: draft.type,
  fileId: draft.fileId,
  attachment: draft.attachment,
);

ResponseBody accepted(RequestOptions request) {
  final body = request.data as Map;
  return response(
    envelope({
      'room': {
        'id': 'room',
        'participant': {'id': 'recipient', 'displayName': 'Alex'},
      },
      'message': {
        'id': 'server-${body['clientMessageId']}',
        'senderId': 'me',
        'clientMessageId': body['clientMessageId'],
        'content': body['content'],
        'type': body['type'] ?? 'TEXT',
        'fileId': body['fileId'],
        'createdAt': '2026-01-01T00:00:00Z',
      },
    }),
  );
}

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test('transient refresh retains authenticated outbox and owned attachment until retry', () async {
    final storage = MemoryTokens()
      ..tokens = const TokenPair('old-access', 'old-refresh');
    final client = DioClient(storage);
    var recover = false;
    client.dio.httpClientAdapter = FakeAdapter((request) {
      if (request.path == ApiEndpoints.me) {
        return response(envelope({...userJson, 'id': 'me'}));
      }
      if (request.path == ApiEndpoints.refresh) {
        return recover
            ? response(envelope(sessionJson()))
            : response({}, status: 503);
      }
      if (request.headers['Authorization'] != 'Bearer new-access') {
        return response({}, status: 401);
      }
      return accepted(request);
    });
    final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
    client.auth.onSessionExpired = () => auth.add(const AuthSessionExpired());
    final repository = ChatRepository(ChatApi(client.dio));
    final session = auth.stream.listen(
      (state) => repository.setAccount(state.user?.id),
    );
    final ready = auth.stream.firstWhere((state) => state is AuthAuthenticated);
    auth.add(const AuthStarted());
    await ready;
    final folder = await Directory.systemTemp.createTemp(
      'qlink-refresh-outbox-',
    );
    final file = await File('${folder.path}/pending.txt')
        .writeAsString('hello');
    final chat = ChatCubit(repository, conversation, 'me');
    final media = ChatMessage(
      id: 'media',
      clientMessageId: 'media',
      senderId: 'me',
      content: '',
      createdAt: DateTime.now().toUtc(),
      delivery: Delivery.sending,
      type: 'FILE',
      fileId: 'already-uploaded',
      localPath: file.path,
      attachment: const AttachmentMetadata('pending.txt', 'text/plain', 5),
    );
    expect(await chat.send('pending text'), isFalse);
    expect(await repository.outbox.enqueue(conversation, media), isFalse);
    expect(auth.state, isA<AuthAuthenticated>());
    expect(storage.tokens?.refreshToken, 'old-refresh');
    expect(await file.exists(), isTrue);
    expect(chat.state.messages, hasLength(2));
    expect(
      chat.state.messages.every((m) => m.delivery == Delivery.failed),
      isTrue,
    );
    expect(
      chat.state.messages.first.sendError,
      contains('temporarily unavailable'),
    );
    final keys = chat.state.messages.map((m) => m.clientMessageId).toSet();
    recover = true;
    for (final message in chat.state.messages.toList()) {
      expect(await chat.retry(message), isTrue);
    }
    expect(chat.state.messages.map((m) => m.clientMessageId).toSet(), keys);
    expect(chat.state.messages.every((m) => m.isConfirmed), isTrue);
    expect(await file.exists(), isFalse);
    await chat.close();
    await session.cancel();
    await repository.dispose();
    await auth.close();
    await folder.delete(recursive: true);
  });

  test('rapid sends are optimistic, ordered and survive navigation', () async {
    final first = Completer<ResponseBody>();
    final adapter = FakeAdapter(
      (request) =>
          request.data['content'] == 'first' ? first.future : accepted(request),
    );
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
    final chat = ChatCubit(repo, conversation, 'me');
    final a = chat.send('first');
    final b = chat.send('second');
    expect(chat.state.messages, hasLength(2));
    expect(
      chat.state.messages.every((m) => m.delivery == Delivery.sending),
      isTrue,
    );
    await flush();
    expect(adapter.requests, hasLength(1));
    await chat.close();
    final reopened = ChatCubit(repo, conversation, 'me');
    expect(reopened.state.messages, hasLength(2));
    first.complete(accepted(adapter.requests.first));
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(reopened.state.messages.map((m) => m.content), ['second', 'first']);
    expect(
      reopened.state.messages.every((m) => m.delivery == Delivery.sent),
      isTrue,
    );
    expect(adapter.requests.last.path, '/api/v1/chat/rooms/room/messages');
    await reopened.close();
    await repo.dispose();
  });

  for (final echoFirst in [true, false]) {
    test(
      'socket echo ${echoFirst ? 'before' : 'after'} HTTP keeps one message',
      () async {
        final events = StreamController<ChatEvent>.broadcast(sync: true);
        final pending = Completer<ResponseBody>();
        final adapter = FakeAdapter((_) => pending.future);
        final repo = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          events: events.stream,
        );
        final chat = ChatCubit(
          repo,
          const Conversation(PublicUser('recipient', 'Alex'), roomId: 'room'),
          'me',
        );
        final sending = chat.send('hello');
        final draft = chat.state.messages.single;
        final event = ChatEvent('event', 'room', 'PERSONAL', saved(draft));
        await flush();
        if (echoFirst) events.add(event);
        pending.complete(accepted(adapter.requests.single));
        expect(await sending, isTrue);
        events.add(event);
        expect(chat.state.messages, hasLength(1));
        expect(chat.state.messages.single.delivery, Delivery.sent);
        expect(chat.state.messages.single.displayTime, draft.createdAt);
        await chat.close();
        await repo.dispose();
        await events.close();
      },
    );
  }

  test(
    'slow media does not block text; retry reuses upload and logical entry',
    () async {
      final folder = await Directory.systemTemp.createTemp('qlink-queue-test-');
      final file = await File('${folder.path}/example.txt')
          .writeAsString('hello');
      final upload = Completer<ResponseBody>();
      var failMessage = true;
      final adapter = FakeAdapter((request) {
        if (request.path.endsWith('/policy')) {
          return response(
            envelope({
              'maxSizeBytes': 1000,
              'extensions': {'txt': 'text/plain'},
            }),
          );
        }
        if (request.data is FormData) return upload.future;
        if (request.data['fileId'] != null && failMessage) {
          return response({'message': 'private server detail'}, status: 500);
        }
        return accepted(request);
      });
      final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
      final chat = ChatCubit(repo, conversation, 'me');
      final media = chat.sendAttachment(
        file.path,
        const AttachmentMetadata('example.txt', 'text/plain', 5),
      );
      expect(chat.state.messages.single.localPath, file.path);
      expect(await chat.send('text while uploading'), isTrue);
      upload.complete(response(envelope({'id': 'uploaded-file'})));
      expect(await media, isFalse);
      final failed = chat.state.messages.singleWhere((m) => m.isAttachment);
      expect(failed.delivery, Delivery.failed);
      expect(failed.sendError, 'Request failed. Please retry.');
      expect(await file.exists(), isTrue);
      failMessage = false;
      final retry = chat.retry(failed);
      final duplicateRetry = chat.retry(failed);
      expect(await retry, isTrue);
      expect(await duplicateRetry, isTrue);
      expect(chat.state.messages, hasLength(2));
      expect(adapter.requests.where((r) => r.data is FormData), hasLength(1));
      expect(
        adapter.requests.where(
          (r) => r.data is Map && r.data['fileId'] != null,
        ),
        hasLength(2),
      );
      expect(await file.exists(), isFalse);
      await chat.close();
      await repo.dispose();
      await folder.delete(recursive: true);
    },
  );

  test('late confirmation releases retained file after failed HTTP', () async {
    final folder = await Directory.systemTemp.createTemp('qlink-late-test-');
    final file = await File('${folder.path}/example.txt')
        .writeAsString('hello');
    final adapter = FakeAdapter((_) => response({}, status: 503));
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
    final draft = ChatMessage(
      id: 'local',
      senderId: 'me',
      clientMessageId: 'local',
      content: '',
      createdAt: DateTime.now(),
      type: 'FILE',
      fileId: 'uploaded',
      localPath: file.path,
      delivery: Delivery.sending,
    );
    expect(await repo.outbox.enqueue(conversation, draft), isFalse);
    expect(await file.exists(), isTrue);
    repo.outbox.confirm(saved(draft), 'room');
    await flush();
    expect(await file.exists(), isFalse);
    expect(await repo.outbox.enqueue(conversation, draft), isTrue);
    expect(adapter.requests, hasLength(1));
    await repo.dispose();
    await folder.delete(recursive: true);
  });

  test(
    'missing files fail visibly and account switch discards pending work',
    () async {
      final pending = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) => pending.future);
      final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
      final chat = ChatCubit(repo, conversation, 'me');
      final folder = await Directory.systemTemp.createTemp(
        'qlink-missing-test-',
      );
      expect(
        await chat.sendAttachment(
          '${folder.path}/missing.txt',
          const AttachmentMetadata('missing.txt', 'text/plain', 5),
        ),
        isFalse,
      );
      expect(
        chat.state.messages.single.sendError,
        contains('Local file unavailable'),
      );
      final send = chat.send('pending');
      await flush();
      repo.setAccount('another');
      expect(await send, isFalse);
      pending.complete(accepted(adapter.requests.single));
      await flush();
      final reopened = ChatCubit(repo, conversation, 'another');
      expect(reopened.state.messages, isEmpty);
      await reopened.close();
      await chat.close();
      await repo.dispose();
      await folder.delete();
    },
  );

  test('confirmation never regresses and retry clears the prior error', () {
    final draft = ChatMessage(
      id: 'local',
      senderId: 'me',
      clientMessageId: 'key',
      content: 'hello',
      createdAt: DateTime.now(),
      delivery: Delivery.sending,
    );
    final failed = draft.withDelivery(
      Delivery.failed,
      error: 'Network unavailable',
    );
    expect(failed.withDelivery(Delivery.sending).sendError, isNull);
    for (final status in [Delivery.sent, Delivery.delivered, Delivery.seen]) {
      final confirmed = saved(draft).withDelivery(status);
      expect(reconcileMessage(confirmed, failed).delivery, status);
      expect(reconcileMessage(confirmed, saved(draft)).delivery, status);
    }
  });

  test('errors expose validation text, never server traces or tokens', () {
    DioException failure(int status, String message) => DioException(
      requestOptions: RequestOptions(),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(),
        statusCode: status,
        data: {'message': message},
      ),
    );
    expect(
      chatError(failure(400, 'File exceeds upload limit')),
      'File exceeds upload limit',
    );
    for (final message in [
      'Bearer secret',
      'java.lang.Exception',
      'eyJsecret',
    ]) {
      expect(chatError(failure(400, message)), 'Request failed. Please retry.');
    }
    expect(
      chatError(failure(500, 'database credentials')),
      'Request failed. Please retry.',
    );
    expect(
      chatError(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      contains('Connection timeout'),
    );
  });
}
