import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/storage/token_storage.dart';
import '../../core/config/app_config.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

@pragma('vm:entry-point')
Future<void> qlinkBackgroundMessage(RemoteMessage message) async {
  debugPrint('qLink push: background message received');
  // The OS presents the generic notification. Full synchronization and token
  // renewal stay on the main isolate; background delivery uses valid access only.
  try {
    await Firebase.initializeApp();
    final tokens = await TokenStorage().read();
    if (tokens == null) return;
    final payload = jsonDecode(
      utf8.decode(
        base64Url.decode(base64Url.normalize(tokens.accessToken.split('.')[1])),
      ),
    ) as Map;
    if (payload['sub'] != message.data['recipientId']) return;
    final expiry = accessTokenExpiry(tokens.accessToken);
    if (expiry == null || !expiry.isAfter(DateTime.now().toUtc())) return;
    final room = message.data['roomId'], id = message.data['messageId'];
    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    if (room is! String ||
        id is! String ||
        !uuid.hasMatch(room) ||
        !uuid.hasMatch(id)) {
      return;
    }
    // Never rotate refresh tokens in a background isolate: the foreground
    // interceptor owns renewal. An expired/revoked access token waits for resume.
    final dio = Dio(
      BaseOptions(
        baseUrl: AppConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
    try {
      await dio.post<dynamic>(
        '/api/v1/chat/rooms/$room/receipts',
        data: {
          'messageIds': [id],
          'seen': false,
        },
        options: Options(
          headers: {'Authorization': 'Bearer ${tokens.accessToken}'},
        ),
      );
    } finally {
      dio.close(force: true);
    }
  } catch (error) {
    debugPrint(
      'qLink push: background receipt failed type=${error.runtimeType}',
    );
  }
}

abstract class PushClient {
  Future<bool> initialize();
  Future<bool> requestPermission();
  Future<String?> token();
  Future<void> deleteToken();
  Future<Map<String, dynamic>?> initialMessage();
  Stream<String> get tokens;
  Stream<Map<String, dynamic>> get foreground;
  Stream<Map<String, dynamic>> get opened;
  String get platform;
}

class FirebasePushClient implements PushClient {
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  @override
  String get platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'IOS' : 'ANDROID';
  @override
  Future<bool> initialize() async {
    if (!const bool.fromEnvironment('QLINK_FCM_ENABLED') ||
        kIsWeb ||
        ![
          TargetPlatform.android,
          TargetPlatform.iOS,
        ].contains(defaultTargetPlatform)) {
      debugPrint(
        'qLink push: disabled or unsupported platform; '
        'QLINK_FCM_ENABLED=${const bool.fromEnvironment('QLINK_FCM_ENABLED')}',
      );
      return false;
    }
    try {
      final app = await Firebase.initializeApp();
      debugPrint(
        'qLink push: Firebase initialized project=${app.options.projectId}',
      );
      FirebaseMessaging.onBackgroundMessage(qlinkBackgroundMessage);
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
      return true;
    } catch (error) {
      debugPrint(
        'qLink push: initialization failed type=${error.runtimeType}; '
        'check Firebase platform setup',
      );
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    final permission = await _messaging.requestPermission();
    debugPrint('qLink push: permission=${permission.authorizationStatus.name}');
    return [
      AuthorizationStatus.authorized,
      AuthorizationStatus.provisional,
    ].contains(permission.authorizationStatus);
  }

  @override
  Future<String?> token() async {
    await _messaging.setAutoInitEnabled(true);
    final token = await _messaging.getToken();
    debugPrint('qLink push: token available=${token != null}');
    return token;
  }

  @override
  Future<void> deleteToken() async {
    await _messaging.setAutoInitEnabled(false);
    await _messaging.deleteToken();
  }

  @override
  Future<Map<String, dynamic>?> initialMessage() async =>
      (await _messaging.getInitialMessage())?.data;
  @override
  Stream<String> get tokens => _messaging.onTokenRefresh;
  @override
  Stream<Map<String, dynamic>> get foreground =>
      FirebaseMessaging.onMessage.map((m) => m.data);
  @override
  Stream<Map<String, dynamic>> get opened =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);
}
