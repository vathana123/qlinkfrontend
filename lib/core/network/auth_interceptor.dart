import 'dart:async';

import 'package:dio/dio.dart';

import '../storage/token_storage.dart';
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
        final tokens = await _storage.read();
        if (tokens != null) {
          options.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
          _expired = false;
        }
      }
      handler.next(options);
    } catch (_) {
      handler.reject(DioException(requestOptions: options));
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
      try {
        await _expire();
      } catch (_) {
        // An unavailable secure store must not leave Dio's handler open.
        // _expire still notifies AuthBloc in its finally block.
      }
      handler.next(error);
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
    } catch (_) {
      // A stale refresh must never clear a different account or revive a logged-out session.
      if (old != null &&
          (await _storage.read())?.refreshToken == old.refreshToken) {
        await _expire();
      }
      rethrow;
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
