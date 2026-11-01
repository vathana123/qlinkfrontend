import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/widgets/user_avatar.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../chat/data/models/chat_models.dart';
import '../../../chat/data/repositories/chat_repository.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../bloc/privacy_cubit.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Settings'),
    body: ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: const Text('Storage & Data'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/profile/settings/storage'),
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('Privacy'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/profile/settings/privacy'),
        ),
      ],
    ),
  );
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key, this.blockedUsers = false, this.user});
  final bool blockedUsers;
  final PublicUser? user;
  @override
  Widget build(BuildContext context) {
    final account = context.select((AuthBloc bloc) => bloc.state.user?.id);
    if (account == null) return const SizedBox.shrink();
    return BlocProvider(
      key: ValueKey((account, blockedUsers, user?.id)),
      create: (context) {
        final cubit = PrivacyCubit(
          context.read<ChatRepository>(),
          account,
          peer: user,
        );
        if (blockedUsers) {
          cubit.loadBlocked();
        } else {
          cubit.load();
        }
        return cubit;
      },
      child: _PrivacyView(blockedUsers: blockedUsers, user: user),
    );
  }
}

class _PrivacyView extends StatelessWidget {
  const _PrivacyView({required this.blockedUsers, this.user});
  final bool blockedUsers;
  final PublicUser? user;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: BlurAppBar(
      title: user != null
          ? 'Profile'
          : blockedUsers
          ? 'Blocked users'
          : 'Privacy',
    ),
    body: BlocBuilder<PrivacyCubit, PrivacyState>(
      builder: (context, state) {
        final cubit = context.read<PrivacyCubit>();
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (state.loading || state.busy) const LinearProgressIndicator(),
            if (state.error != null) ...[
              Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              TextButton(
                onPressed: state.busy || state.loading
                    ? null
                    : () {
                        if (blockedUsers) {
                          cubit.loadBlocked(reset: true);
                        } else {
                          cubit.load();
                        }
                      },
                child: const Text('Retry'),
              ),
            ],
            if (user != null) ...[
              Center(
                child: UserAvatar(
                  name: user!.displayName,
                  url: user!.avatarUrl,
                  radius: 40,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                user!.displayName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (user!.username != null)
                Text('@${user!.username}', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (state.loaded)
                ListTile(
                  leading: Icon(
                    state.blockedByMe ? Icons.person_add_outlined : Icons.block,
                  ),
                  title: Text(
                    state.blockedByMe ? 'Unblock user' : 'Block user',
                  ),
                  subtitle: const Text(
                    'Blocking stops personal messages in both directions. Shared groups and message history stay available.',
                  ),
                  onTap: state.busy
                      ? null
                      : () => cubit.block(user!, !state.blockedByMe),
                ),
            ] else if (blockedUsers) ...[
              if (state.loaded && state.blocked.isEmpty)
                const Center(child: Text('No blocked users.')),
              for (final user in state.blocked)
                ListTile(
                  leading: UserAvatar(
                    name: user.displayName,
                    url: user.avatarUrl,
                  ),
                  title: Text(user.displayName),
                  trailing: TextButton(
                    onPressed: state.busy
                        ? null
                        : () => cubit.block(user, false),
                    child: const Text('Unblock'),
                  ),
                ),
              if (state.hasMore)
                TextButton(
                  onPressed: state.loading || state.busy
                      ? null
                      : () => cubit.loadBlocked(),
                  child: const Text('Load more'),
                ),
            ] else ...[
              const Text(
                'Choose who can see your activity. Contacts are people you have a personal conversation with.',
              ),
              const SizedBox(height: 16),
              for (final online in [true, false])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(online ? 'Online' : 'Last seen'),
                  trailing: DropdownButton<String>(
                    value: online ? state.online : state.lastSeen,
                    items: const [
                      DropdownMenuItem(
                        value: 'EVERYONE',
                        child: Text('Everyone'),
                      ),
                      DropdownMenuItem(
                        value: 'CONTACTS',
                        child: Text('Contacts'),
                      ),
                      DropdownMenuItem(value: 'NOBODY', child: Text('Nobody')),
                    ],
                    onChanged: !state.loaded || state.loading || state.busy
                        ? null
                        : (value) {
                            if (value != null) {
                              cubit.save(
                                online ? value : state.online,
                                online ? state.lastSeen : value,
                              );
                            }
                          },
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block),
                title: const Text('Blocked users'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/profile/settings/blocked'),
              ),
            ],
          ],
        );
      },
    ),
  );
}
