import 'dart:async';

import 'package:go_router/go_router.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/widgets/user_avatar.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../bloc/chat_cubit.dart';
import '../widgets/voice_input.dart';
import '../widgets/attachment_button.dart';
import '../widgets/attachment_bubble.dart';
import '../widgets/voice_bubble.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.conversation});
  final Conversation conversation;
  @override
  Widget build(BuildContext context) {
    final accountId = context.select((AuthBloc bloc) => bloc.state.user?.id);
    if (accountId == null) return const SizedBox.shrink();
    return BlocProvider(
      key: ValueKey((
        accountId,
        conversation.roomId,
        conversation.recipient?.id,
      )),
      create: (context) =>
          ChatCubit(context.read<ChatRepository>(), conversation, accountId)
            ..load(),
      child: _ChatView(conversation: conversation),
    );
  }
}

// The server ID can change when an optimistic message is acknowledged.
Key chatMessageKey(ChatMessage message) => message.clientMessageId.isNotEmpty
    ? ValueKey(('client', message.senderId, message.clientMessageId))
    : ValueKey(('server', message.id));

class _ChatView extends StatefulWidget {
  const _ChatView({required this.conversation});
  final Conversation conversation;
  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _text.text;
    if (text.trim().isEmpty || text.length > 4000) return;
    final cubit = context.read<ChatCubit>();
    _text.clear();
    unawaited(cubit.send(text));
  }

  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversation;
    final colors = Theme.of(context).colorScheme;
    final chat = context.watch<ChatCubit>().state;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: BlurAppBar(
        title: chat.group?.title ?? conversation.title,
        titleWidget: conversation.isGroup
            ? InkWell(
                onTap: chat.removed
                    ? null
                    : () async {
                        await context.push('/groups/${conversation.roomId}');
                        if (context.mounted) {
                          unawaited(context.read<ChatCubit>().synchronize());
                        }
                      },
                child: Row(
                  children: [
                    UserAvatar(
                      name: chat.group?.title ?? conversation.title,
                      url: chat.group?.avatarUrl ?? conversation.avatarUrl,
                      radius: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        chat.group?.title ?? conversation.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.info_outline),
                  ],
                ),
              )
            : null,
        actions: [
          if (!conversation.isGroup)
            UserAvatar(
              name: conversation.title,
              url: conversation.avatarUrl,
              radius: 18,
            ),
          const SizedBox(width: 16),
          IconButton(
            tooltip: 'Refresh messages',
            onPressed: () => context.read<ChatCubit>().synchronize(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: BlocConsumer<ChatCubit, ChatState>(
          listenWhen: (previous, current) =>
              previous.messages.firstOrNull?.id !=
              current.messages.firstOrNull?.id,
          listener: (context, state) {
            if (!_scroll.hasClients || _scroll.offset > 100) return;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _scroll.hasClients && _scroll.offset <= 100) {
                _scroll.animateTo(
                  0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                );
              }
            });
          },
          builder: (context, state) {
            final indices = {
              for (var i = 0; i < state.messages.length; i++)
                chatMessageKey(state.messages[i]): i,
            };
            return Column(
              children: [
                if (conversation.isGroup && conversation.memberCount != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '${state.group?.memberCount ?? conversation.memberCount} members',
                    ),
                  ),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      state.error!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
                if (state.loading) const LinearProgressIndicator(),
                Expanded(
                  child: state.messages.isEmpty
                      ? Center(
                          child: Text(
                            state.roomId == null
                                ? 'Say hello to ${conversation.title}'
                                : 'No messages yet',
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: EdgeInsets.only(
                            top:
                                MediaQuery.paddingOf(context).top +
                                kToolbarHeight +
                                16,
                            bottom: MediaQuery.paddingOf(context).bottom + 24,
                            left: 12,
                            right: 12,
                          ),
                          itemCount: state.messages.length + 1,
                          findChildIndexCallback: (key) => indices[key],
                          itemBuilder: (context, index) {
                            if (index == state.messages.length) {
                              return Center(
                                child: state.cursor != null
                                    ? TextButton(
                                        onPressed: state.loading
                                            ? null
                                            : () => context
                                                  .read<ChatCubit>()
                                                  .load(),
                                        child: const Text(
                                          'Load older messages',
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              );
                            }
                            final message = state.messages[index];
                            final mine =
                                message.senderId ==
                                context.read<AuthBloc>().state.user?.id;
                            return Align(
                              key: chatMessageKey(message),
                              alignment: mine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: message.type == 'IMAGE'
                                    ? const EdgeInsets.all(4)
                                    : const EdgeInsets.fromLTRB(14, 10, 14, 8),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.sizeOf(context).width * .8,
                                ),
                                decoration: BoxDecoration(
                                  color: mine
                                      ? colors.primaryContainer
                                      : colors.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (conversation.isGroup && !mine)
                                      Text(
                                        message.senderDisplayName ??
                                            'qLink member',
                                        style: TextStyle(
                                          color: colors.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    if (message.isVoice)
                                      VoiceBubble(message: message)
                                    else if (message.isAttachment)
                                      AttachmentBubble(message: message)
                                    else
                                      SelectableText(
                                        message.content,
                                        style: TextStyle(
                                          color: mine
                                              ? colors.onPrimaryContainer
                                              : colors.onSurface,
                                        ),
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${messageTime(message.displayTime)}${mine ? ' · ${message.statusText}' : ''}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall,
                                    ),
                                    if (message.delivery == Delivery.failed)
                                      TextButton.icon(
                                        onPressed: () => context
                                            .read<ChatCubit>()
                                            .retry(message),
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('Retry'),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: !state.canSend
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Messaging is unavailable for you in this group.',
                          ),
                        )
                      : VoiceInput(
                          controller: _text,
                          onSend: _send,
                          busy: false,
                          attachmentButton: const AttachmentButton(busy: false),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
