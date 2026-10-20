import 'dart:async';

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
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/rooms_cubit.dart';
import 'package:qlinkfrontend/features/user/presentation/bloc/user_search_cubit.dart';

import 'support/fakes.dart';

const other = {
  'id': 'recipient',
  'displayName': 'Alex',
  'username': 'alex_1',
  'avatarUrl': null,
};
Map<String, dynamic> message(String key, {String text = 'Hello'}) => {
  'id': 'message-$key',
  'roomId': 'room-1',
  'senderId': 'user-1',
  'clientMessageId': key,
  'type': 'TEXT',
  'content': text,
  'createdAt': '2026-10-17T10:00:00.000001Z',
};
Map<String, dynamic> room() => {
  'id': 'room-1',
  'participant': other,
  'lastMessage': null,
  'lastMessageAt': null,
};
ChatRepository repository(FakeAdapter adapter) =>
    ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('QR identifiers are exact discovery URLs, never token-bearing URLs', () {
    const id = 'a2b25557-8ff7-47b4-8d80-0a26839c94ff';
    expect(parseUserQr('qlink://user/$id'), id);
    for (final value in [
      'https://user/$id',
      'qlink://user/$id?token=secret',
      'qlink://user/$id#x',
      'qlink://user/nope',
      'qlink://user/$id/',
      'qlink://user/',
    ]) {
      expect(parseUserQr(value), isNull);
    }
    expect(validateUsername('Alex_123'), isNull);
    expect(validateUsername('ADMIN'), isNotNull);
    expect(validateUsername('aa'), isNotNull);
  });
  test(
    'draft lookup does not post and existing lookup carries the room ID',
    () async {
      bool exists = false;
      final adapter = FakeAdapter(
        (r) => response(
          envelope({'exists': exists, 'room': exists ? room() : null}),
        ),
      );
      final repo = repository(adapter);
      final draft = await repo.conversation(PublicUser.fromJson(other));
      expect(draft.roomId, isNull);
      exists = true;
      expect(
        (await repo.conversation(PublicUser.fromJson(other))).roomId,
        'room-1',
      );
      expect(adapter.requests.map((r) => r.method), everyElement('GET'));
    },
  );
  test(
    'first send transitions once; failed retry retains clientMessageId',
    () async {
      bool fail = true;
      final adapter = FakeAdapter((r) {
        if (r.method == 'GET') {
          return response(envelope({'items': <Object>[], 'nextCursor': null}));
        }
        if (fail) return response({'message': 'Try again'}, status: 503);
        final body = r.data as Map;
        return response(
          envelope({
            'room': room(),
            'message': message(
              body['clientMessageId'] as String,
              text: body['content'] as String,
            ),
          }),
        );
      });
      final cubit = ChatCubit(
        repository(adapter),
        Conversation(PublicUser.fromJson(other)),
        'user-1',
      );
      await cubit.load();
      expect(adapter.requests, isEmpty);
      expect(cubit.state.roomId, isNull);
      expect(await cubit.send('Hello'), isFalse);
      expect(cubit.state.messages.single.delivery, Delivery.failed);
      final failed = cubit.state.messages.single;
      expect(cubit.state.roomId, isNull);
      fail = false;
      expect(await cubit.retry(failed), isTrue);
      expect(cubit.state.roomId, 'room-1');
      expect(cubit.state.messages, hasLength(1));
      expect(cubit.state.messages.single.delivery, Delivery.sent);
      final posts = adapter.requests.where((r) => r.method == 'POST').toList();
      expect(
        posts[0].data['clientMessageId'],
        posts[1].data['clientMessageId'],
      );
      await cubit.send('Again');
      expect(adapter.requests.last.path, '/api/v1/chat/rooms/room-1/messages');
      expect(cubit.state.messages, hasLength(2));
      await cubit.close();
    },
  );
  test('existing history merges without duplicates and uses cursor', () async {
    final adapter = FakeAdapter(
      (r) => response(
        envelope({
          'items': [message('key')],
          'nextCursor': r.queryParameters['cursor'] == null ? 'next' : null,
        }),
      ),
    );
    final cubit = ChatCubit(
      repository(adapter),
      Conversation(PublicUser.fromJson(other), roomId: 'room-1'),
      'user-1',
    );
    await cubit.load();
    await cubit.load();
    expect(adapter.requests.last.queryParameters['cursor'], 'next');
    expect(cubit.state.messages, hasLength(1));
    expect(cubit.state.cursor, isNull);
    await cubit.load();
    expect(adapter.requests, hasLength(2));
    await cubit.close();
  });
  test('search debounces and ignores stale results', () async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((r) {
      if (r.queryParameters['q'] == 'alex') return pending.future;
      return response(
        envelope({
          'content': [other],
          'last': true,
        }),
      );
    });
    final cubit = UserSearchCubit(repository(adapter));
    cubit.search('a');
    cubit.search('alex');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(adapter.requests, hasLength(1));
    expect(cubit.state.loading, isTrue);
    cubit.search('alex_1');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    pending.complete(response(envelope({'content': <Object>[], 'last': true})));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.items.single.username, 'alex_1');
    cubit.search('');
    expect(cubit.state.items, isEmpty);
    await cubit.close();
  });
  test('room list handles loading, pagination, refresh and errors', () async {
    bool fail = false;
    final adapter = FakeAdapter(
      (r) => fail
          ? response({'message': 'Unavailable'}, status: 503)
          : response(
              envelope({
                'content': [room()],
                'last': r.queryParameters['page'] == 1,
              }),
            ),
    );
    final cubit = RoomsCubit(repository(adapter));
    await cubit.load();
    expect(cubit.state.items.single.id, 'room-1');
    expect(cubit.state.hasMore, isTrue);
    await cubit.load();
    expect(cubit.state.items, hasLength(1));
    expect(cubit.state.hasMore, isFalse);
    fail = true;
    await cubit.load(refresh: true);
    expect(cubit.state.error, 'Unavailable');
    expect(cubit.state.items, hasLength(1));
    await cubit.close();
  });

  test(
    'user discovery accepts names and contacts and retries paginated errors',
    () async {
      bool fail = false;
      final adapter = FakeAdapter((r) {
        if (fail) {
          return response({'message': 'Search limit reached.'}, status: 429);
        }
        return response(
          envelope({
            'content': [other],
            'last': r.queryParameters['page'] == 1,
          }),
        );
      });
      final cubit = UserSearchCubit(repository(adapter));
      for (final query in [
        'Alice Smith',
        'ALICE@EXAMPLE.COM',
        '+855 (12) 345-678',
      ]) {
        cubit.search(query);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(adapter.requests.last.queryParameters['q'], query.toLowerCase());
        expect(
          adapter.requests.last.queryParameters.containsKey('username'),
          isFalse,
        );
        expect(cubit.state.items.single.displayName, 'Alex');
      }
      fail = true;
      await cubit.more();
      expect(cubit.state.error, 'Search limit reached.');
      expect(cubit.state.items, hasLength(1));
      fail = false;
      await cubit.retry();
      expect(adapter.requests.last.queryParameters['page'], 1);
      expect(cubit.state.hasMore, isFalse);
      cubit.search('ab');
      expect(cubit.state.error, isNotNull);
      await cubit.close();
    },
  );

  testWidgets(
    'user search renders empty/error/results and clears contact input',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      final adapter = FakeAdapter((r) {
        if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
        if (r.path == '/api/v1/chat/rooms') {
          return response(envelope({'content': <Object>[], 'last': true}));
        }
        if (r.queryParameters['q'] == 'error@example.com') {
          return response({'message': 'Search limit reached.'}, status: 429);
        }
        return response(
          envelope({
            'content': r.queryParameters['q'] == 'alice smith'
                ? [other]
                : <Object>[],
            'last': true,
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
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('Search users'));
      await tester.pumpAndSettle();
      expect(
        find.text('Search by name, username, email or phone'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'missing@example.com');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('No users found.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'error@example.com');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Search limit reached.'), findsOneWidget);
      expect(find.text('No users found.'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Alice Smith');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('@alex_1'), findsOneWidget);
      final count = adapter.requests.length;
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Alex'), findsNothing);
      expect(adapter.requests.length, count);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
    testWidgets('draft and persisted navigation and send in ${mode.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        ThemeCubit.preferenceKey: mode.name,
      });
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      bool exists = false;
      final adapter = FakeAdapter((r) {
        if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
        if (r.path == '/api/v1/chat/rooms') {
          return response(envelope({'content': <Object>[], 'last': true}));
        }
        if (r.path == '/api/v1/users/search') {
          return response(
            envelope({
              'content': [other],
              'last': true,
            }),
          );
        }
        if (r.path.contains('/personal/with/')) {
          return response(
            envelope({'exists': exists, 'room': exists ? room() : null}),
          );
        }
        if (r.method == 'POST') {
          exists = true;
          final body = r.data as Map;
          return response(
            envelope({
              'room': room(),
              'message': message(
                body['clientMessageId'] as String,
                text: body['content'] as String,
              ),
            }),
          );
        }
        return response(envelope({'items': <Object>[], 'nextCursor': null}));
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
      expect(
        find.text('No conversations yet. Start a new message.'),
        findsOneWidget,
      );
      expect(find.byType(FloatingActionButton), findsNothing);
      await tester.tap(find.byTooltip('Search users'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'alex');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alex'));
      await tester.pumpAndSettle();
      expect(find.text('Say hello to Alex'), findsOneWidget);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Say hello to Alex'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alex'));
      await tester.pumpAndSettle();
      expect(find.text('No messages yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
