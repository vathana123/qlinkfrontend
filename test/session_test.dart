import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/core/network/api_endpoints.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';

import 'support/fakes.dart';

void main() {
  late MemoryTokens storage;
  late DioClient client;
  setUp(() {
    storage = MemoryTokens()
      ..tokens = const TokenPair('old-access', 'old-refresh');
    client = DioClient(storage);
  });
  for (final path in ApiEndpoints.publicPaths) {
    test('public $path strips inherited and per-request bearer headers', () async {
      client.dio.options.headers['Authorization'] = 'Bearer stale-default';
      final adapter = FakeAdapter((request) {
        final hasBearer = request.headers.keys.any(
          (key) => key.toLowerCase() == 'authorization',
        );
        // Model Spring's bearer filter running before permitAll authorization.
        return response(envelope(sessionJson()), status: hasBearer ? 401 : 200);
      });
      client.dio.httpClientAdapter = adapter;
      final result = await client.dio.post<dynamic>(
        path,
        options: Options(headers: {'authorization': 'Bearer stale-request'}),
      );
      expect(result.statusCode, 200);
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers.keys.any(
          (key) => key.toLowerCase() == 'authorization',
        ),
        false,
      );
    });
  }
  test(
    'protected request replaces stale headers with the secure access token',
    () async {
      client.dio.options.headers['authorization'] = 'Bearer stale-default';
      final adapter = FakeAdapter((_) => response(envelope(userJson)));
      client.dio.httpClientAdapter = adapter;
      await client.dio.get<dynamic>(ApiEndpoints.me);
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer old-access',
      );
      expect(
        adapter.requests.single.headers.keys.where(
          (key) => key.toLowerCase() == 'authorization',
        ),
        hasLength(1),
      );
    },
  );
  test('unsigned 401 is not eligible for refresh', () async {
    storage.tokens = null;
    client.dio.options.headers['Authorization'] = 'Bearer stale-default';
    final adapter = FakeAdapter((_) => response({}, status: 401));
    client.dio.httpClientAdapter = adapter;
    await expectLater(
      client.dio.get<dynamic>(ApiEndpoints.me),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.headers.containsKey('Authorization'), false);
  });
  test(
    'other origins receive no app token and cannot trigger refresh or logout',
    () async {
      var expired = 0;
      client.auth.onSessionExpired = () => expired++;
      final adapter = FakeAdapter((_) => response({}, status: 401));
      client.dio.httpClientAdapter = adapter;
      await expectLater(
        client.dio.get<dynamic>('https://other.example/api/v1/auth/me'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, hasLength(1));
      expect(
        adapter.requests.single.headers.containsKey('Authorization'),
        false,
      );
      expect(storage.tokens?.accessToken, 'old-access');
      expect(expired, 0);
    },
  );
  test(
    'JSON and timeout configuration; bearer only for protected endpoints',
    () async {
      final adapter = FakeAdapter((_) => response(envelope(userJson)));
      client.dio.httpClientAdapter = adapter;
      await client.dio.get<dynamic>(ApiEndpoints.me);
      await client.dio.post<dynamic>(ApiEndpoints.signIn);
      expect(
        adapter.requests.first.headers['Authorization'],
        'Bearer old-access',
      );
      expect(adapter.requests.last.headers.containsKey('Authorization'), false);
      expect(client.dio.options.contentType, Headers.jsonContentType);
      expect(client.dio.options.connectTimeout, const Duration(seconds: 15));
      expect(client.dio.options.sendTimeout, const Duration(seconds: 15));
      expect(client.dio.options.receiveTimeout, const Duration(seconds: 20));
    },
  );
  test(
    'concurrent 401s share one refresh and both retry with rotated tokens',
    () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final refreshing = Completer<void>();
      client.dio.httpClientAdapter = FakeAdapter((request) async {
        if (request.path == ApiEndpoints.refresh) {
          refreshes++;
          refreshing.complete();
          expect(request.data, {'refreshToken': 'old-refresh'});
          expect(request.headers.containsKey('Authorization'), false);
          await gate.future;
          return response(envelope(sessionJson()));
        }
        return request.headers['Authorization'] == 'Bearer new-access'
            ? response(envelope(userJson))
            : response({}, status: 401);
      });
      final a = client.dio.get<dynamic>(ApiEndpoints.me);
      final b = client.dio.get<dynamic>(ApiEndpoints.me);
      await refreshing.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await Future.wait([a, b]);
      expect(refreshes, 1);
      expect(storage.tokens?.refreshToken, 'new-refresh');
      expect(storage.writes, 1);
    },
  );
  test('late old-token 401 reuses tokens without a second refresh', () async {
    final late = Completer<void>();
    var refreshes = 0;
    client.dio.httpClientAdapter = FakeAdapter((request) async {
      if (request.path == ApiEndpoints.refresh) {
        refreshes++;
        return response(envelope(sessionJson()));
      }
      if (request.headers['Authorization'] == 'Bearer new-access') {
        return response(envelope(userJson));
      }
      if (request.queryParameters['late'] == true) await late.future;
      return response({}, status: 401);
    });
    final pending = client.dio.get<dynamic>(
      ApiEndpoints.me,
      queryParameters: {'late': true},
    );
    await client.dio.get<dynamic>(ApiEndpoints.me);
    late.complete();
    await pending;
    expect(refreshes, 1);
  });
  for (final status in [401]) {
    test(
      'refresh $status clears session and never recursively refreshes',
      () async {
        var expired = 0;
        client.auth.onSessionExpired = () => expired++;
        final adapter = FakeAdapter(
          (request) => response(
            {},
            status: request.path == ApiEndpoints.refresh ? status : 401,
          ),
        );
        client.dio.httpClientAdapter = adapter;
        await expectLater(
          client.dio.get<dynamic>(ApiEndpoints.me),
          throwsA(isA<DioException>()),
        );
        expect(storage.tokens, null);
        expect(expired, 1);
        expect(
          adapter.requests.where((r) => r.path == ApiEndpoints.refresh).length,
          1,
        );
      },
    );
  }
  for (final failure in <Object>[
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    500,
    502,
    503,
    504,
  ]) {
    test(
      'refresh $failure preserves credentials and permits later recovery',
      () async {
        var expired = 0, refreshes = 0;
        var recover = false;
        client.auth.onSessionExpired = () => expired++;
        final adapter = FakeAdapter((request) {
          if (request.path == ApiEndpoints.refresh) {
            refreshes++;
            if (recover) return response(envelope(sessionJson()));
            if (failure is int) return response({}, status: failure);
            throw DioException(
              requestOptions: request,
              type: failure as DioExceptionType,
            );
          }
          return request.headers['Authorization'] == 'Bearer new-access'
              ? response(envelope(userJson))
              : response({}, status: 401);
        });
        client.dio.httpClientAdapter = adapter;
        await expectLater(
          client.dio.get<dynamic>(ApiEndpoints.me),
          throwsA(isA<DioException>()),
        );
        expect(storage.tokens?.refreshToken, 'old-refresh');
        expect(expired, 0);
        expect(refreshes, 1);
        expect(
          adapter.requests,
          hasLength(2),
        ); // No protected retry after failure.
        recover = true;
        expect(
          (await client.dio.get<dynamic>(ApiEndpoints.me)).statusCode,
          200,
        );
        expect(storage.tokens?.refreshToken, 'new-refresh');
        expect(refreshes, 2);
      },
    );
  }

  test(
    'concurrent recoverable refresh failure is shared and new requests wait',
    () async {
      final refreshing = Completer<void>(), release = Completer<void>();
      var refreshes = 0, protected = 0;
      client.dio.httpClientAdapter = FakeAdapter((request) async {
        if (request.path == ApiEndpoints.refresh) {
          refreshes++;
          refreshing.complete();
          await release.future;
          return response({}, status: 503);
        }
        protected++;
        return response({}, status: 401);
      });
      final a = expectLater(
        client.dio.get<dynamic>(ApiEndpoints.me),
        throwsA(isA<DioException>()),
      );
      await refreshing.future;
      final b = expectLater(
        client.dio.get<dynamic>('/api/v1/chat/rooms'),
        throwsA(isA<DioException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(protected, 1);
      release.complete();
      await Future.wait([a, b]);
      expect(refreshes, 1);
      expect(protected, 1);
      expect(storage.tokens?.refreshToken, 'old-refresh');
    },
  );

  test('retry is bounded to once if fresh access token is rejected', () async {
    var expired = 0;
    client.auth.onSessionExpired = () => expired++;
    final adapter = FakeAdapter(
      (r) => r.path == ApiEndpoints.refresh
          ? response(envelope(sessionJson()))
          : response({}, status: 401),
    );
    client.dio.httpClientAdapter = adapter;
    await expectLater(
      client.dio.get<dynamic>(ApiEndpoints.me),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests.length, 3);
    expect(storage.tokens, null);
    expect(expired, 1);
  });
  test('retry server error preserves successfully refreshed session', () async {
    client.dio.httpClientAdapter = FakeAdapter(
      (r) => r.path == ApiEndpoints.refresh
          ? response(envelope(sessionJson()))
          : response({}, status: r.extra['authRetried'] == true ? 503 : 401),
    );
    await expectLater(
      client.dio.get<dynamic>(ApiEndpoints.me),
      throwsA(isA<DioException>()),
    );
    expect(storage.tokens?.accessToken, 'new-access');
  });
  test('public authentication failure does not refresh', () async {
    final adapter = FakeAdapter((_) => response({}, status: 401));
    client.dio.httpClientAdapter = adapter;
    await expectLater(
      client.dio.post<dynamic>(ApiEndpoints.signIn),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests.length, 1);
    expect(storage.tokens?.accessToken, 'old-access');
  });
}
