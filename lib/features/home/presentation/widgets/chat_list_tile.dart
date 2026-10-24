import 'package:flutter/material.dart';

import '../../../../core/widgets/user_avatar.dart';

class ChatPreview {
  const ChatPreview(
    this.name,
    this.message,
    this.time, {
    this.unread = 0,
    this.avatarUrl,
    this.online = false,
    this.isGroup = false,
  });
  final String name, message, time;
  final String? avatarUrl;
  final int unread;
  final bool online, isGroup;
}

class ChatListTile extends StatelessWidget {
  const ChatListTile({super.key, required this.chat, required this.onTap});
  final ChatPreview chat;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: chat.unread > 0
            ? colors.primaryContainer.withValues(alpha: .35)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          minVerticalPadding: 12,
          horizontalTitleGap: 14,
          onTap: onTap,
          leading: Stack(
            children: [
              if (chat.isGroup && chat.avatarUrl == null)
                CircleAvatar(
                  radius: 26,
                  backgroundColor: colors.secondaryContainer,
                  foregroundColor: colors.onSecondaryContainer,
                  child: const Icon(Icons.group_outlined),
                )
              else
                UserAvatar(name: chat.name, url: chat.avatarUrl),
              if (chat.online)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Semantics(
                    label: 'Online',
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.tertiary,
                        border: Border.all(color: colors.surface, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            chat.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: chat.unread > 0 ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              chat.message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          trailing: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                chat.time,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: chat.unread > 0
                      ? colors.primary
                      : colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              if (chat.unread > 0)
                Badge(
                  backgroundColor: colors.primary,
                  textColor: colors.onPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  label: Text('${chat.unread}'),
                )
              else
                const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
