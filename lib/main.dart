import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'features/chat/data/realtime/chat_realtime.dart';
import 'app/theme/theme_cubit.dart';
import 'core/network/dio_client.dart';
import 'core/storage/token_storage.dart';
import 'features/auth/data/datasources/oauth_provider.dart';
import 'features/auth/data/repositories/auth_repository.dart';
import 'features/auth/presentation/bloc/auth_bloc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final preferences = await SharedPreferences.getInstance();
  final storage = TokenStorage();
  final client = DioClient(storage);
  final auth = AuthBloc(
    AuthRepository(client.dio, storage, NativeOAuthProvider()),
  );
  client.auth.onSessionExpired = () => auth.add(const AuthSessionExpired());
  runApp(
    QLinkApp(
      auth: auth,
      theme: ThemeCubit(preferences),
      realtime: ChatRealtime(
        url: AppConfig.socketUrl(),
        tokenProvider: client.auth.socketAccessToken,
        tokenChanges: client.auth.tokenChanges,
      ),
    ),
  );
  auth.add(const AuthStarted());
}
