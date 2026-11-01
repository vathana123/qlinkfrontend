import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/features/auth/data/models/app_user.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/user/presentation/bloc/privacy_cubit.dart';
import 'package:qlinkfrontend/features/user/presentation/screens/privacy_screen.dart';

import 'support/fakes.dart';

class SignedInAuth extends AuthBloc {
  SignedInAuth() : super(AuthRepository(Dio(), MemoryTokens(), FakeOAuth())) {
    emit(AuthAuthenticated(AppUser.fromJson(userJson)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const peer = PublicUser('bob', 'Bob');
  ChatRepository repository(Reply reply, [WidgetTester? tester]) {
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = FakeAdapter(reply)),
    );
    repo.setAccount('user-1');
    if (tester == null) addTearDown(repo.dispose);
    return repo;
  }

  test('privacy saves desired values, failure retains settings, account switch rejects late results', () async {
    bool fail = false;
    Completer<ResponseBody>? pending;
    final repo = repository((r) {
      expect(r.extra['expectedAccountId'], 'user-1');
      if (r.method == 'PUT') {
        if (fail) return response({'message': 'Unavailable'}, status: 503);
        return response(envelope(r.data));
      }
      return pending?.future ??
          response(
            envelope({
              'onlineVisibility': 'CONTACTS',
              'lastSeenVisibility': 'CONTACTS',
            }),
          );
    });
    final cubit = PrivacyCubit(repo, 'user-1');
    addTearDown(cubit.close);
    await cubit.load();
    await cubit.save('NOBODY', 'EVERYONE');
    expect(cubit.state.online, 'NOBODY');
    expect(cubit.state.lastSeen, 'EVERYONE');
    fail = true;
    await cubit.save('EVERYONE', 'EVERYONE');
    expect(cubit.state.online, 'NOBODY');
    expect(cubit.state.error, isNotNull);
    pending = Completer<ResponseBody>();
    final request = cubit.load();
    await Future<void>.delayed(Duration.zero);
    repo.setAccount('another');
    pending.complete(
      response(
        envelope({
          'onlineVisibility': 'EVERYONE',
          'lastSeenVisibility': 'EVERYONE',
        }),
      ),
    );
    await request;
    expect(cubit.state.online, 'NOBODY');
  });
  test('block updates an open personal chat without clearing history; group stays writable', () async {
    bool blocked = false;
    final repo = repository((r) {
      if (r.path.endsWith('/blocks/bob')) blocked = r.method == 'PUT';
      if (r.path.endsWith('/relationship') || r.path.endsWith('/blocks/bob')) {
        return response(
          envelope({'blockedByMe': blocked, 'canMessage': !blocked}),
        );
      }
      return response(
        envelope({
          'items': [
            {
              'id': 'm',
              'senderId': 'bob',
              'clientMessageId': 'key',
              'content': 'History',
              'createdAt': '2026-10-28T00:00:00Z',
            },
          ],
        }),
      );
    });
    final chat = ChatCubit(
      repo,
      const Conversation(peer, roomId: 'room'),
      'user-1',
    );
    final group = ChatCubit(
      repo,
      const Conversation(null, roomId: 'g', groupName: 'Group'),
      'user-1',
    );
    final privacy = PrivacyCubit(repo, 'user-1', peer: peer);
    addTearDown(chat.close);
    addTearDown(group.close);
    addTearDown(privacy.close);
    await chat.load();
    await privacy.load();
    expect(chat.state.messages.single.content, 'History');
    await privacy.block(peer, true);
    await Future<void>.delayed(Duration.zero);
    expect(chat.state.canSend, isFalse);
    expect(chat.state.messages.single.content, 'History');
    expect(group.state.canSend, isTrue);
    expect(privacy.state.blockedByMe, isTrue);
    await privacy.block(peer, false);
    await Future<void>.delayed(Duration.zero);
    expect(chat.state.canSend, isTrue);
  });
  test(
    'blocked list paginates, deduplicates and resets after unblock',
    () async {
      bool removed = false;
      final repo = repository((r) {
        if (r.method == 'DELETE') {
          removed = true;
          return response(envelope({'blockedByMe': false, 'canMessage': true}));
        }
        final page = r.queryParameters['page'];
        return response(
          envelope({
            'content': removed
                ? []
                : [
                    {
                      'id': page == 0 ? 'bob' : 'chris',
                      'displayName': page == 0 ? 'Bob' : 'Chris',
                    },
                  ],
            'last': removed || page != 0,
          }),
        );
      });
      final cubit = PrivacyCubit(repo, 'user-1');
      addTearDown(cubit.close);
      await cubit.loadBlocked();
      await cubit.loadBlocked();
      expect(cubit.state.blocked.map((u) => u.id), ['bob', 'chris']);
      await cubit.block(peer, false);
      expect(cubit.state.blocked, isEmpty);
      expect(cubit.state.hasMore, isFalse);
    },
  );
  test('personal send eligibility survives room metadata copies; groups ignore personal flags', () {
    final room = ChatRoom.fromJson({
      'id': 'r',
      'participant': {'id': 'bob', 'displayName': 'Bob'},
      'canSend': false,
    });
    expect(room.canSend, isFalse);
    expect(Conversation.fromRoom(room).canMessage, isFalse);
    final group = ChatRoom.fromJson({
      'id': 'g',
      'type': 'GROUP_PRIVATE',
      'membersCanSend': true,
      'canSend': false,
    });
    expect(group.canSend, isTrue);
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'privacy controls and block/unblock render in ${brightness.name}',
      (tester) async {
        bool blocked = false;
        final repo = (await tester.runAsync(
          () async => repository((r) {
            if (r.path.endsWith('/blocks/bob')) blocked = r.method == 'PUT';
            if (r.path.endsWith('/relationship') ||
                r.path.endsWith('/blocks/bob')) {
              return response(
                envelope({'blockedByMe': blocked, 'canMessage': !blocked}),
              );
            }
            return response(
              envelope(
                r.method == 'PUT'
                    ? r.data
                    : {
                        'onlineVisibility': 'CONTACTS',
                        'lastSeenVisibility': 'CONTACTS',
                      },
              ),
            );
          }, tester),
        ))!;
        final auth = (await tester.runAsync(() async => SignedInAuth()))!;
        Widget app(Widget child) => RepositoryProvider.value(
          value: repo,
          child: BlocProvider<AuthBloc>.value(
            value: auth,
            child: MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: child,
            ),
          ),
        );

        await tester.pumpWidget(app(const PrivacyScreen()));
        await tester.pumpAndSettle();

        expect(find.text('Online'), findsOneWidget);
        expect(find.text('Last seen'), findsOneWidget);
        await tester.tap(find.byType(DropdownButton<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Nobody').last);
        await tester.pumpAndSettle();

        expect(find.text('Nobody'), findsOneWidget);
        await tester.pumpWidget(app(const PrivacyScreen(user: peer)));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Block user'));
        await tester.pumpAndSettle();
        expect(find.text('Unblock user'), findsOneWidget);
        await tester.tap(find.text('Unblock user'));
        await tester.pumpAndSettle();
        expect(find.text('Block user'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await repo.dispose();
          await auth.close();
        });
      },
    );
  }
}
