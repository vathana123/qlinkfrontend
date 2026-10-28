import '../../features/chat/presentation/screens/share_screen.dart';

import 'dart:async';

import '../../features/chat/presentation/screens/group_info_screen.dart';

import '../../features/chat/presentation/screens/create_group_screen.dart';
import '../../features/chat/presentation/screens/select_group_members_screen.dart';
import '../../features/chat/presentation/bloc/group_creation_cubit.dart';

import '../../features/chat/data/models/chat_models.dart';
import '../../features/chat/presentation/screens/chat_screen.dart';
import '../../features/chat/presentation/screens/chat_search_screen.dart';
import '../../features/chat/presentation/screens/user_search_screen.dart';
import '../../features/chat/presentation/screens/qr_scanner_screen.dart';
import '../../features/user/presentation/screens/my_qr_screen.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/screens/sign_in_screen.dart';
import '../../features/auth/presentation/screens/sign_up_screen.dart';
import '../../features/home/presentation/screens/home_screen.dart';
import '../../features/user/presentation/screens/user_profile_screen.dart';
import '../../features/user/presentation/screens/edit_profile_screen.dart';

String? authRedirect(AuthState auth, String location) {
  final authPage = location == '/signin' || location == '/signup';
  final starting = auth is AuthInitial || auth is AuthLoading && auth.startup;
  if (starting) return location == '/startup' ? null : '/startup';
  if (auth.user != null) {
    return authPage || location == '/startup' ? '/chats' : null;
  }
  return authPage ? null : '/signin';
}

class RouterRefresh extends ChangeNotifier {
  RouterRefresh(AuthBloc bloc) {
    _subscription = bloc.stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription<AuthState> _subscription;
  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

GoRouter createRouter(AuthBloc auth, RouterRefresh refresh) => GoRouter(
  initialLocation: '/startup',
  refreshListenable: refresh,
  redirect: (_, state) => authRedirect(auth.state, state.uri.path),
  routes: [
    GoRoute(path: '/', redirect: (_, _) => '/chats'),
    GoRoute(
      path: '/startup',
      builder: (_, _) =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
    GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
    GoRoute(path: '/signup', builder: (_, _) => const SignUpScreen()),
    GoRoute(
      path: '/create-group',
      builder: (_, _) => const CreateGroupScreen(),
    ),
    GoRoute(
      path: '/create-group/members',
      redirect: (_, s) =>
          s.extra is GroupCreationCubit ? null : '/create-group',
      builder: (_, s) =>
          SelectGroupMembersScreen(cubit: s.extra! as GroupCreationCubit),
    ),
    GoRoute(
      path: '/groups/:id',
      builder: (_, s) => GroupInfoScreen(roomId: s.pathParameters['id']!),
    ),
    GoRoute(path: '/search', builder: (_, _) => const UserSearchScreen()),
    GoRoute(
      path: '/share',
      redirect: (_, s) => s.extra is ShareRequest ? null : '/chats',
      builder: (_, s) {
        final request = s.extra! as ShareRequest;
        return ShareScreen(draft: request.draft, onRelease: request.onRelease);
      },
    ),
    GoRoute(path: '/chat-search', builder: (_, _) => const ChatSearchScreen()),
    GoRoute(path: '/scan', builder: (_, _) => const QrScannerScreen()),
    GoRoute(path: '/my-qr', builder: (_, _) => const MyQrScreen()),
    GoRoute(
      path: '/conversation',
      redirect: (_, s) => s.extra is Conversation ? null : '/chats',
      builder: (_, s) => ChatScreen(
        conversation: s.extra! as Conversation,
        initialMessageId: s.uri.queryParameters['message'],
      ),
    ),
    GoRoute(path: '/chats', builder: (_, _) => const HomeScreen()),
    GoRoute(path: '/profile', builder: (_, _) => const UserProfileScreen()),
    GoRoute(
      path: '/profile/edit',
      builder: (_, _) => const EditProfileScreen(),
    ),
  ],
);
