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
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_search_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/search_highlight.dart';

import 'support/fakes.dart';

Map<String, dynamic> message(
  String id, {
  int second = 0,
  bool hidden = false,
  int revision = 0,
}) => {
  'id': id,
  'roomId': 'room',
  'senderId': 'bob',
  'clientMessageId': id,
  'type': 'TEXT',
  'content': hidden ? '' : 'needle $id',
  'createdAt': '2026-01-01T00:00:${second.toString().padLeft(2, '0')}Z',
  'hidden': hidden,
  'revision': revision,
};
Map<String, dynamic> room({bool group = false}) => {
  'id': 'room',
  'type': group ? 'GROUP_PRIVATE' : 'PERSONAL',
  'name': group ? 'Needle group' : null,
  'participant': group ? null : {'id': 'bob', 'displayName': 'Bob Needle'},
};
Map<String, dynamic> match(String id, {bool group = false}) => {
  'room': room(group: group),
  'message': message(id),
};
const conversation = Conversation(PublicUser('bob', 'Bob'), roomId: 'room');
Future<void> debounce() =>
    Future<void>.delayed(const Duration(milliseconds: 400));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('typing debounces, clearing cancels pending results, and empty results end pagination', () async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((r) => pending.future);
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
    final search = ChatSearchCubit(repo, roomId: 'room');
    search.change('n');
    search.change('ne');
    search.change('needle');
    expect(adapter.requests, isEmpty);
    await debounce();
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.path, '/api/v1/chat/rooms/room/search');
    search.change('');
    pending.complete(
      response(
        envelope({
          'items': [match('stale')],
          'nextCursor': 'older',
        }),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(search.state.messages, isEmpty);
    expect(search.state.loading, isFalse);
    await search.more();
    expect(adapter.requests, hasLength(1));
    await search.close();
    await repo.dispose();
  });

  test('global personal/group results paginate independently, deduplicate, and retry failed pages', () async {
    bool fail = true;
    final adapter = FakeAdapter((r) {
      final rooms = r.path.endsWith('/rooms');
      final cursor = r.queryParameters['cursor'];
      if (!rooms && cursor == 'm2' && fail) {
        return response({'message': 'Try again'}, status: 503);
      }
      return response(
        envelope({
          'items': rooms
              ? [room(group: cursor != null)]
              : [match('one'), if (cursor != null) match('two', group: true)],
          'nextCursor': cursor == null ? (rooms ? 'r2' : 'm2') : null,
        }),
      );
    });
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
    final search = ChatSearchCubit(repo);
    search.change('needle');
    await search.retry();
    expect(search.state.rooms.single.isGroup, isFalse);
    expect(search.state.messages, hasLength(1));
    await search.more();
    expect(search.state.error, isNotNull);
    expect(search.state.messageCursor, 'm2');
    expect(search.state.roomCursor, 'r2');
    fail = false;
    await search.retry();
    expect(search.state.messages, hasLength(2));
    expect(search.state.messages.last.room.isGroup, isTrue);
    expect(search.state.rooms.single.isGroup, isTrue);
    expect(search.state.messageCursor, isNull);
    final calls = adapter.requests.length;
    await search.more();
    expect(adapter.requests.length, calls);
    await search.close();
    await repo.dispose();
  });

  test('a new query supersedes a slow page and simultaneous more calls share one request', () async {
    final slow = Completer<ResponseBody>();
    final adapter = FakeAdapter((r) {
      if (r.queryParameters['cursor'] != null) return slow.future;
      return response(
        envelope({
          'items': [match(r.queryParameters['q'] as String)],
          'nextCursor': 'more',
        }),
      );
    });
    final repo = ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
    final search = ChatSearchCubit(repo, roomId: 'room');
    search.change('first');
    await search.retry();
    final page = search.more();
    await search.more();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      adapter.requests.where((r) => r.queryParameters['cursor'] != null),
      hasLength(1),
    );
    search.change('second');
    await search.retry();
    slow.complete(
      response(
        envelope({
          'items': [match('stale')],
          'nextCursor': null,
        }),
      ),
    );
    await page;
    expect(search.state.messages.single.message.id, 'second');
    await search.close();
    await repo.dispose();
  });

  test('hide events invalidate previews and in-flight search', () async {
    final events = StreamController<ChatEvent>.broadcast(sync: true);
    bool hidden = false;
    final repo = ChatRepository(
      ChatApi(
        Dio()
          ..httpClientAdapter = FakeAdapter(
            (r) => response(
              envelope({
                'items': hidden ? [] : [match('one')],
                'nextCursor': null,
              }),
            ),
          ),
      ),
      events: events.stream,
    );
    final search = ChatSearchCubit(repo, roomId: 'room');
    search.change('needle');
    await search.retry();
    hidden = true;
    events.add(
      ChatEvent.parse(
        jsonEncode({
          'eventId': 'hidden',
          'type': 'MESSAGE_HIDDEN',
          'roomId': 'room',
          'roomType': 'PERSONAL',
          'message': message('one', hidden: true),
        }),
      )!,
    );
    expect(search.state.messages, isEmpty);
    await debounce();
    expect(search.state.messages, isEmpty);
    expect(search.state.messageCursor, isNull);
    await search.close();
    await repo.dispose();
    await events.close();
  });

  test('revoked membership discards an in-flight message window and search previews', () async {
    final events = StreamController<ChatEvent>.broadcast(sync: true);
    final pending = Completer<ResponseBody>();
    final repo = ChatRepository(
      ChatApi(
        Dio()
          ..httpClientAdapter = FakeAdapter(
            (r) => r.path.endsWith('/context')
                ? pending.future
                : response(
                    envelope({
                      'items': [match('target', group: true)],
                      'nextCursor': null,
                    }),
                  ),
          ),
      ),
      events: events.stream,
    );
    final chat = ChatCubit(
      repo,
      Conversation.fromRoom(ChatRoom.fromJson(room(group: true))),
      'user-1',
    );
    final search = ChatSearchCubit(repo, roomId: 'room');
    search.change('needle');
    await search.retry();
    final jump = chat.jumpToMessage('target');
    events.add(
      const ChatEvent(
        'removed',
        'room',
        'GROUP_PRIVATE',
        null,
        type: 'GROUP_REMOVED',
      ),
    );
    expect(search.state.messages, isEmpty);
    pending.complete(
      response(
        envelope({
          'items': [message('target')],
          'nextCursor': null,
          'newerCursor': null,
        }),
      ),
    );
    expect(await jump, isFalse);
    expect(chat.state.removed, isTrue);
    expect(chat.state.loading, isFalse);
    expect(chat.state.messages, isEmpty);
    await chat.close();
    await search.close();
    await repo.dispose();
    await events.close();
  });

  test('old match loads one bounded context, preserves socket edits, and resumes both directions', () async {
    final events = StreamController<ChatEvent>.broadcast(sync: true);
    final adapter = FakeAdapter(
      (r) => response(
        envelope(
          r.path.endsWith('/context')
              ? {
                  'items': [
                    message('newer', second: 3),
                    message('target', second: 2),
                    message('older', second: 1),
                  ],
                  'nextCursor': 'old-page',
                  'newerCursor': 'new-page',
                }
              : r.path.endsWith('/newer')
              ? {
                  'items': [message('next', second: 4)],
                  'nextCursor': null,
                }
              : {
                  'items': [message('latest', second: 9)],
                  'nextCursor': 'history',
                },
        ),
      ),
    );
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      events: events.stream,
    );
    final chat = ChatCubit(repo, conversation, 'user-1');
    await chat.load();
    expect(await chat.jumpToMessage('target'), isTrue);
    expect(adapter.requests, hasLength(2));
    expect(chat.state.messages.map((m) => m.id), ['newer', 'target', 'older']);
    expect(chat.state.contextMessageId, 'target');
    expect(chat.state.cursor, 'old-page');
    events.add(
      ChatEvent.parse(
        jsonEncode({
          'eventId': 'edit',
          'type': 'MESSAGE_UPDATED',
          'roomId': 'room',
          'roomType': 'PERSONAL',
          'message': {
            ...message('target', second: 2, revision: 1),
            'content': 'edited',
          },
        }),
      )!,
    );
    expect(chat.state.messages[1].content, 'edited');
    events.add(
      ChatEvent(
        'outside',
        'room',
        'PERSONAL',
        ChatMessage.fromJson(message('outside', second: 8)),
      ),
    );
    expect(chat.state.messages.any((m) => m.id == 'outside'), isFalse);
    await chat.loadNewer();
    expect(chat.state.messages.first.id, 'next');
    expect(chat.state.newerCursor, isNull);
    events.add(
      ChatEvent(
        'live',
        'room',
        'PERSONAL',
        ChatMessage.fromJson(message('live', second: 8)),
      ),
    );
    expect(chat.state.messages.first.id, 'live');
    await chat.returnToLatest();
    expect(chat.state.contextMessageId, isNull);
    expect(chat.state.messages.single.id, 'latest');
    await chat.close();
    await repo.dispose();
    await events.close();
  });

  test(
    'a slow initial history response cannot replace a search window',
    () async {
      final slow = Completer<ResponseBody>();
      final repo = ChatRepository(
        ChatApi(
          Dio()
            ..httpClientAdapter = FakeAdapter(
              (r) => r.path.endsWith('/context')
                  ? response(
                      envelope({
                        'items': [message('target')],
                        'nextCursor': null,
                        'newerCursor': null,
                      }),
                    )
                  : slow.future,
            ),
        ),
      );
      final chat = ChatCubit(repo, conversation, 'user-1');
      final load = chat.load();
      await chat.jumpToMessage('target');
      slow.complete(
        response(
          envelope({
            'items': [message('latest')],
            'nextCursor': 'many-pages',
          }),
        ),
      );
      await load;
      expect(chat.state.messages.single.id, 'target');
      expect(chat.state.cursor, isNull);
      expect(chat.state.loading, isFalse);
      await chat.close();
      await repo.dispose();
    },
  );

  testWidgets('matching text highlights literal punctuation', (tester) async {
    expect(
      searchPreview('${'long text ' * 40}needle suffix', 'needle'),
      contains('needle'),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SearchHighlight('a [.*] b', '[.*]')),
      ),
    );
    final text = tester.widget<Text>(find.byType(Text));
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(
      spans.where((s) => s.style?.fontWeight == FontWeight.bold).single.text,
      '[.*]',
    );
  });

  testWidgets(
    'global search opens an older match and in-chat next match stays in that room',
    (tester) async {
      tester.view.physicalSize = const Size(390, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
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
        if (r.path.endsWith('/search/rooms')) {
          return response(
            envelope({
              'items': [room()],
              'nextCursor': null,
            }),
          );
        }
        if (r.path.endsWith('/search/messages') || r.path.endsWith('/search')) {
          return response(
            envelope({
              'items': [match('target'), match('second')],
              'nextCursor': null,
            }),
          );
        }
        if (r.path.endsWith('/context')) {
          final id = r.path.split('/')[7];
          return response(
            envelope({
              'items': [message(id)],
              'nextCursor': 'older',
              'newerCursor': 'newer',
            }),
          );
        }
        if (r.path.endsWith('/notifications')) {
          return response(envelope({'muted': false}));
        }
        return response(
          envelope({
            'items': [message('latest', second: 9)],
            'nextCursor': 'many-pages',
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
      await tester.tap(find.byTooltip('Search chats'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SearchHighlight, 'needle target'));
      await tester.pumpAndSettle();
      expect(find.text('needle target'), findsOneWidget);
      expect(find.text('Back to latest'), findsOneWidget);
      expect(
        adapter.requests.where(
          (r) => r.queryParameters['cursor'] == 'many-pages',
        ),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Search this conversation'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).first, 'needle');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(
        adapter.requests.any(
          (r) => r.path == '/api/v1/chat/rooms/room/messages/second/context',
        ),
        isTrue,
      );
      expect(
        adapter.requests.any((r) => r.path == '/api/v1/chat/rooms/room/search'),
        isTrue,
      );
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(find.text('needle second'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
