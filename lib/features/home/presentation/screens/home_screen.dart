import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../chat/data/models/chat_models.dart';
import '../../../chat/data/repositories/chat_repository.dart';
import '../../../chat/presentation/bloc/rooms_cubit.dart';
import '../widgets/blur_app_bar.dart';
import '../../../../core/widgets/user_avatar.dart';
import '../widgets/chat_list_tile.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => BlocProvider(
    key: ValueKey(context.watch<AuthBloc>().state.user?.id),
    create: (c) => RoomsCubit(c.read<ChatRepository>())..load(),
    child: const _RoomsView(),
  );
}

class _RoomsView extends StatefulWidget {
  const _RoomsView();
  @override
  State<_RoomsView> createState() => _RoomsViewState();
}

class _RoomsViewState extends State<_RoomsView> {
  Future<void> _navigate(String path, {Object? extra}) async {
    await context.push(path, extra: extra);
    if (mounted) await context.read<RoomsCubit>().load(refresh: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: BlurAppBar(
      titleWidget: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, state) {
          final user = state.user;
          final colors = Theme.of(context).colorScheme;
          final username = user?.username;
          final email = user?.email;
          return Tooltip(
            message: 'Your profile',
            child: InkWell(
              onTap: () => context.push('/profile'),
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    UserAvatar(
                      name: user?.displayName ?? '',
                      url: user?.avatarUrl,
                      radius: 19,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user?.displayName ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: colors.onSurface,
                                  fontWeight: FontWeight.w700,
                                  height: 1.1,
                                ),
                          ),
                          if (username != null && username.isNotEmpty)
                            Text(
                              '@$username',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    height: 1.1,
                                  ),
                            )
                          else
                            Text(
                              '$email',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                    height: 1.1,
                                  ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      actions: [
        IconButton(
          tooltip: 'Search users',
          onPressed: () => _navigate('/search'),
          icon: const Icon(Icons.search_rounded),
        ),
        IconButton(
          tooltip: 'Scan QR code',
          onPressed: () => _navigate('/scan'),
          icon: const Icon(Icons.qr_code_scanner),
        ),
        PopupMenuButton<String>(
          tooltip: 'More options',
          onSelected: (value) => value == 'group'
              ? _navigate('/create-group')
              : context.push('/profile'),
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'group',
              child: Text('Create New Group'),
            ),
            const PopupMenuItem(value: 'profile', child: Text('Profile')),
          ],
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: BlocBuilder<RoomsCubit, RoomsState>(
      builder: (context, state) {
        final rooms = state.items;
        return RefreshIndicator(
          onRefresh: () => context.read<RoomsCubit>().load(refresh: true),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + kToolbarHeight + 16,
              bottom: MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Text(
                  'Messages',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 12),
              if (state.loading) const LinearProgressIndicator(),
              if (state.error != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text(state.error!),
                      TextButton(
                        onPressed: () =>
                            context.read<RoomsCubit>().load(refresh: true),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              if (!state.loading && rooms.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text('No conversations yet. Start a new message.'),
                  ),
                ),
              for (final room in rooms) ...[
                ChatListTile(
                  chat: ChatPreview(
                    room.title,
                    room.lastMessage?.isVoice == true
                        ? 'Voice message'
                        : room.lastMessage?.isAttachment == true
                        ? room.lastMessage?.attachment?.originalName ??
                              'Attachment'
                        : room.lastMessage?.content ?? '',
                    room.lastMessageAt == null
                        ? ''
                        : messageTime(room.lastMessageAt!),
                    avatarUrl: room.avatarUrl,
                    isGroup: room.isGroup,
                  ),
                  onTap: () => _navigate(
                    '/conversation',
                    extra: Conversation.fromRoom(room),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 88),
                  child: Divider(height: 1),
                ),
              ],
              if (state.hasMore && !state.loading && state.error == null)
                TextButton(
                  onPressed: () => context.read<RoomsCubit>().load(),
                  child: const Text('Load more conversations'),
                ),
            ],
          ),
        );
      },
    ),
  );
}
