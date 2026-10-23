import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
import 'package:qlinkfrontend/features/chat/presentation/bloc/group_creation_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/create_group_screen.dart';

import 'support/fakes.dart';

const bob = {'id': 'bob', 'displayName': 'Bob', 'username': 'bob_1'};
const carol = {'id': 'carol', 'displayName': 'Carol', 'username': 'carol_1'};
Map<String, dynamic> group() => {
  'id': 'group-1',
  'type': 'GROUP_PRIVATE',
  'name': 'Friends',
  'participant': null,
  'memberCount': 3,
  'lastMessage': null,
  'lastMessageAt': null,
};
Map<String, dynamic> incoming() => {
  'id': 'message-1',
  'clientMessageId': 'key-1',
  'senderId': 'bob',
  'senderDisplayName': 'Bob',
  'content': 'Hello everyone',
  'createdAt': '2026-10-18T08:00:00Z',
};
ChatRepository repo(FakeAdapter adapter) =>
    ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'group validation trims names and rejects empty and excessive length',
    () {
      expect(validateGroupName('  '), isNotNull);
      expect(validateGroupName('x' * 101), isNotNull);
      expect(validateGroupName(' Friends '), isNull);
    },
  );

  test(
    'contacts paginate, retry, filter and retain selections excluding self',
    () async {
      bool fail = false;
      final adapter = FakeAdapter(
        (r) => fail
            ? response({'message': 'Offline'}, status: 503)
            : response(
                envelope({
                  'content': r.queryParameters['page'] == 0
                      ? [bob, userJson]
                      : [carol],
                  'last': r.queryParameters['page'] == 1,
                }),
              ),
      );
      final cubit = GroupCreationCubit(repo(adapter), 'user-1');
      expect(cubit.state.isPublic, isFalse);
      expect(cubit.state.viewAllMessages, isFalse);
      await cubit.loadContacts();
      expect(cubit.state.contacts.map((u) => u.id), ['bob']);
      cubit.toggle('user-1');
      cubit.toggle('bob');
      cubit.search('CAROL');
      expect(cubit.state.filtered, isEmpty);
      fail = true;
      await cubit.loadContacts();
      expect(cubit.state.error, 'Request failed. Please retry.');
      expect(cubit.state.selected, {'bob'});
      fail = false;
      await cubit.loadContacts();
      expect(adapter.requests.last.queryParameters['page'], 1);
      expect(cubit.state.filtered.single.id, 'carol');
      cubit.toggle('carol');
      cubit.search('');
      expect(cubit.state.selected, {'bob', 'carol'});
      expect(cubit.state.hasMore, isFalse);
      await cubit.close();
    },
  );

  for (final enabled in [false, true]) {
    test(
      'creation maps enums ($enabled), blocks duplicate posts and preserves failed form',
      () async {
        final pending = Completer<ResponseBody>();
        final started = Completer<void>();
        bool fail = true;
        final adapter = FakeAdapter((r) {
          if (r.method == 'GET') {
            return response(
              envelope({
                'content': [bob],
                'last': true,
              }),
            );
          }
          if (fail) return response({'message': 'Try again'}, status: 503);
          started.complete();
          return pending.future;
        });
        final cubit = GroupCreationCubit(repo(adapter), 'user-1');
        await cubit.loadContacts();
        cubit.details(
          name: '  Friends  ',
          isPublic: enabled,
          viewAllMessages: enabled,
        );
        cubit.photo(base64Decode('aGVsbG8='));
        cubit.toggle('bob');
        await cubit.create();
        expect(cubit.state.error, 'Request failed. Please retry.');
        expect(cubit.state.name, '  Friends  ');
        expect(cubit.state.selected, {'bob'});
        expect(cubit.state.photo, isNotNull);
        fail = false;
        final creating = cubit.create();
        await cubit.create();
        await started.future;
        expect(cubit.state.creating, isTrue);
        expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(2));
        final body = adapter.requests.last.data as Map;
        expect(body, {
          'name': 'Friends',
          'type': enabled ? 'GROUP_PUBLIC' : 'GROUP_PRIVATE',
          'messageHistoryVisibility': enabled
              ? 'VIEW_ALL_MESSAGES'
              : 'VIEW_AFTER_JOIN',
          'memberIds': ['bob'],
        });
        pending.complete(response(envelope(group())));
        await creating;
        expect(cubit.state.created!.id, 'group-1');
        expect(cubit.state.photo, isNull);
        expect(cubit.state.selected, isEmpty);
        expect(cubit.state.name, isEmpty);
        await cubit.close();
      },
    );
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
    testWidgets(
      'group workflow, failure recovery, navigation and messaging in $mode',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          ThemeCubit.preferenceKey: mode.name,
        });
        final storage = MemoryTokens()
          ..tokens = const TokenPair('access', 'refresh');
        final client = DioClient(storage);
        bool created = false, fail = true;
        final adapter = FakeAdapter((r) {
          if (r.path == '/api/v1/auth/me') return response(envelope(userJson));
          if (r.path == '/api/v1/chat/rooms') {
            return response(
              envelope({
                'content': created ? [group()] : [],
                'last': true,
              }),
            );
          }
          if (r.path == '/api/v1/contacts') {
            return response(
              envelope({
                'content': [bob, carol],
                'last': true,
              }),
            );
          }
          if (r.path == '/api/v1/chat/groups') {
            if (fail) return response({'message': 'Please retry'}, status: 503);
            created = true;
            return response(envelope(group()));
          }
          if (r.method == 'POST') {
            return response(
              envelope({
                'room': group(),
                'message': {
                  ...incoming(),
                  'id': 'outgoing',
                  'senderId': 'user-1',
                  'clientMessageId': r.data['clientMessageId'],
                  'content': r.data['content'],
                },
              }),
            );
          }
          return response(
            envelope({
              'items': [incoming()],
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
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create New Group'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<SwitchListTile>(find.byType(SwitchListTile))
              .map((s) => s.value),
          [false, false],
        );
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text('Enter a group name.'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), '  Friends  ');
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text('Select Members'), findsOneWidget);
        expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Bob'));
        await tester.tap(find.text('Carol'));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
          '  Friends  ',
        );
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Request failed. Please retry.'), findsOneWidget);
        expect(find.text('2 selected'), findsOneWidget);
        fail = false;
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Friends'), findsOneWidget);
        expect(find.text('3 members'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Hello everyone'), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsNothing);
        await tester.enterText(find.byType(TextField), 'Group reply');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Send message'));
        await tester.pumpAndSettle();
        expect(find.text('Group reply'), findsOneWidget);
        expect(
          adapter.requests.last.path,
          '/api/v1/chat/rooms/group-1/messages',
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Friends'), findsOneWidget);
        await tester.tap(find.text('Friends'));
        await tester.pumpAndSettle();
        expect(find.text('3 members'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'gallery selection renders a circular local preview without API posts',
    (tester) async {
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      final adapter = FakeAdapter((r) => response(envelope(userJson)));
      client.dio.httpClientAdapter = adapter;
      final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
      await tester.pumpWidget(const SizedBox.shrink());
      auth.add(const AuthStarted());
      await tester.pumpAndSettle();
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII=',
      );
      await tester.pumpWidget(
        RepositoryProvider.value(
          value: repo(adapter),
          child: BlocProvider.value(
            value: auth,
            child: MaterialApp(
              home: CreateGroupScreen(pickPhoto: () async => bytes),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add_a_photo_outlined));
      await tester.pumpAndSettle();
      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isA<MemoryImage>());
      expect((avatar.backgroundImage! as MemoryImage).bytes, bytes);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      addTearDown(auth.close);
    },
  );

  test('group models accept null participant and personal models remain compatible', () {
    final room = ChatRoom.fromJson(group());
    expect(Conversation.fromRoom(room).title, 'Friends');
    expect(room.isGroup, isTrue);
    final personal = ChatRoom.fromJson({'id': 'p', 'participant': bob});
    expect(personal.isGroup, isFalse);
    expect(Conversation.fromRoom(personal).recipient!.id, 'bob');
  });
}
