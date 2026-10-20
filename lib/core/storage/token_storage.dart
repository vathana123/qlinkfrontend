import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenPair {
  const TokenPair(this.accessToken, this.refreshToken);
  final String accessToken;
  final String refreshToken;
  factory TokenPair.fromJson(Map<String, dynamic> json) {
    final access = json['accessToken'];
    final refresh = json['refreshToken'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty) {
      throw const FormatException('Invalid token response');
    }
    return TokenPair(access, refresh);
  }
  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
  };
}

class TokenStorage {
  TokenStorage({FlutterSecureStorage? secureStorage})
    : _storage = secureStorage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const key = 'qlink.session.v1';
  Future<TokenPair?> read() async {
    final value = await _storage.read(key: key);
    if (value == null) return null;
    try {
      return TokenPair.fromJson(jsonDecode(value) as Map<String, dynamic>);
    } on FormatException {
      await clear();
      return null;
    } on TypeError {
      await clear();
      return null;
    }
  }

  // One secure entry avoids partially written token pairs after rotation.
  Future<void> write(TokenPair tokens) =>
      _storage.write(key: key, value: jsonEncode(tokens.toJson()));
  Future<void> clear() => _storage.delete(key: key);
}

// Scheduling hint only. The backend remains responsible for validating JWTs.
DateTime? accessTokenExpiry(String token) {
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final seconds = payload['exp'];
    return seconds is num
        ? DateTime.fromMillisecondsSinceEpoch(
            seconds.toInt() * 1000,
            isUtc: true,
          )
        : null;
  } catch (_) {
    return null;
  }
}
