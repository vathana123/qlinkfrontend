import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/datasources/oauth_provider.dart';

class MemoryTokens extends TokenStorage {
  TokenPair? tokens;
  int writes = 0;
  @override
  Future<TokenPair?> read() async => tokens;
  @override
  Future<void> write(TokenPair value) async {
    writes++;
    tokens = value;
  }

  @override
  Future<void> clear() async {
    tokens = null;
  }
}

class FakeOAuth implements OAuthProvider {
  Object? error;
  String? receivedHash;
  int calls = 0;
  Completer<String>? pending;
  @override
  Future<String> authenticate(
    AuthProvider provider, {
    String? nonceHash,
  }) async {
    calls++;
    receivedHash = nonceHash;
    if (error != null) throw error!;
    return pending == null ? 'provider-id-token' : pending!.future;
  }
}

typedef Reply = FutureOr<ResponseBody> Function(RequestOptions options);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.reply);
  final Reply reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody response(Object? data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
Map<String, dynamic> envelope(Object? data) => {
  'success': true,
  'message': 'OK',
  'data': data,
};
const userJson = {
  'id': 'user-1',
  'displayName': 'Maya Chen',
  'email': 'maya@example.com',
  'avatarUrl': null,
  'status': 'ACTIVE',
};
Map<String, dynamic> sessionJson([
  String access = 'new-access',
  String refresh = 'new-refresh',
]) => {
  'accessToken': access,
  'refreshToken': refresh,
  'tokenType': 'Bearer',
  'expiresIn': 900,
  'user': userJson,
};
