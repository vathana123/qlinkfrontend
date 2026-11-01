import 'dart:convert';

import 'package:stomp_dart_client/stomp_dart_client.dart';

class SocketCallbacks {
  const SocketCallbacks({
    required this.connected,
    required this.closed,
    required this.rejected,
  });
  final void Function() connected, closed, rejected;
}

abstract interface class ChatSocket {
  void start();
  void close();
  void Function() subscribe(
    void Function(String body) receive,
    void Function() ready,
  );
}

typedef SocketFactory = ChatSocket Function(
  String url,
  String token,
  SocketCallbacks callbacks,
);

abstract interface class ActivitySocket {
  void Function() subscribeActivity(
    void Function(String body) receive,
    void Function() ready,
  );
  void sendActivity(String action, Map<String, dynamic> payload);
}

class NativeStompSocket implements ChatSocket, ActivitySocket {
  NativeStompSocket(String url, String token, SocketCallbacks callbacks) {
    _client = StompClient(
      config: StompConfig(
        url: url,
        stompConnectHeaders: {'Authorization': 'Bearer $token'},
        reconnectDelay: Duration.zero,
        connectionTimeout: const Duration(seconds: 10),
        heartbeatIncoming: const Duration(seconds: 10),
        heartbeatOutgoing: const Duration(seconds: 10),
        onConnect: (_) => callbacks.connected(),
        onDisconnect: (_) => callbacks.closed(),
        onWebSocketDone: callbacks.closed,
        onWebSocketError: (_) => callbacks.closed(),
        onUnhandledReceipt: (frame) {
          if (frame.headers['receipt-id'] == 'activity-ready') {
            final ready = _activityReady;
            _activityReady = null;
            ready?.call();
          }
          if (frame.headers['receipt-id'] == 'chat-ready') {
            final ready = _ready;
            _ready = null;
            ready?.call();
          }
        },
        onStompError: (_) => callbacks.rejected(),
      ),
    );
  }
  late final StompClient _client;
  void Function()? _activityReady;
  @override
  void sendActivity(String action, Map<String, dynamic> payload) =>
      _client.send(
        destination: '/app/activity/$action',
        body: jsonEncode(payload),
        headers: {'content-type': 'application/json'},
      );
  @override
  void Function() subscribeActivity(
    void Function(String body) receive,
    void Function() ready,
  ) {
    _activityReady = ready;
    final cancel = _client.subscribe(
      destination: '/user/queue/activity',
      headers: {'ack': 'auto', 'receipt': 'activity-ready'},
      callback: (frame) {
        final body =
            frame.body ??
            (frame.binaryBody == null ? null : utf8.decode(frame.binaryBody!));
        if (body != null) receive(body);
      },
    );
    return () => cancel();
  }

  void Function()? _ready;
  @override
  void start() => _client.activate();
  @override
  void close() => _client.deactivate();
  @override
  void Function() subscribe(
    void Function(String body) receive,
    void Function() ready,
  ) {
    _ready = ready;
    final unsubscribe = _client.subscribe(
      destination: '/user/queue/chat-events',
      headers: {'ack': 'auto', 'receipt': 'chat-ready'},
      callback: (frame) {
        try {
          final body =
              frame.body ??
              (frame.binaryBody == null
                  ? null
                  : utf8.decode(frame.binaryBody!));
          if (body != null) receive(body);
        } catch (_) {}
      },
    );
    return () => unsubscribe();
  }
}
