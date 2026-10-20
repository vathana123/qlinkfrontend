import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/core/error/app_exception.dart';
import 'package:qlinkfrontend/core/network/api_endpoints.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/datasources/oauth_provider.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';

import 'support/fakes.dart';

void main() {
  late MemoryTokens storage;
  late FakeOAuth oauth;
  late Dio dio;
  late AuthRepository repository;
  setUp(() {
    storage = MemoryTokens();
    oauth = FakeOAuth();
    dio = DioClient(storage).dio;
    repository = AuthRepository(dio, storage, oauth);
  });
  for (final signUp in [false, true]) {
    test(
      'Google ${signUp ? 'signup' : 'signin'} uses actual request and envelope',
      () async {
        final adapter = FakeAdapter(
          (r) => response(
            envelope(r.path == ApiEndpoints.me ? userJson : sessionJson()),
          ),
        );
        dio.httpClientAdapter = adapter;
        final user = await repository.authenticate(
          AuthProvider.google,
          signUp: signUp,
        );
        expect(
          adapter.requests.first.path,
          signUp ? ApiEndpoints.signUp : ApiEndpoints.signIn,
        );
        expect(adapter.requests.first.data, {
          'provider': 'GOOGLE',
          'idToken': 'provider-id-token',
        });
        expect(adapter.requests, hasLength(1));
        expect(user.displayName, 'Maya Chen');
        expect(storage.tokens?.refreshToken, 'new-refresh');
      },
    );
  }
  test(
    'Apple sends hashed nonce to provider and raw nonce to backend',
    () async {
      final adapter = FakeAdapter(
        (r) => response(
          envelope(switch (r.path) {
            ApiEndpoints.nonce => {
              'nonce': 'raw-challenge',
              'nonceHash': 'hash-challenge',
              'expiresAt': '2026-10-17T00:00:00Z',
            },
            ApiEndpoints.me => userJson,
            _ => sessionJson(),
          }),
        ),
      );
      dio.httpClientAdapter = adapter;
      await repository.authenticate(AuthProvider.apple, signUp: true);
      expect(oauth.receivedHash, 'hash-challenge');
      expect(adapter.requests.first.data, {'provider': 'APPLE'});
      expect(adapter.requests[1].data, {
        'provider': 'APPLE',
        'idToken': 'provider-id-token',
        'nonce': 'raw-challenge',
      });
    },
  );
  test('canceled provider never calls signin or saves tokens', () async {
    oauth.error = const AppException('Canceled', canceled: true);
    final adapter = FakeAdapter((_) => response({}));
    dio.httpClientAdapter = adapter;
    await expectLater(
      repository.authenticate(AuthProvider.google, signUp: false),
      throwsA(isA<AppException>()),
    );
    expect(adapter.requests, isEmpty);
    expect(storage.tokens, null);
  });
  test('restoration validates stored session via me', () async {
    expect(await repository.restore(), null);
    storage.tokens = const TokenPair('access', 'refresh');
    final adapter = FakeAdapter((_) => response(envelope(userJson)));
    dio.httpClientAdapter = adapter;
    expect((await repository.restore())?.id, 'user-1');
    expect(adapter.requests.single.path, ApiEndpoints.me);
  });
  test(
    'expired startup access token refreshes once then loads current user',
    () async {
      storage.tokens = const TokenPair('expired-access', 'refresh');
      final adapter = FakeAdapter((r) {
        if (r.path == ApiEndpoints.refresh) {
          return response(envelope(sessionJson()));
        }
        return r.headers['Authorization'] == 'Bearer new-access'
            ? response(envelope(userJson))
            : response({}, status: 401);
      });
      dio.httpClientAdapter = adapter;
      expect((await repository.restore())?.id, 'user-1');
      expect(adapter.requests.map((r) => r.path).toList(), [
        ApiEndpoints.me,
        ApiEndpoints.refresh,
        ApiEndpoints.me,
      ]);
      expect(storage.tokens?.refreshToken, 'new-refresh');
    },
  );
  test(
    'invalid startup refresh clears credentials without retry loops',
    () async {
      storage.tokens = const TokenPair('expired-access', 'revoked-refresh');
      final adapter = FakeAdapter((_) => response({}, status: 401));
      dio.httpClientAdapter = adapter;
      await expectLater(repository.restore(), throwsA(isA<DioException>()));
      expect(storage.tokens, null);
      expect(adapter.requests.map((r) => r.path).toList(), [
        ApiEndpoints.me,
        ApiEndpoints.refresh,
      ]);
    },
  );
  test(
    'signout uses bearer session, no body, then deletes credentials',
    () async {
      storage.tokens = const TokenPair('access', 'refresh');
      final adapter = FakeAdapter((r) {
        expect(storage.tokens, isNotNull);
        return response(envelope(null));
      });
      dio.httpClientAdapter = adapter;
      expect(await repository.signOut(), null);
      expect(adapter.requests.single.path, ApiEndpoints.signOut);
      expect(adapter.requests.single.data, null);
      expect(adapter.requests.single.headers['Authorization'], 'Bearer access');
      expect(storage.tokens, null);
    },
  );
  test('unreachable signout clears locally and explicitly warns', () async {
    storage.tokens = const TokenPair('access', 'refresh');
    dio.httpClientAdapter = FakeAdapter(
      (r) => throw DioException(
        requestOptions: r,
        type: DioExceptionType.connectionError,
      ),
    );
    expect(
      await repository.signOut(),
      contains('revocation could not be confirmed'),
    );
    expect(storage.tokens, null);
  });
  for (final code in [
    'NOT_REGISTERED',
    'ALREADY_REGISTERED',
    'INVALID_PROVIDER_TOKEN',
  ]) {
    test('backend $code maps to safe message', () async {
      dio.httpClientAdapter = FakeAdapter(
        (_) => response({
          'success': false,
          'message': 'secret must not be shown',
          'data': {'code': code, 'fields': {}},
        }, status: 400),
      );
      try {
        await repository.authenticate(AuthProvider.google, signUp: false);
        fail('Expected API failure');
      } catch (e) {
        final message = AppException.from(e).message;
        expect(message, isNot(contains('secret')));
        expect(message, isNot(contains('Unable to connect')));
      }
      expect(storage.tokens, null);
    });
  }
}
