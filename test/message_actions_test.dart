import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/app.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/rooms_cubit.dart';

import 'support/fakes.dart';

Map<String, dynamic> message(
  String id, {
  int revision = 0,
  bool hidden = false,
  bool deleted = false,
  String? replyTo,
}) => {
  'id': id,
  'roomId': 'room',
  'senderId': 'user-1',
  'clientMessageId': id,
  'type': 'TEXT',
  'content': hidden || deleted ? '' : '$id version $revision',
  'createdAt': '2026-10-24T01:00:00Z',
  'revision': revision,
  'hidden': hidden,
  'removedAt': deleted ? '2026-10-24T02:00:00Z' : null,
  'canDeleteForEveryone': !hidden && !deleted,
  if (replyTo != null) ...{
    'replyToId': replyTo,
    'reply': {
      'id': replyTo,
      'content': 'original version 0',
      'type': 'TEXT',
      'unavailable': false,
    },
  },
};
Map<String, dynamic> room([Map<String, dynamic>? last]) => {
  'id': 'room',
  'type': 'PERSONAL',
  'participant': {'id': 'bob', 'displayName': 'Bob'},
  'lastMessage': last,
  'lastMessageAt': last?['createdAt'],
};
ChatEvent event(Map<String, dynamic> m, {String type = 'MESSAGE_UPDATED'}) =>
    ChatEvent.parse(
      jsonEncode({
        'eventId': 'event-${m['revision']}-$type',
        'type': type,
        'roomId': 'room',
        'roomType': 'PERSONAL',
        'message': m,
        'room': room(m['hidden'] == true ? null : m),
      }),
    )!;
const conversation = Conversation(PublicUser('bob', 'Bob'), roomId: 'room');
Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 10));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mutation events parse tombstones for every message type', () {
    for (final type in ['TEXT', 'VOICE', 'IMAGE', 'FILE']) {
      final parsed = event({
        ...message('m', deleted: true, revision: 2),
        'type': type,
      });
      expect(parsed.isGroupChange, isFalse);
      expect(parsed.message!.deleted, isTrue);
      expect(parsed.message!.isAttachment, isFalse);
    }
    expect(
      event(message('m', hidden: true), type: 'MESSAGE_HIDDEN').message!.hidden,
      isTrue,
    );
  });
  test('old REST and socket data cannot undo edits or hiding', () {
    final old = ChatMessage.fromJson(message('m'));
    final edited = ChatMessage.fromJson(message('m', revision: 2));
    expect(reconcileMessage(edited, old).revision, 2);
    final hidden = ChatMessage.fromJson(message('m', hidden: true));
    expect(reconcileMessage(hidden, edited).hidden, isTrue);
  });
  test(
    'two open chats apply edits, hide and reply invalidation without reload',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      final adapter = FakeAdapter(
        (r) => response(
          envelope({
            'items': [
              message('reply', replyTo: 'original'),
              message('original'),
            ],
            'nextCursor': null,
          }),
        ),
      );
      final repo = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      );
      final first = ChatCubit(repo, conversation, 'user-1'),
          second = ChatCubit(repo, conversation, 'user-1');
      await first.load();
      await second.load();
      final calls = adapter.requests.length;
      events.add(event(message('original', revision: 1)));
      for (final chat in [first, second]) {
        expect(
          chat.state.messages.firstWhere((m) => m.id == 'original').revision,
          1,
        );
        expect(
          chat.state.messages.firstWhere((m) => m.id == 'reply').reply!.content,
          'original version 1',
        );
      }
      events.add(
        event(
          message('original', hidden: true, revision: 1),
          type: 'MESSAGE_HIDDEN',
        ),
      );
      events.add(event(message('original'), type: 'MESSAGE_CREATED'));
      for (final chat in [first, second]) {
        expect(chat.state.messages.any((m) => m.id == 'original'), isFalse);
        expect(chat.state.messages.single.reply!.unavailable, isTrue);
      }
      expect(adapter.requests.length, calls);
      await first.synchronize();
      expect(first.state.messages.any((m) => m.id == 'original'), isFalse);
      await first.close();
      await second.close();
      await repo.dispose();
      await events.close();
    },
  );
  test(
    'reconnect reads hidden markers and removes previously loaded messages',
    () async {
      bool hidden = false;
      final repo = ChatRepository(
        ChatApi(
          Dio()
            ..httpClientAdapter = FakeAdapter(
              (r) => response(
                envelope({
                  'items': [message('m', hidden: hidden)],
                  'nextCursor': null,
                }),
              ),
            ),
        ),
      );
      final chat = ChatCubit(repo, conversation, 'user-1');
      await chat.load();
      expect(chat.state.messages, hasLength(1));
      hidden = true;
      await chat.synchronize();
      expect(chat.state.messages, isEmpty);
      await chat.close();
      await repo.dispose();
    },
  );
  test(
    'reply navigation fetches older history and sending keeps reply reference',
    () async {
      final adapter = FakeAdapter((r) {
        if (r.method == 'POST') {
          return response(
            envelope({
              'room': room(),
              'message': {
                ...message('sent'),
                'clientMessageId': r.data['clientMessageId'],
                'replyToId': r.data['replyToId'],
              },
            }),
          );
        }
        return response(
          envelope(
            r.queryParameters['cursor'] == null
                ? {
                    'items': [message('reply', replyTo: 'original')],
                    'nextCursor': 'older',
                  }
                : {
                    'items': [message('original')],
                    'nextCursor': null,
                  },
          ),
        );
      });
      final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
      repo.setAccount('user-1');
      final chat = ChatCubit(repo, conversation, 'user-1');
      await chat.load();
      expect(await chat.findOriginal('original'), isTrue);
      chat.selectReply(
        chat.state.messages.firstWhere((m) => m.id == 'original'),
      );
      expect(await chat.send('Answer'), isTrue);
      expect(adapter.requests.last.data['replyToId'], 'original');
      expect(chat.replyTo, isNull);
      await chat.close();
      await repo.dispose();
    },
  );
  test(
    'edit conflicts preserve conversation and do not revoke group access',
    () async {
      final adapter = FakeAdapter(
        (r) => r.method == 'PATCH'
            ? response({'message': 'Message changed'}, status: 409)
            : response(
                envelope({
                  'items': [message('m')],
                  'nextCursor': null,
                }),
              ),
      );
      final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
      final chat = ChatCubit(repo, conversation, 'user-1');
      await chat.load();
      expect(
        await chat.editMessage(chat.state.messages.single, 'new'),
        isFalse,
      );
      expect(chat.state.messages.single.content, 'm version 0');
      expect(chat.state.error, isNotNull);
      expect(chat.state.removed, isFalse);
      expect(adapter.requests.last.data['revision'], 0);
      await chat.close();
      await repo.dispose();
    },
  );
  test(
    'room preview drops a hidden last message and stays dropped on stale event',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      final repo = ChatRepository(
        ChatApi(
          Dio()
            ..httpClientAdapter = FakeAdapter(
              (r) => response(
                envelope({
                  'content': [room(message('m'))],
                  'last': true,
                }),
              ),
            ),
        ),
        events: events.stream,
      );
      final rooms = RoomsCubit(repo);
      await rooms.load();
      events.add(event(message('m', hidden: true), type: 'MESSAGE_HIDDEN'));
      expect(rooms.state.items.single.lastMessage, isNull);
      events.add(event(message('m'), type: 'MESSAGE_CREATED'));
      expect(rooms.state.items.single.lastMessage, isNull);
      await rooms.close();
      await repo.dispose();
      await events.close();
    },
  );
  testWidgets(
    'long press Reply cancel, Edit save and Delete update existing bubble',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      var current = message('m');
      final adapter = FakeAdapter((r) {
        if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
        if (r.path == '/api/v1/chat/rooms') {
          return response(
            envelope({
              'content': [room(current)],
              'last': true,
            }),
          );
        }
        if (r.method == 'PATCH') {
          current = {
            ...current,
            'content': r.data['content'],
            'revision': 1,
            'editedAt': '2026-10-24T02:00:00Z',
          };
          return response(envelope(current));
        }
        if (r.method == 'DELETE') {
          current = message('m', deleted: true, revision: 2);
          return response(envelope(current));
        }
        return response(
          envelope({
            'items': [current],
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
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('m version 0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('m version 0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'm version 0',
      );
      await tester.enterText(find.byType(TextField), 'Changed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Changed'), findsOneWidget);
      await tester.longPress(find.text('Changed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete for Everyone'));
      await tester.pumpAndSettle();
      expect(find.text('Message deleted'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'tapping a quote loads older history and scrolls to the original',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      final adapter = FakeAdapter((r) {
        if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
        if (r.path == '/api/v1/chat/rooms') {
          return response(
            envelope({
              'content': [room()],
              'last': true,
            }),
          );
        }
        if (r.queryParameters['cursor'] == 'older') {
          return response(
            envelope({
              'items': [
                {...message('aaa'), 'createdAt': '2026-10-24T00:00:00Z'},
              ],
              'nextCursor': null,
            }),
          );
        }
        return response(
          envelope({
            'items': [
              message('zzreply', replyTo: 'aaa'),
              ...List.generate(35, (i) => message('z$i')),
            ],
            'nextCursor': 'older',
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
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('original version 0'));
      await tester.pumpAndSettle();
      expect(
        adapter.requests.any((r) => r.queryParameters['cursor'] == 'older'),
        isTrue,
      );
      expect(find.text('aaa version 0'), findsOneWidget);
      expect(
        tester.widget<ListView>(find.byType(ListView)).controller!.offset,
        greaterThan(0),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
