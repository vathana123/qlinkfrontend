import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../storage/token_storage.dart';
import '../error/app_exception.dart';
import 'api_endpoints.dart';

class AuthInterceptor extends Interceptor {
  AuthInterceptor(this._dio, this._storage);
  final Dio _dio;
  final TokenStorage _storage;
  void Function()? onSessionExpired;
  Future<TokenPair>? _refreshing;
  bool _expired = false;
  final _tokenChanges = StreamController<String>.broadcast();
  Stream<String> get tokenChanges => _tokenChanges.stream;
  bool _apiOrigin(RequestOptions request) =>
      request.uri.origin == Uri.parse(_dio.options.baseUrl).origin;
  bool _public(RequestOptions request) =>
      ApiEndpoints.publicPaths.contains(request.uri.path);
  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      if (!_apiOrigin(options)) {
        handler.next(options);
        return;
      }
      // Dio merges default and per-request headers before interceptors run.
      // A stale bearer can make Spring reject even a permitAll endpoint.
      options.headers = {
        for (final entry in options.headers.entries)
          if (entry.key.toLowerCase() != 'authorization')
            entry.key: entry.value,
      };
      if (!_public(options)) {
        // A refresh already in flight owns credential renewal. Do not send
        // additional protected requests with the token it is replacing.
        final refreshing = _refreshing;
        if (refreshing != null) await refreshing;
        final tokens = await _storage.read();
        final expected = options.extra['expectedAccountId'];
        if (expected != null) {
          String? subject;
          try {
            subject =
                (jsonDecode(
                      utf8.decode(
                        base64Url.decode(
                          base64Url.normalize(
                            tokens!.accessToken.split('.')[1],
                          ),
                        ),
                      ),
                    ) as Map)['sub']
                    as String?;
          } catch (_) {}
          final sessionAccount = _dio.options.extra['authenticatedAccountId'];
          if ((subject != null && subject != expected) ||
              (subject == null && sessionAccount != expected)) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.cancel,
                error: const AppException(
                  'Account changed. Pending message retained.',
                ),
              ),
            );
            return;
          }
        }
        if (tokens != null) {
          options.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
          _expired = false;
        }
      }
      handler.next(options);
    } catch (error) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: error is DioException
              ? error.error
              : const AppException(
                  'Session verification is temporarily unavailable. Please retry.',
                ),
        ),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final error = err;
    final request = error.requestOptions;
    if (error.response?.statusCode != 401 ||
        !_apiOrigin(request) ||
        _public(request) ||
        request.headers['Authorization'] == null) {
      handler.next(error);
      return;
    }
    try {
      if (request.extra['authRetried'] == true) {
        await _expire();
        handler.next(error);
        return;
      }
      final current = await _storage.read();
      if (current == null) throw StateError('No session');
      // A late 401 can arrive after another request already rotated tokens.
      final tokens =
          request.headers['Authorization'] != 'Bearer ${current.accessToken}'
          ? current
          : await _refreshOnce();
      handler.resolve(
        await _dio.fetch<dynamic>(
          request.copyWith(
            data: request.data is FormData
                ? (request.data as FormData).clone()
                : request.data,
            headers: {
              ...request.headers,
              'Authorization': 'Bearer ${tokens.accessToken}',
            },
            extra: {...request.extra, 'authRetried': true},
          ),
        ),
      );
    } on DioException catch (retryError) {
      // Refresh expires inside _rotate; a retried request's 5xx is not logout.
      handler.next(retryError);
    } catch (_) {
      // Local storage/decoding failures are not proof that credentials were revoked.
      handler.next(
        error.copyWith(
          error: const AppException(
            'Session verification is temporarily unavailable. Please retry.',
          ),
        ),
      );
    }
  }

  Future<String> socketAccessToken({String? rejectedToken}) async {
    final current = await _storage.read();
    if (current == null) throw StateError('No session');
    final expiry = accessTokenExpiry(current.accessToken);
    if (rejectedToken == current.accessToken ||
        expiry != null &&
            !expiry.isAfter(
              DateTime.now().toUtc().add(const Duration(seconds: 45)),
            )) {
      return (await _refreshOnce()).accessToken;
    }
    return current.accessToken;
  }

  Future<TokenPair> _refreshOnce() async {
    if (_refreshing != null) return _refreshing!;
    final future = _rotate();
    _refreshing = future;
    try {
      return await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<TokenPair> _rotate() async {
    final old = await _storage.read();
    try {
      if (old == null) throw StateError('No refresh token');
      final response = await _dio.post<dynamic>(
        ApiEndpoints.refresh,
        data: {'refreshToken': old.refreshToken},
      );
      final tokens = TokenPair.fromJson(ApiEndpoints.data(response.data));
      if ((await _storage.read())?.refreshToken != old.refreshToken) {
        throw StateError('Session changed');
      }
      await _storage.write(tokens);
      _tokenChanges.add(tokens.accessToken);
      return tokens;
    } catch (error) {
      // A stale refresh must never clear a different account or revive a logged-out session.
      final terminal =
          error is DioException && error.response?.statusCode == 401;
      if (terminal &&
          old != null &&
          (await _storage.read())?.refreshToken == old.refreshToken) {
        await _expire();
      }
      if (terminal) rethrow;
      // Preserve the existing account-change cancellation contract.
      if (error is StateError) rethrow;
      const recoverable = AppException(
        'Session verification is temporarily unavailable. Please retry.',
      );
      if (error is DioException) throw error.copyWith(error: recoverable);
      throw DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.refresh),
        error: recoverable,
      );
    }
  }

  Future<void> _expire() async {
    try {
      await _storage.clear();
    } finally {
      if (!_expired) {
        _expired = true;
        onSessionExpired?.call();
      }
    }
  }
}
