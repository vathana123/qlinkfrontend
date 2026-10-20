import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../../core/error/app_exception.dart';
import '../../../../core/config/app_config.dart';

enum AuthProvider { google, apple }

abstract interface class OAuthProvider {
  Future<String> authenticate(AuthProvider provider, {String? nonceHash});
}

class NativeOAuthProvider implements OAuthProvider {
  Future<void>? _initialization;
  static bool get supportsGoogle =>
      !kIsWeb &&
      {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);
  static bool get supportsApple =>
      !kIsWeb &&
      {
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);
  @override
  Future<String> authenticate(
    AuthProvider provider, {
    String? nonceHash,
  }) async {
    try {
      String? token;
      if (provider == AuthProvider.google) {
        if (!supportsGoogle) {
          throw const AppException(
            'Google sign-in is available in the Android and Apple apps.',
          );
        }
        if (AppConfig.googleServerClientId.trim().isEmpty) {
          throw const AppException(
            'Google sign-in is not configured. Start with qLink Development or pass --dart-define-from-file=env/development.json.',
          );
        }
        _initialization ??= GoogleSignIn.instance
            .initialize(
              serverClientId: AppConfig.googleServerClientId,
              clientId: AppConfig.googleClientId.isEmpty
                  ? null
                  : AppConfig.googleClientId,
            )
            .catchError((Object error) {
              _initialization = null;
              throw error;
            });
        await _initialization;
        final account = await GoogleSignIn.instance.authenticate();
        token = account.authentication.idToken;
      } else {
        if (!supportsApple || !await SignInWithApple.isAvailable()) {
          throw const AppException(
            'Apple sign-in is not available on this device.',
          );
        }
        if (nonceHash == null) {
          throw const AppException('Unable to start secure Apple sign-in.');
        }
        token = (await SignInWithApple.getAppleIDCredential(
          scopes: [
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
          nonce: nonceHash,
        )).identityToken;
      }
      if (token == null || token.isEmpty) {
        throw const AppException(
          'The provider did not return an identity token. Please try again.',
        );
      }
      return token;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const AppException('Sign-in canceled.', canceled: true);
      }
      throw const AppException(
        'Google sign-in failed. Check your connection and provider configuration.',
      );
    } on SignInWithAppleAuthorizationException catch (error) {
      if (error.code == AuthorizationErrorCode.canceled) {
        throw const AppException('Sign-in canceled.', canceled: true);
      }
      throw const AppException('Apple sign-in failed. Please try again.');
    }
  }
}
