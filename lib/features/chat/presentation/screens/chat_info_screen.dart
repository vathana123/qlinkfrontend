import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/widgets/user_avatar.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/models/chat_models.dart';

class ChatInfoScreen extends StatelessWidget {
  const ChatInfoScreen({super.key, required this.conversation});
  final Conversation conversation;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Chat Info'),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: UserAvatar(
            name: conversation.title,
            url: conversation.avatarUrl,
            radius: 44,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          conversation.title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 24),
        if (conversation.recipient != null)
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('View profile'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                context.push('/user-profile', extra: conversation.recipient),
          ),
        if (conversation.roomId != null)
          ListTile(
            leading: const Icon(Icons.perm_media_outlined),
            title: const Text('Shared Media'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/rooms/${conversation.roomId}/media'),
          ),
      ],
    ),
  );
}
