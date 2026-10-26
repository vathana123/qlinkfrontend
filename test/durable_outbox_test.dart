import 'dart:async';

import 'package:qlinkfrontend/features/chat/data/realtime/chat_realtime.dart';

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/outbox_store.dart';

import 'support/fakes.dart';

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

const conversation = Conversation(PublicUser('bob', 'Bob'), roomId: 'room');
ChatMessage draft(String type, {String? path}) => ChatMessage(
  id: 'key',
  senderId: 'alice',
  clientMessageId: 'key',
  content: type == 'TEXT' ? 'offline' : '',
  createdAt: DateTime.utc(2026),
  delivery: Delivery.sending,
  type: type,
  localPath: path,
  durationMs: type == 'VOICE' ? 1000 : null,
  attachment: type == 'IMAGE' || type == 'FILE'
      ? const AttachmentMetadata('report.txt', 'text/plain', 8)
      : null,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'secure account records and retained media survive repository restart',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final folder = await Directory.systemTemp.createTemp('outbox-test-');
      final source = File('${folder.path}/source.txt');
      await source.writeAsString('retained');
      final store = SecureOutboxStore(directory: () async => folder);
      final offline = FakeAdapter(
        (r) => response({'message': 'offline'}, status: 503),
      );
      for (final type in ['TEXT', 'IMAGE', 'FILE', 'VOICE']) {
        final repo = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = offline),
          outboxStore: store,
        );
        repo.setAccount('alice');
        expect(
          await repo.outbox.enqueue(
            conversation,
            draft(type, path: type == 'TEXT' ? null : source.path),
            ownsFile: false,
          ),
          isFalse,
        );
        await repo.dispose();
        final saved = await store.read('alice');
        expect(saved, hasLength(1));
        expect(saved.single['message']['clientMessageId'], 'key');
        if (type != 'TEXT') {
          expect(
            await File(saved.single['message']['localPath'] as String).exists(),
            isTrue,
          );
        }
        expect(await store.read('bob'), isEmpty);
        await store.write('alice', []);
      }
      await folder.delete(recursive: true);
    },
  );
  test('restored text automatically retries with original id and excludes other accounts', () async {
    final store = MemoryOutboxStore();
    await store.write('alice', [
      {
        'conversationKey': 'alice:person:bob',
        'recipientId': 'bob',
        'roomId': 'room',
        'recoverable': true,
        'message': draft('TEXT').toPendingJson(),
      },
    ]);
    final adapter = FakeAdapter(
      (r) => response(
        envelope({
          'room': {
            'id': 'room',
            'participant': {'id': 'bob', 'displayName': 'Bob'},
          },
          'message': {
            ...draft('TEXT').toPendingJson(),
            'id': 'server',
            'createdAt': '2026-01-01T00:00:00Z',
          },
        }),
      ),
    );
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      outboxStore: store,
    );
    repo.setAccount('bob');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(adapter.requests, isEmpty);
    repo.setAccount('alice');
    await until(
      () => repo.outbox.messages('alice:person:bob').any((m) => m.isConfirmed),
    );
    expect(adapter.requests.single.data['clientMessageId'], 'key');
    await repo.dispose();
    expect(await store.read('alice'), isEmpty);
  });

  test('offline to online automatically retries and reconciles a lost response before sending', () async {
    final connections = StreamController<ChatConnection>.broadcast(sync: true);
    var online = false;
    var posts = 0;
    final adapter = FakeAdapter((r) {
      if (!online) return response({'message': 'offline'}, status: 503);
      if (r.method == 'GET') {
        return response(
          envelope({
            'room': {
              'id': 'room',
              'participant': {'id': 'bob', 'displayName': 'Bob'},
            },
            'message': {...draft('TEXT').toPendingJson(), 'id': 'committed'},
          }),
        );
      }
      posts++;
      return response({'message': 'Unexpected duplicate'}, status: 500);
    });
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      connections: connections.stream,
    );
    repo.setAccount('alice');
    expect(await repo.outbox.enqueue(conversation, draft('TEXT')), isFalse);
    online = true;
    connections.add(ChatConnection.connected);
    await until(
      () => repo.outbox.messages('alice:person:bob').any((m) => m.isConfirmed),
    );
    expect(posts, 0);
    await repo.dispose();
    await connections.close();
  });
  test(
    'media upload references survive restart and avoid uploading again',
    () async {
      final store = MemoryOutboxStore();
      final saved = draft(
        'FILE',
        path: 'retained-private-file',
      ).withDelivery(Delivery.failed, fileId: 'uploaded-file');
      await store.write('alice', [
        {
          'conversationKey': 'alice:person:bob',
          'recipientId': 'bob',
          'roomId': 'room',
          'attempts': 1,
          'recoverable': true,
          'message': saved.toPendingJson(),
        },
      ]);
      final adapter = FakeAdapter(
        (r) => response(
          envelope({
            'room': {
              'id': 'room',
              'participant': {'id': 'bob', 'displayName': 'Bob'},
            },
            'message': {...saved.toPendingJson(), 'id': 'committed'},
          }),
        ),
      );
      final repo = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        outboxStore: store,
      );
      repo.setAccount('alice');
      await until(
        () =>
            repo.outbox.messages('alice:person:bob').any((m) => m.isConfirmed),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.path, '/api/v1/chat/messages/client/key');
      await repo.dispose();
      expect(await store.read('alice'), isEmpty);
    },
  );

  test('expired upload references retry retained bytes with a fresh stable upload key', () async {
    final folder = await Directory.systemTemp.createTemp('expired-upload-');
    final file = await File('${folder.path}/pending.txt')
        .writeAsString('retained');
    final store = MemoryOutboxStore();
    final stale = draft(
      'FILE',
      path: file.path,
    ).withDelivery(Delivery.failed, fileId: 'expired-file');
    await store.write('alice', [
      {
        'conversationKey': 'alice:person:bob',
        'recipientId': 'bob',
        'roomId': 'room',
        'recoverable': true,
        'message': stale.toPendingJson(),
      },
    ]);
    var uploaded = 0;
    String? uploadKey;
    final connections = StreamController<ChatConnection>.broadcast(sync: true);
    final adapter = FakeAdapter((r) {
      if (r.method == 'GET' && r.path.contains('/messages/client/')) {
        return response({
          'data': {'code': 'MESSAGE_NOT_FOUND'},
        }, status: 404);
      }
      if (r.path.contains('/uploads/')) {
        return response({
          'data': {'code': 'FILE_NOT_FOUND'},
        }, status: 404);
      }
      if (r.path.endsWith('/policy')) {
        return response(
          envelope({
            'maxSizeBytes': 1000,
            'extensions': {'txt': 'text/plain'},
          }),
        );
      }
      if (r.path == '/api/v1/storage/files') {
        uploaded++;
        uploadKey = (r.data as FormData).fields
            .firstWhere((f) => f.key == 'uploadKey')
            .value;
        return response(envelope({'id': 'fresh-file'}));
      }
      if (r.data['fileId'] == 'expired-file') {
        return response({
          'data': {'code': 'FILE_NOT_FOUND'},
        }, status: 404);
      }
      return response(
        envelope({
          'room': {
            'id': 'room',
            'participant': {'id': 'bob', 'displayName': 'Bob'},
          },
          'message': {
            ...stale.toPendingJson(),
            'id': 'server',
            'fileId': 'fresh-file',
          },
        }),
      );
    });
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      outboxStore: store,
      connections: connections.stream,
    );
    repo.setAccount('alice');
    await until(
      () => repo.outbox
          .messages('alice:person:bob')
          .any((m) => m.delivery == Delivery.failed),
    );
    connections.add(ChatConnection.connected);
    await until(
      () => repo.outbox.messages('alice:person:bob').any((m) => m.isConfirmed),
    );
    expect(uploaded, 1);
    expect(uploadKey, isNot('key'));
    expect(
      repo.outbox.messages('alice:person:bob').single.clientMessageId,
      'key',
    );
    await repo.dispose();
    await connections.close();
    await folder.delete(recursive: true);
  });
}
