import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qlinkfrontend/core/error/app_exception.dart';
import 'package:qlinkfrontend/core/network/api_endpoints.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/datasources/oauth_provider.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';

import 'support/fakes.dart';

void main() {
  late MemoryTokens storage;
  late FakeOAuth oauth;
  late DioClient client;
  late AuthBloc bloc;
  setUp(() {
    storage = MemoryTokens();
    oauth = FakeOAuth();
    client = DioClient(storage);
    client.dio.httpClientAdapter = FakeAdapter(
      (r) => response(
        envelope(r.path == ApiEndpoints.me ? userJson : sessionJson()),
      ),
    );
    bloc = AuthBloc(AuthRepository(client.dio, storage, oauth));
    client.auth.onSessionExpired = () => bloc.add(const AuthSessionExpired());
  });
  tearDown(() async => bloc.close());
  test(
    'startup without credentials emits loading then unauthenticated',
    () async {
      final expectation = expectLater(
        bloc.stream,
        emitsInOrder([isA<AuthLoading>(), isA<AuthUnauthenticated>()]),
      );
      bloc.add(const AuthStarted());
      await expectation;
    },
  );
  test('startup validates credentials before authenticating', () async {
    storage.tokens = const TokenPair('access', 'refresh');
    final expectation = expectLater(
      bloc.stream,
      emitsInOrder([isA<AuthLoading>(), isA<AuthAuthenticated>()]),
    );
    bloc.add(const AuthStarted());
    await expectation;
    expect(bloc.state.user?.displayName, 'Maya Chen');
  });
  for (final signup in [false, true]) {
    test(
      '${signup ? 'signup' : 'signin'} emits loading then authenticated',
      () async {
        final expectation = expectLater(
          bloc.stream,
          emitsInOrder([isA<AuthLoading>(), isA<AuthAuthenticated>()]),
        );
        bloc.add(
          signup
              ? const AuthSignUpRequested(AuthProvider.google)
              : const AuthSignInRequested(AuthProvider.google),
        );
        await expectation;
      },
    );
  }
  test('duplicate submissions are dropped while provider is open', () async {
    oauth.pending = Completer<String>();
    bloc.add(const AuthSignInRequested(AuthProvider.google));
    bloc.add(const AuthSignUpRequested(AuthProvider.google));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(oauth.calls, 1);
    final completed = bloc.stream.firstWhere((s) => s is AuthAuthenticated);
    oauth.pending!.complete('token');
    await completed;
  });
  test(
    'provider cancellation returns to unauthenticated without failure',
    () async {
      oauth.error = const AppException('Canceled', canceled: true);
      final expectation = expectLater(
        bloc.stream,
        emitsInOrder([isA<AuthLoading>(), isA<AuthUnauthenticated>()]),
      );
      bloc.add(const AuthSignInRequested(AuthProvider.google));
      await expectation;
    },
  );
  test('provider error becomes safe failure', () async {
    oauth.error = const AppException('Try again');
    final completed = bloc.stream.firstWhere((s) => s is AuthFailure);
    bloc.add(const AuthSignInRequested(AuthProvider.google));
    expect((await completed as AuthFailure).message, 'Try again');
  });
  test(
    'invalid refresh expires startup and cannot emit authenticated afterwards',
    () async {
      storage.tokens = const TokenPair('access', 'refresh');
      client.dio.httpClientAdapter = FakeAdapter(
        (_) => response({}, status: 401),
      );
      final completed = bloc.stream.firstWhere((s) => s is AuthUnauthenticated);
      bloc.add(const AuthStarted());
      await completed;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bloc.state, isA<AuthUnauthenticated>());
      expect(storage.tokens, null);
    },
  );
  test(
    'signout preserves profile while loading and then clears authentication',
    () async {
      storage.tokens = const TokenPair('access', 'refresh');
      final restored = bloc.stream.firstWhere((s) => s is AuthAuthenticated);
      bloc.add(const AuthStarted());
      await restored;
      final expectation = expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthLoading>().having((s) => s.user?.id, 'user', 'user-1'),
          isA<AuthUnauthenticated>(),
        ]),
      );
      bloc.add(const AuthSignOutRequested());
      await expectation;
      expect(storage.tokens, null);
    },
  );
  test('offline signout emits explicit remote revocation warning', () async {
    storage.tokens = const TokenPair('access', 'refresh');
    client.dio.httpClientAdapter = FakeAdapter(
      (_) => response({}, status: 503),
    );
    final completed = bloc.stream.firstWhere((s) => s is AuthUnauthenticated);
    bloc.add(const AuthSignOutRequested());
    expect(
      (await completed as AuthUnauthenticated).message,
      contains('revocation could not be confirmed'),
    );
  });
}
