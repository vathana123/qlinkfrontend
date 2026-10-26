import 'package:dio/dio.dart';

import '../../../../core/network/api_endpoints.dart';
import '../../../../core/storage/token_storage.dart';
import '../datasources/oauth_provider.dart';
import '../models/app_user.dart';

class AuthRepository {
  AuthRepository(this.dio, this.storage, this.oauth);
  Future<void> Function()? beforeSignOut;
  final Dio dio;
  final TokenStorage storage;
  final OAuthProvider oauth;
  Future<AppUser?> restore() async {
    if (await storage.read() == null) return null;
    return currentUser();
  }

  Future<AppUser> currentUser() async => AppUser.fromJson(
    ApiEndpoints.data((await dio.get<dynamic>(ApiEndpoints.me)).data),
  );
  Future<AppUser> authenticate(
    AuthProvider provider, {
    required bool signUp,
  }) async {
    String? nonce;
    String? hash;
    if (provider == AuthProvider.apple) {
      final challenge = ApiEndpoints.data(
        (await dio.post<dynamic>(
          ApiEndpoints.nonce,
          data: {'provider': 'APPLE'},
        )).data,
      );
      nonce = challenge['nonce'] as String;
      hash = challenge['nonceHash'] as String;
    }
    final idToken = await oauth.authenticate(provider, nonceHash: hash);
    final result = await dio.post<dynamic>(
      signUp ? ApiEndpoints.signUp : ApiEndpoints.signIn,
      data: {
        'provider': provider.name.toUpperCase(),
        'idToken': idToken,
        'nonce': ?nonce,
      },
    );
    final data = ApiEndpoints.data(result.data);
    final user = AppUser.fromJson(
      Map<String, dynamic>.from(data['user'] as Map),
    );
    await storage.write(TokenPair.fromJson(data));
    // The exchange already returns the authenticated profile. Reserve /me for
    // restoration; a second request must not turn a successful login into failure.
    return user;
  }

  /// Null means remote revocation succeeded. Otherwise local sign-out only.
  Future<String?> signOut() async {
    String? warning;
    try {
      await beforeSignOut?.call();
    } catch (_) {}
    try {
      await dio.post<dynamic>(ApiEndpoints.signOut);
    } catch (_) {
      warning = 'Signed out on this device. Server revocation could not be confirmed; the remote session may remain active until it expires.';
    }
    await storage.clear();
    return warning;
  }
}
