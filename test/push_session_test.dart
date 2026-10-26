import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/push/push_client.dart';
import 'package:qlinkfrontend/features/push/push_session.dart';

import 'support/fakes.dart';

const account = '11111111-1111-4111-8111-111111111111';
const roomId = '22222222-2222-4222-8222-222222222222';
const messageId = '33333333-3333-4333-8333-333333333333';

class FakePush implements PushClient {
  bool enabled = true, permitted = true;
  int deleted = 0;
  Map<String, dynamic>? initial;
  final tokenEvents = StreamController<String>.broadcast(sync: true);
  final messages = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final taps = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Future<bool> initialize() async => enabled;
  @override
  Future<bool> requestPermission() async => permitted;
  @override
  Future<String?> token() async => 'initial-token';
  @override
  Future<void> deleteToken() async {
    deleted++;
  }

  @override
  Future<Map<String, dynamic>?> initialMessage() async => initial;
  @override
  Stream<String> get tokens => tokenEvents.stream;
  @override
  Stream<Map<String, dynamic>> get foreground => messages.stream;
  @override
  Stream<Map<String, dynamic>> get opened => taps.stream;
  @override
  String get platform => 'ANDROID';
  Future<void> close() async {
    await tokenEvents.close();
    await messages.close();
    await taps.close();
  }
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('permission denial blocks registration; resume retries safely without logging tokens', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final logs = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (String? value, {int? wrapWidth}) {
      if (value != null) logs.add(value);
    };
    addTearDown(() => debugPrint = originalPrint);
    var failRegistration = true;
    final adapter = FakeAdapter((r) {
      if (r.path == '/api/v1/auth/me') {
        return response(envelope({...userJson, 'id': account}));
      }
      if (r.method == 'PUT' && failRegistration) {
        throw DioException(
          requestOptions: r,
          message: 'secret-token-from-provider',
        );
      }
      return response(envelope(null));
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final tokens = MemoryTokens()
      ..tokens = const TokenPair('access', 'refresh');
    final auth = AuthBloc(AuthRepository(dio, tokens, FakeOAuth()));
    final chat = ChatRepository(ChatApi(dio));
    final native = FakePush()..permitted = false;
    final session = PushSession(auth, chat, native, (_) {});
    await session.start();
    auth.add(const AuthStarted());
    await until(() => auth.state.user != null);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
    native.permitted = true;
    session.resume();
    await until(() => logs.any((line) => line.contains('registration failed')));
    failRegistration = false;
    session.resume();
    await until(() => logs.any((line) => line.contains('device registered')));
    final registrations = adapter.requests
        .where((r) => r.method == 'PUT')
        .toList();
    expect(
      registrations.every((r) => r.extra['expectedAccountId'] == account),
      isTrue,
    );
    expect(registrations.map((r) => r.path).toSet(), hasLength(1));
    expect(logs.join(), isNot(contains('initial-token')));
    expect(logs.join(), isNot(contains('secret-token-from-provider')));
    await session.dispose();
    await chat.dispose();
    await auth.close();
    await native.close();
  });
  test('terminated tap waits for authentication; token rotation, foreground and logout are scoped', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = MemoryTokens()
      ..tokens = const TokenPair('access', 'refresh');
    final adapter = FakeAdapter((r) {
      if (r.path == '/api/v1/auth/me') {
        return response(envelope({...userJson, 'id': account}));
      }
      if (r.path == '/api/v1/chat/rooms/$roomId') {
        return response(
          envelope({
            'id': roomId,
            'participant': {'id': 'bob', 'displayName': 'Bob'},
          }),
        );
      }
      return response(envelope(null));
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final auth = AuthBloc(AuthRepository(dio, storage, FakeOAuth()));
    final chat = ChatRepository(ChatApi(dio));
    final native = FakePush()
      ..initial = {
        'roomId': roomId,
        'messageId': messageId,
        'recipientId': account,
      };
    final navigated = <Conversation>[];
    final sync = <String>[];
    final sub = chat.syncRequests.listen(sync.add);
    final session = PushSession(auth, chat, native, navigated.add);
    await session.start();
    expect(navigated, isEmpty);
    auth.add(const AuthStarted());
    await until(() => auth.state.user != null);
    chat.setAccount(account);
    await until(
      () =>
          navigated.length == 1 &&
          adapter.requests.any((r) => r.method == 'PUT'),
    );
    expect(navigated.single.roomId, roomId);
    native.taps.add(native.initial!);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(navigated, hasLength(1));
    native.tokenEvents.add('rotated-token');
    await until(
      () => adapter.requests.any(
        (r) => r.data is Map && r.data['token'] == 'rotated-token',
      ),
    );
    native.messages.add(native.initial!);
    await until(() => sync.contains(roomId));
    native.taps.add({
      'roomId': roomId,
      'messageId': '44444444-4444-4444-8444-444444444444',
      'recipientId': '55555555-5555-4555-8555-555555555555',
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(navigated, hasLength(1));
    auth.add(const AuthSignOutRequested());
    await until(() => auth.state is AuthUnauthenticated);
    expect(native.deleted, greaterThan(0));
    expect(
      adapter.requests.any(
        (r) =>
            r.method == 'DELETE' && r.path.startsWith('/api/v1/push/devices/'),
      ),
      isTrue,
    );
    await session.dispose();
    await sub.cancel();
    await chat.dispose();
    await auth.close();
    await native.close();
  });
  test(
    'disabled Firebase makes no network or permission-dependent registration',
    () async {
      final dio = Dio();
      final auth = AuthBloc(AuthRepository(dio, MemoryTokens(), FakeOAuth()));
      final chat = ChatRepository(ChatApi(dio));
      final native = FakePush()..enabled = false;
      final session = PushSession(auth, chat, native, (_) {});
      await session.start();
      expect(auth.repository.beforeSignOut, isNull);
      await session.dispose();
      await chat.dispose();
      await auth.close();
      await native.close();
    },
  );
}
