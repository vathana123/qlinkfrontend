import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/app.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/models/share_draft.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/external_share_intake.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/outbox_store.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/share_cubit.dart';

import 'message_actions_test.dart' as fixture;
import 'support/fakes.dart';

Map<String, dynamic> reacted(int revision, int count, bool mine) => {
  ...fixture.message('m', revision: revision),
  'reactions': [
    if (count > 0) {'emoji': '👍', 'count': count, 'selected': mine},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'lost forward source permission does not revoke the destination',
    () async {
      final adapter = FakeAdapter(
        (r) => response({
          'message': 'Original message is no longer available',
          'data': {'code': 'FORWARD_SOURCE_UNAVAILABLE'},
        }, status: 403),
      );
      final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
      repo.setAccount('user-1');
      final revoked = <String>[];
      final subscription = repo.outbox.revokedRooms.listen(revoked.add);
      final share = ShareCubit(repo);
      final work = share.enqueue(
        ShareDraft(
          message: ChatMessage.fromJson(fixture.message('source')),
          sourceRoom: 'source-room',
        ),
        ChatRoom.fromJson(fixture.room()),
        'user-1',
        '',
      );
      expect(await work.single, isFalse);
      expect(revoked, isEmpty);
      await subscription.cancel();
      await share.close();
      await repo.dispose();
    },
  );
  testWidgets(
    'cold share waits for authentication; preview send and warm cancellation preserve navigation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('qlink/share');
      Map<String, Object?>? incoming = {
        'id': 'external-1',
        'text': 'Shared text',
        'files': [],
      };
      var reads = 0, discards = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'pending') {
              reads++;
              return incoming;
            }
            if (call.method == 'discard') {
              discards++;
              incoming = null;
            }
            return null;
          });
      final storage = MemoryTokens();
      final client = DioClient(storage);
      Map<String, dynamic>? sent;
      final adapter = FakeAdapter((r) {
        if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
        if (r.path == '/api/v1/chat/rooms') {
          return response(
            envelope({
              'content': [fixture.room()],
              'last': true,
            }),
          );
        }
        if (r.method == 'POST' && r.path.endsWith('/messages')) {
          sent = {
            ...fixture.message('shared'),
            'clientMessageId': r.data['clientMessageId'],
            'content': r.data['content'],
          };
          return response(
            envelope({'room': fixture.room(sent), 'message': sent}),
          );
        }
        return response(
          envelope({
            'items': [?sent],
            'nextCursor': null,
          }),
        );
      });
      client.dio.httpClientAdapter = adapter;
      final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
      await tester.pumpWidget(
        QLinkApp(
          auth: auth,
          theme: ThemeCubit(await SharedPreferences.getInstance()),
        ),
      );
      auth.add(const AuthStarted());
      await tester.pumpAndSettle();
      expect(reads, 0);
      expect(find.text('Share to qLink'), findsNothing);
      storage.tokens = const TokenPair('access', 'refresh');
      auth.add(const AuthStarted());
      await tester.pumpAndSettle();
      expect(find.text('Share to qLink'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Shared text',
      );
      await tester.enterText(find.byType(TextField), 'Reviewed shared text');
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to Bob'));
      await tester.pumpAndSettle();
      expect(sent!['content'], 'Reviewed shared text');
      expect(discards, 1);
      expect(find.text('Reviewed shared text'), findsOneWidget);
      incoming = {'id': 'external-2', 'text': 'Cancel this', 'files': []};
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'qlink/share',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('available'),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.text('Share to qLink'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(discards, 2);
      expect(find.text('Reviewed shared text'), findsOneWidget);
      expect(
        adapter.requests.where(
          (r) => r.method == 'POST' && r.path.endsWith('/messages'),
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  test(
    'external share replay uses stable keys scoped to account and destination',
    () async {
      final keys = <String>[];
      final adapter = FakeAdapter((r) {
        keys.add(r.data['clientMessageId'] as String);
        return response(
          envelope({
            'room': fixture.room(),
            'message': {
              ...fixture.message('sent'),
              'clientMessageId': r.data['clientMessageId'],
              'content': r.data['content'],
            },
          }),
        );
      });
      final draft = ShareDraft.fromPlatform({
        'id': 'persistent-share',
        'text': 'Hello',
      });
      for (var run = 0; run < 2; run++) {
        final repo = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
        );
        repo.setAccount('user-1');
        final share = ShareCubit(repo);
        var retained = false;
        expect(
          await share
              .enqueue(
                draft,
                ChatRoom.fromJson(fixture.room()),
                'user-1',
                draft.text,
                onRetained: () => retained = true,
              )
              .single,
          isTrue,
        );
        expect(retained, isTrue);
        await share.close();
        await repo.dispose();
      }
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
      repo.setAccount('other');
      final share = ShareCubit(repo);
      await share
          .enqueue(
            draft,
            ChatRoom.fromJson(fixture.room()),
            'other',
            draft.text,
          )
          .single;
      expect(keys.last, isNot(keys.first));
      await share.close();
      await repo.dispose();
    },
  );
  test(
    'reaction optimism, duplicate taps, realtime revision and failure rollback',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      var pending = Completer<ResponseBody>();
      final adapter = FakeAdapter(
        (r) => r.method == 'PUT'
            ? pending.future
            : response(
                envelope({
                  'items': [fixture.message('m')],
                  'nextCursor': null,
                }),
              ),
      );
      final repo = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      );
      final chat = ChatCubit(repo, fixture.conversation, 'user-1');
      await chat.load();
      final first = chat.react(chat.state.messages.single, '👍');
      expect(chat.state.messages.single.reactions.single.selected, isTrue);
      await chat.react(chat.state.messages.single, '👍');
      await fixture.tick();
      expect(adapter.requests.where((r) => r.method == 'PUT'), hasLength(1));
      expect(adapter.requests.last.extra['expectedAccountId'], 'user-1');
      events.add(fixture.event(reacted(2, 2, true)));
      pending.complete(response(envelope(reacted(1, 1, true))));
      await first;
      expect(chat.state.messages.single.reactions.single.count, 2);
      pending = Completer<ResponseBody>();
      final remove = chat.react(chat.state.messages.single, '👍');
      expect(chat.state.messages.single.reactions.single.selected, isFalse);
      pending.complete(response({}, status: 403));
      await remove;
      expect(chat.state.messages.single.reactions.single.selected, isTrue);
      expect(chat.state.error, isNotNull);
      await chat.close();
      await repo.dispose();
      await events.close();
    },
  );

  test(
    'reaction updates synchronize two open chats without history reload',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      final adapter = FakeAdapter(
        (r) => response(
          envelope({
            'items': [fixture.message('m')],
            'nextCursor': null,
          }),
        ),
      );
      final repo = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      );
      final first = ChatCubit(repo, fixture.conversation, 'user-1');
      final second = ChatCubit(repo, fixture.conversation, 'user-1');
      await first.load();
      await second.load();
      events.add(fixture.event(reacted(1, 3, true)));
      expect(first.state.messages.single.reactions.single.count, 3);
      expect(second.state.messages.single.reactions.single.selected, isTrue);
      expect(adapter.requests, hasLength(2));
      events.add(
        fixture.event(fixture.message('m', deleted: true, revision: 2)),
      );
      expect(first.state.messages.single.reactions, isEmpty);
      await first.close();
      await second.close();
      await repo.dispose();
      await events.close();
    },
  );

  test(
    'all forwarded types persist source, retry same key and never upload',
    () async {
      for (final type in ['TEXT', 'IMAGE', 'VOICE', 'FILE']) {
        final store = MemoryOutboxStore();
        var fail = true;
        final adapter = FakeAdapter((r) {
          if (r.method == 'GET') return response({}, status: 404);
          if (fail) return response({}, status: 503);
          return response(
            envelope({
              'room': fixture.room(),
              'message': {
                ...fixture.message('forwarded'),
                'clientMessageId': r.data['clientMessageId'],
                'type': type,
                'forwarded': true,
                if (type != 'TEXT') 'fileId': 'file',
              },
            }),
          );
        });
        var repo = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          outboxStore: store,
        );
        repo.setAccount('user-1');
        final source = ChatMessage.fromJson({
          ...fixture.message('source'),
          'type': type,
          if (type != 'TEXT') 'fileId': 'file',
        });
        var share = ShareCubit(repo);
        final work = share.enqueue(
          ShareDraft(message: source, sourceRoom: 'original-room'),
          ChatRoom.fromJson(fixture.room()),
          'user-1',
          '',
        );
        expect(await work.single, isFalse);
        final rows = await store.read('user-1');
        final key = (rows.single['message'] as Map)['clientMessageId'];
        expect((rows.single['message'] as Map)['forwardSourceId'], 'source');
        await share.close();
        await repo.dispose();
        fail = false;
        repo = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          outboxStore: store,
        );
        repo.setAccount('user-1');
        for (
          var i = 0;
          i < 50 && (await store.read('user-1')).isNotEmpty;
          i++
        ) {
          await fixture.tick();
        }
        expect(await store.read('user-1'), isEmpty);
        final sends = adapter.requests
            .where((r) => r.method == 'POST')
            .toList();
        expect(sends, hasLength(2));
        expect(
          sends.every((r) => r.path == '/api/v1/chat/rooms/room/forward'),
          isTrue,
        );
        expect(
          sends.every(
            (r) =>
                r.data['clientMessageId'] == key &&
                r.data['messageId'] == 'source',
          ),
          isTrue,
        );
        expect(sends.last.extra['expectedAccountId'], 'user-1');
        await repo.dispose();
      }
    },
  );

  test('conversation selection excludes groups without send permission and paginates', () async {
    final adapter = FakeAdapter(
      (r) => response(
        envelope({
          'content': [
            fixture.room(),
            {
              'id': 'locked',
              'type': 'GROUP_PRIVATE',
              'myRole': 'MEMBER',
              'membersCanSend': false,
            },
          ],
          'last': r.queryParameters['page'] == 1,
        }),
      ),
    );
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
    final cubit = ShareCubit(repo);
    await cubit.load();
    expect(cubit.state.rooms.map((r) => r.id), ['room']);
    await cubit.load();
    expect(cubit.state.rooms, hasLength(1));
    expect(cubit.state.more, isFalse);
    await cubit.close();
    await repo.dispose();
  });

  test(
    'Android intake supports cold-start payload and explicit cancellation',
    () async {
      const channel = MethodChannel('qlink/share-test');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'pending') {
              return {
                'id': 'share',
                'text': 'Hello',
                'files': [
                  {
                    'path': '/private/image.png',
                    'name': 'image.png',
                    'mime': 'image/png',
                    'size': 12,
                  },
                  {
                    'path': '/private/doc.pdf',
                    'name': 'doc.pdf',
                    'mime': 'application/pdf',
                    'size': 30,
                  },
                ],
              };
            }
            return null;
          });
      final intake = ExternalShareIntake(channel: channel)..start();
      final draft = await intake.pending();
      expect(draft!.valid, isTrue);
      expect(draft.files, hasLength(2));
      expect(draft.text, 'Hello');
      await intake.discard(draft.id);
      expect(calls, ['pending', 'discard']);
      await intake.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  test('invalid, excessive and permission-denied shares cannot be sent', () {
    expect(ShareDraft.fromPlatform({'text': 'x' * 4001}).valid, isFalse);
    expect(
      ShareDraft.fromPlatform({'error': 'Permission expired'}).valid,
      isFalse,
    );
    expect(ShareDraft.fromPlatform({}).valid, isFalse);
    expect(
      ShareDraft.fromPlatform({
        'files': [
          {'path': '/private/file', 'name': 'empty.txt', 'size': 0},
        ],
      }).valid,
      isFalse,
    );
    expect(
      ShareDraft.fromPlatform({
        'files': List.generate(
          11,
          (_) => {'path': '/private/file', 'name': 'file.txt', 'size': 1},
        ),
      }).valid,
      isFalse,
    );
  });
}
