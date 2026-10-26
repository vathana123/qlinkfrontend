import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../auth/presentation/bloc/auth_bloc.dart';
import '../chat/data/models/chat_models.dart';
import '../chat/data/repositories/chat_repository.dart';
import 'push_client.dart';

class PushSession {
  PushSession(
    this.auth,
    this.chat,
    this.client,
    this.navigate, {
    FlutterSecureStorage? storage,
  }) : storage = storage ?? const FlutterSecureStorage();
  final AuthBloc auth;
  final ChatRepository chat;
  final PushClient client;
  final void Function(Conversation) navigate;
  final FlutterSecureStorage storage;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _opened = <String>{};
  bool _enabled = false, _disposed = false;
  int _generation = 0, _attempts = 0;
  String? _account, _token, _installation;
  Map<String, dynamic>? _pending;
  Timer? _retry;
  CancelToken _cancel = CancelToken();
  Future<void> start() async {
    if (!await client.initialize() || _disposed) return;
    _enabled = true;
    auth.repository.beforeSignOut = unregister;
    _subscriptions.add(
      client.tokens.listen((token) {
        debugPrint('qLink push: token refreshed');
        _token = token;
        unawaited(_register());
      }),
    );
    _subscriptions.add(
      client.foreground.listen((data) {
        if (_valid(data) && data['recipientId'] == _account) {
          debugPrint(
            'qLink push: foreground message; banner intentionally suppressed',
          );
          chat.acknowledgeId(
            data['roomId'] as String,
            data['messageId'] as String,
          );
          chat.requestSynchronization(data['roomId'] as String);
        }
      }),
    );
    _subscriptions.add(client.opened.listen(_tap));
    _subscriptions.add(auth.stream.listen((s) => _apply(s.user?.id)));
    _apply(auth.state.user?.id);
    final initial = await client.initialMessage();
    if (initial != null) _tap(initial);
  }

  bool _valid(Map<String, dynamic> data) {
    final uuid = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return [
      'roomId',
      'messageId',
      'recipientId',
    ].every((key) => data[key] is String && uuid.hasMatch(data[key] as String));
  }

  void _apply(String? account) {
    if (_account != account) {
      _generation++;
      _cancel.cancel('Account changed');
      _cancel = CancelToken();
      _retry?.cancel();
      _attempts = 0;
      final old = _account;
      _account = account;
      if (account == null && old != null) {
        _token = null;
        unawaited(client.deleteToken().catchError((_) {}));
      }
      if (account != null) unawaited(_register());
    }
    if (account != null && _pending != null) {
      final pending = _pending!;
      _pending = null;
      _tap(pending);
    }
  }

  Future<void> _register() async {
    final account = _account, generation = _generation;
    if (!_enabled || _disposed || account == null) return;
    try {
      if (!await client.requestPermission()) return;
      _installation ??= await storage.read(key: 'qlink.push.installation.v1');
      _installation ??= const Uuid().v4();
      await storage.write(
        key: 'qlink.push.installation.v1',
        value: _installation,
      );
      final token = _token ?? await client.token();
      if (token == null || generation != _generation || _disposed) return;
      _token = token;
      await chat.api.dio.put<dynamic>(
        '/api/v1/push/devices/$_installation',
        data: {'token': token, 'platform': client.platform},
        options: Options(extra: {'expectedAccountId': account}),
        cancelToken: _cancel,
      );
      _attempts = 0;
      debugPrint(
        'qLink push: device registered account=$account installation=$_installation',
      );
    } catch (error) {
      // Never print exception messages/requests: they can contain the FCM token.
      final status = error is DioException ? error.response?.statusCode : null;
      debugPrint(
        'qLink push: registration failed type=${error.runtimeType} status=$status',
      );
      if (generation == _generation && !_disposed) {
        _retry?.cancel();
        _retry = Timer(Duration(seconds: 1 << (_attempts++).clamp(1, 6)), () {
          unawaited(_register());
        });
      }
    }
  }

  void resume() {
    if (_enabled && !_disposed) {
      unawaited(_register());
    }
  }

  void _tap(Map<String, dynamic> data) {
    if (!_valid(data) || _disposed) return;
    if (_account == null) {
      _pending = data;
      return;
    }
    if (data['recipientId'] != _account) return;
    final id = data['messageId'] as String;
    if (!_opened.add(id)) return;
    if (_opened.length > 200) _opened.remove(_opened.first);
    unawaited(_open(data));
  }

  Future<void> _open(Map<String, dynamic> data) async {
    final generation = _generation;
    try {
      final room = await chat.roomById(data['roomId'] as String);
      if (generation == _generation && !_disposed) {
        chat.requestSynchronization(room.id);
        navigate(Conversation.fromRoom(room));
      }
    } catch (_) {
      _opened.remove(data['messageId']);
    } // Removed/inaccessible rooms never bypass membership checks.
  }

  Future<void> unregister() async {
    _retry?.cancel();
    final account = _account;
    if (account != null && _installation != null) {
      try {
        await chat.api.dio
            .delete<dynamic>(
              '/api/v1/push/devices/$_installation',
              options: Options(extra: {'expectedAccountId': account}),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await client.deleteToken().timeout(const Duration(seconds: 5));
    } catch (_) {}
    _token = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    _cancel.cancel();
    auth.repository.beforeSignOut = null;
    for (final s in _subscriptions) {
      await s.cancel();
    }
  }
}
