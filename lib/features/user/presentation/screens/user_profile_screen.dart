import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/theme/theme_cubit.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../bloc/profile_cubit.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';

class UserProfileScreen extends StatelessWidget {
  const UserProfileScreen({super.key});
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) => ProfileCubit(context.read<AuthBloc>())..refresh(),
    child: const _ProfileView(),
  );
}

class _ProfileView extends StatelessWidget {
  const _ProfileView();
  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: const BlurAppBar(title: 'Profile'),
    body: BlocBuilder<AuthBloc, AuthState>(
      builder: (context, state) {
        final user = state.user;
        if (user == null) return const SizedBox.shrink();
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.paddingOf(context).top + kToolbarHeight + 20,
                24,
                MediaQuery.paddingOf(context).bottom + 24,
              ),
              children: [
                BlocBuilder<ProfileCubit, ProfileState>(
                  builder: (context, profile) => Column(
                    children: [
                      if (profile.busy) const LinearProgressIndicator(),
                      if (profile.error != null)
                        Text(
                          profile.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      TextButton.icon(
                        onPressed: profile.busy
                            ? null
                            : () => context.read<ProfileCubit>().refresh(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh profile'),
                      ),
                    ],
                  ),
                ),
                Center(
                  child: InkWell(
                    onTap: () => context.push('/profile/edit'),
                    borderRadius: BorderRadius.circular(56),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: UserAvatar(
                        name: user.displayName,
                        url: user.avatarUrl,
                        radius: 42,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  user.displayName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (user.username != null)
                  Text('@${user.username}', textAlign: TextAlign.center),
                if (user.email != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      user.email!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      ListTile(
                        trailing: const Icon(Icons.chevron_right_rounded),
                        leading: const Icon(Icons.alternate_email),
                        title: const Text('Edit profile'),
                        subtitle: Text(
                          user.username == null
                              ? 'Set your username'
                              : '@${user.username}',
                        ),
                        onTap: () => context.push('/profile/edit'),
                      ),
                      ListTile(
                        trailing: const Icon(Icons.chevron_right_rounded),
                        leading: const Icon(Icons.qr_code),
                        title: const Text('My QR code'),
                        onTap: () => context.push('/my-qr'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'Make it yours',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text('Choose how qLink looks on this device.'),
                const SizedBox(height: 18),
                BlocBuilder<ThemeCubit, ThemeMode>(
                  builder: (context, mode) => Column(
                    children: [
                      for (final option in ThemeMode.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            decoration: BoxDecoration(
                              color: mode == option
                                  ? Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                  : Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerLow,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: mode == option
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: .6),
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                leading: Icon(switch (option) {
                                  ThemeMode.light => Icons.light_mode_outlined,
                                  ThemeMode.dark => Icons.dark_mode_outlined,
                                  ThemeMode.system =>
                                    Icons.brightness_auto_outlined,
                                }),
                                title: Text(switch (option) {
                                  ThemeMode.light => 'Light',
                                  ThemeMode.dark => 'Dark',
                                  ThemeMode.system => 'System',
                                }),
                                subtitle: option == ThemeMode.system
                                    ? const Text(
                                        'Follow your device appearance',
                                      )
                                    : null,
                                trailing: mode == option
                                    ? const Icon(Icons.check_circle_rounded)
                                    : null,
                                onTap: () async {
                                  try {
                                    await context.read<ThemeCubit>().setTheme(
                                      option,
                                    );
                                  } catch (_) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Theme changed, but could not be saved on this device.',
                                              ),
                                            ),
                                          );
                                    }
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                if (state is AuthFailure)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      state.message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: state is AuthLoading
                      ? null
                      : () => context.read<AuthBloc>().add(
                          const AuthSignOutRequested(),
                        ),
                  icon: state is AuthLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout_rounded),
                  label: const Text('Sign out'),
                ),
                const SizedBox(height: 16),
                Text(
                  'qLink',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
