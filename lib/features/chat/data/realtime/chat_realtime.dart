import 'dart:async';
import 'dart:math';

import '../../../../core/storage/token_storage.dart';
import 'chat_event.dart';
import 'chat_socket.dart';
import 'activity_event.dart';

enum ChatConnection { disconnected, reconnecting, connected }

typedef SocketTokenProvider = Future<String> Function({String? rejectedToken});

class ChatRealtime {
  ChatRealtime({
    required this.url,
    required this.tokenProvider,
    this.factory = NativeStompSocket.new,
    this.retryBase = const Duration(seconds: 1),
    this.retryMax = const Duration(seconds: 30),
    double Function()? jitter,
    Stream<String>? tokenChanges,
  }) : _jitter = jitter ?? Random().nextDouble {
    _tokens = tokenChanges?.listen((token) {
      if (_wanted && _socket != null && token != _token) {
        _stop();
        unawaited(_connect());
      }
    });
  }
  StreamSubscription<String>? _tokens;
  final String url;
  final SocketTokenProvider tokenProvider;
  final SocketFactory factory;
  final Duration retryBase, retryMax;
  final double Function() _jitter;
  final _events = StreamController<ChatEvent>.broadcast();
  final _states = StreamController<ChatConnection>.broadcast();
  final _activity = StreamController<ActivityEvent>.broadcast();
  Stream<ActivityEvent> get activity => _activity.stream;
  final _watchers = <String, int>{};
  void Function()? _cancelActivity;
  bool _activityReady = false;
  Timer? _watchTimer;
  void watch(String user, bool enabled, {String? account}) {
    if (account != null && account != _user) return;
    if (enabled) {
      _watchers[user] = (_watchers[user] ?? 0) + 1;
    } else {
      final remaining = (_watchers[user] ?? 1) - 1;
      if (remaining <= 0) {
        _watchers.remove(user);
      } else {
        _watchers[user] = remaining;
      }
    }
    _watchTimer?.cancel();
    _watchTimer = Timer(const Duration(milliseconds: 250), _sendWatches);
  }

  void _sendWatches() {
    if (_activityReady) {
      sendActivity('watch', {'userIds': _watchers.keys.take(100).toList()});
    }
  }

  void sendActivity(
    String action,
    Map<String, dynamic> payload, {
    String? account,
  }) {
    if (account != null && account != _user) return;
    final socket = _socket;
    if (state != ChatConnection.connected || socket is! ActivitySocket) return;
    try {
      (socket as ActivitySocket).sendActivity(action, payload);
    } catch (_) {}
  }

  Stream<ChatEvent> get events => _events.stream;
  Stream<ChatConnection> get states => _states.stream;
  ChatConnection state = ChatConnection.disconnected;
  String? _user, _token, _rejected;
  ChatSocket? _socket;
  void Function()? _unsubscribe;
  Timer? _retry, _renew, _timeout;
  bool _active = true, _disposed = false;
  int _generation = 0, _attempt = 0;
  bool get _wanted => !_disposed && _active && _user != null;

  void session(String? user) {
    if (_user == user || _disposed) return;
    _stop();
    _watchers.clear();
    _user = user;
    _attempt = 0;
    _rejected = null;
    if (_wanted) unawaited(_connect());
  }

  void foreground(bool active) {
    if (_active == active || _disposed) return;
    _active = active;
    _stop();
    if (_wanted) unawaited(_connect());
  }

  void _state(ChatConnection value) {
    if (_disposed) return;
    state = value;
    _states.add(value);
  }

  void _stop() {
    _generation++;
    _retry?.cancel();
    _renew?.cancel();
    _timeout?.cancel();
    _retry = null;
    _renew = null;
    _timeout = null;
    _watchTimer?.cancel();
    try {
      _cancelActivity?.call();
    } catch (_) {}
    _cancelActivity = null;
    _activityReady = false;
    final unsubscribe = _unsubscribe;
    _unsubscribe = null;
    final socket = _socket;
    _socket = null;
    try {
      unsubscribe?.call();
    } catch (_) {}
    try {
      socket?.close();
    } catch (_) {}
    _state(ChatConnection.disconnected);
  }

  Future<void> _connect() async {
    if (!_wanted) return;
    final generation = ++_generation;
    _state(ChatConnection.reconnecting);
    try {
      final token = await tokenProvider(rejectedToken: _rejected);
      if (!_wanted || generation != _generation) return;
      _token = token;
      _rejected = null;
      late final ChatSocket socket;
      socket = factory(
        url,
        token,
        SocketCallbacks(
          connected: () {
            if (!_wanted || generation != _generation || _unsubscribe != null) {
              return;
            }
            if (socket is ActivitySocket) {
              _cancelActivity = (socket as ActivitySocket).subscribeActivity(
                (body) {
                  if (!_wanted || generation != _generation) return;
                  final event = ActivityEvent.parse(body);
                  if (event != null) _activity.add(event);
                },
                () {
                  if (!_wanted || generation != _generation) return;
                  _activityReady = true;
                  _sendWatches();
                },
              );
            }
            _unsubscribe = socket.subscribe(
              (body) {
                if (!_wanted || generation != _generation) return;
                final event = ChatEvent.parse(body);
                if (event != null) _events.add(event);
              },
              () {
                if (!_wanted || generation != _generation) return;
                _timeout?.cancel();
                _attempt = 0;
                _state(ChatConnection.connected);
                _sendWatches();
                final expiry = accessTokenExpiry(token);
                final delay = expiry == null
                    ? const Duration(minutes: 10)
                    : expiry.difference(DateTime.now().toUtc()) -
                          const Duration(seconds: 30);
                _renew = Timer(delay.isNegative ? Duration.zero : delay, () {
                  if (generation != _generation) return;
                  _stop();
                  if (_wanted) unawaited(_connect());
                });
              },
            );
          },
          closed: () => _failed(generation),
          rejected: () {
            if (generation == _generation) _rejected = _token;
            _failed(generation);
          },
        ),
      );
      _socket = socket;
      _timeout = Timer(const Duration(seconds: 15), () => _failed(generation));
      socket.start();
    } catch (_) {
      _failed(generation);
    }
  }

  void _failed(int generation) {
    if (generation != _generation || !_wanted) return;
    _stop();
    if (!_wanted) return;
    _state(ChatConnection.reconnecting);
    final ceiling = min(
      retryMax.inMilliseconds,
      retryBase.inMilliseconds * pow(2, min(_attempt++, 10)),
    ).toInt();
    final delay = Duration(
      milliseconds: (ceiling * (0.5 + _jitter() * 0.5)).round(),
    );
    _retry = Timer(delay, () {
      _retry = null;
      if (_wanted) unawaited(_connect());
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _stop();
    _disposed = true;
    _user = null;
    await _tokens?.cancel();
    await _events.close();
    await _states.close();
    await _activity.close();
  }
}
