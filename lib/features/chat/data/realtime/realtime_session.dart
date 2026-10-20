import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import 'chat_realtime.dart';

// App-wide lifecycle adapter; conversation widgets never create or control sockets.
class RealtimeSession with WidgetsBindingObserver {
  RealtimeSession(this.auth, this.realtime) {
    WidgetsBinding.instance.addObserver(this);
    realtime.foreground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _apply(auth.state);
    _subscription = auth.stream.listen(_apply);
  }
  final AuthBloc auth;
  final ChatRealtime realtime;
  late final StreamSubscription<AuthState> _subscription;
  void _apply(AuthState state) => realtime.session(state.user?.id);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) realtime.foreground(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      realtime.foreground(false);
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription.cancel());
    unawaited(realtime.dispose());
  }
}
