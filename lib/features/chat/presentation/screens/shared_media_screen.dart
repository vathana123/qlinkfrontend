import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/repositories/chat_repository.dart';
import '../bloc/shared_media_cubit.dart';
import '../widgets/attachment_bubble.dart';
import '../widgets/voice_bubble.dart';

class SharedMediaScreen extends StatelessWidget {
  const SharedMediaScreen({super.key, required this.roomId});
  final String roomId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    key: ValueKey('${context.watch<AuthBloc>().state.user?.id}:$roomId'),
    create: (c) => SharedMediaCubit(
      c.read<ChatRepository>(),
      roomId,
      c.read<AuthBloc>().state.user!.id,
    )..load(),
    child: const _SharedMediaView(),
  );
}

class _SharedMediaView extends StatelessWidget {
  const _SharedMediaView();
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: const BlurAppBar(title: 'Shared Media'),
      body: Column(
        children: [
          TabBar(
            tabs: const [
              Tab(text: 'Photos'),
              Tab(text: 'Voice'),
              Tab(text: 'Files'),
            ],
            onTap: (index) => context.read<SharedMediaCubit>().select(
              ['PHOTOS', 'VOICE', 'FILES'][index],
            ),
          ),
          Expanded(
            child: BlocBuilder<SharedMediaCubit, SharedMediaState>(
              builder: (context, state) {
                final cubit = context.read<SharedMediaCubit>();
                if (state.unavailable) {
                  return const Center(
                    child: Text('This conversation is unavailable.'),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () => cubit.load(refresh: true),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notice) {
                      if (notice.metrics.extentAfter < 400 &&
                          state.error == null) {
                        cubit.load();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      key: PageStorageKey(state.category),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(16),
                      itemCount: state.items.length + 1,
                      itemBuilder: (context, index) {
                        if (index == state.items.length) {
                          if (state.error != null) {
                            return Column(
                              children: [
                                Text(state.error!),
                                TextButton(
                                  onPressed: () => cubit.load(),
                                  child: const Text('Retry'),
                                ),
                              ],
                            );
                          }
                          if (state.items.isEmpty) {
                            return Padding(
                              padding: const EdgeInsets.all(40),
                              child: Center(
                                child: state.loading
                                    ? const CircularProgressIndicator()
                                    : const Text('No shared media yet.'),
                              ),
                            );
                          }
                          return state.hasMore
                              ? TextButton(
                                  onPressed: state.loading
                                      ? null
                                      : () => cubit.load(),
                                  child: const Text('Load more'),
                                )
                              : const SizedBox(height: 24);
                        }
                        final message = state.items[index];
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: Card(
                              key: ValueKey(message.id),
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerLow,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${message.senderDisplayName ?? ''} · ${message.createdAt.toLocal().toString().substring(0, 16)}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium,
                                    ),
                                    const SizedBox(height: 8),
                                    message.isVoice
                                        ? VoiceBubble(
                                            message: message,
                                            roomId: cubit.room,
                                          )
                                        : AttachmentBubble(
                                            message: message,
                                            roomId: cubit.room,
                                          ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
