import 'package:flutter/material.dart';

import '../features/chat/data/realtime/chat_realtime.dart';
import '../features/chat/data/realtime/realtime_session.dart';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/presentation/bloc/auth_bloc.dart';
import 'router/app_router.dart';
import '../features/chat/data/repositories/chat_repository.dart';
import '../features/chat/data/datasources/chat_api.dart';
import 'theme/app_theme.dart';
import 'theme/theme_cubit.dart';

class QLinkApp extends StatefulWidget {
  const QLinkApp({
    super.key,
    required this.auth,
    required this.theme,
    this.realtime,
  });
  final AuthBloc auth;
  final ThemeCubit theme;
  final ChatRealtime? realtime;
  @override
  State<QLinkApp> createState() => _QLinkAppState();
}

class _QLinkAppState extends State<QLinkApp> {
  late final RouterRefresh _refresh = RouterRefresh(widget.auth);
  late final GoRouter _router = createRouter(widget.auth, _refresh);
  RealtimeSession? _session;
  @override
  void initState() {
    super.initState();
    if (widget.realtime != null) {
      _session = RealtimeSession(widget.auth, widget.realtime!);
    }
  }

  final _messenger = GlobalKey<ScaffoldMessengerState>();
  @override
  void dispose() {
    _session?.dispose();
    _router.dispose();
    _refresh.dispose();
    widget.auth.close();
    widget.theme.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepositoryProvider(
    create: (_) => ChatRepository(
      ChatApi(widget.auth.repository.dio),
      realtime: widget.realtime,
    ),
    child: MultiBlocProvider(
      providers: [
        BlocProvider.value(value: widget.auth),
        BlocProvider.value(value: widget.theme),
      ],
      child: BlocListener<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthUnauthenticated && state.message != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _messenger.currentState?.showSnackBar(
                SnackBar(
                  content: Text(state.message!),
                  duration: const Duration(seconds: 10),
                ),
              );
            });
          }
        },
        child: BlocBuilder<ThemeCubit, ThemeMode>(
          builder: (context, mode) => MaterialApp.router(
            title: 'qLink',
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: _messenger,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: mode,
            routerConfig: _router,
            builder: (context, child) {
              final dark = Theme.of(context).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value:
                    (dark
                            ? SystemUiOverlayStyle.light
                            : SystemUiOverlayStyle.dark)
                        .copyWith(
                          statusBarColor: Colors.transparent,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: dark
                              ? Brightness.light
                              : Brightness.dark,
                        ),
                child: child!,
              );
            },
          ),
        ),
      ),
    ),
  );
}
