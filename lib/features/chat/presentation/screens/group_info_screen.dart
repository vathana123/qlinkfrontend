import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/widgets/user_avatar.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../user/presentation/bloc/user_search_cubit.dart';
import '../../data/datasources/attachment_picker.dart';
import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../bloc/group_info_cubit.dart';

class GroupInfoScreen extends StatelessWidget {
  const GroupInfoScreen({super.key, required this.roomId});
  final String roomId;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (c) => GroupInfoCubit(c.read<ChatRepository>(), roomId)..load(),
    child: const _GroupInfoView(),
  );
}

class _GroupInfoView extends StatefulWidget {
  const _GroupInfoView();
  @override
  State<_GroupInfoView> createState() => _GroupInfoViewState();
}

class _GroupInfoViewState extends State<_GroupInfoView> {
  bool _uploading = false;
  GroupInfoCubit get cubit => context.read<GroupInfoCubit>();
  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _edit(ChatRoom room) async {
    final name = TextEditingController(text: room.title);
    final description = TextEditingController(text: room.description);
    final form = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Edit group'),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter a group name'
                      : null,
                ),
                TextFormField(
                  controller: description,
                  maxLength: 2000,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == true && mounted) {
      await cubit.act('PATCH', '', {
        'name': name.text.trim(),
        'description': description.text.trim(),
      });
    }
    // Dialog fields finish their exit animation before their controllers are disposed.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    description.dispose();
  }

  Future<void> _avatar() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final manager = cubit;
    final api = manager.repository.api;
    PreparedAttachment? prepared;
    String? uploaded;
    bool linked = false;
    try {
      final picker = AttachmentPicker();
      final selected = await picker.pick(AttachmentSource.image);
      if (selected.isEmpty || !mounted) return;
      final policy = await api.uploadPolicy();
      prepared = await picker.prepare(
        selected.first,
        AttachmentSource.photo,
        (policy['maxSizeBytes'] as num).toInt(),
        Map<String, dynamic>.from(policy['extensions'] as Map),
      );
      if (!prepared.metadata.contentType.startsWith('image/')) {
        throw StateError('Choose an image.');
      }
      uploaded = await api.uploadAttachment(
        prepared.path,
        prepared.metadata.originalName,
        prepared.metadata.contentType,
        (_, _) {},
      );
      if (!mounted) return;
      linked = await manager.act('PUT', '/avatar', {'fileId': uploaded});
    } catch (e) {
      manager.report(e);
    } finally {
      if (uploaded != null && !linked) {
        // If a response was lost, attached-file authorization prevents deleting a bound avatar.
        try {
          await api.dio.delete<dynamic>('/api/v1/storage/files/$uploaded');
        } catch (_) {}
      }
      if (prepared != null) {
        try {
          await File(prepared.path).delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _add() async {
    final repository = cubit.repository;
    final existing = cubit.state.members.map((m) => m['id']).toSet();
    final user = await showDialog<PublicUser>(
      context: context,
      builder: (_) => BlocProvider(
        create: (_) => UserSearchCubit(repository),
        child: _MemberSearch(existing: existing),
      ),
    );
    if (user != null && mounted) {
      await cubit.act('POST', '/members', {
        'memberIds': [user.id],
      });
    }
  }

  Future<void> _memberAction(String action, Map<String, dynamic> member) async {
    final id = member['id'] as String;
    if (action == 'remove') {
      if (await _confirm(
            'Remove member?',
            'Remove ${member['displayName']} from this group?',
          ) &&
          mounted) {
        await cubit.act('DELETE', '/members/$id');
      }
    } else if (action == 'transfer') {
      if (await _confirm(
            'Transfer ownership?',
            '${member['displayName']} will become Owner. You will become a Co-Owner.',
          ) &&
          mounted) {
        await cubit.act('POST', '/ownership', {'userId': id});
      }
    } else {
      await cubit.act('PATCH', '/members/$id/role', {'role': action});
    }
  }

  Future<void> _exit(bool delete) async {
    if (!await _confirm(
      delete ? 'Delete group?' : 'Leave group?',
      delete ? 'All members will lose access to this group and its messages.' : 'You will lose access to this group. A member with invite permission must add you again.',
    )) {
      return;
    }
    if (!mounted) return;
    if (await cubit.act(delete ? 'DELETE' : 'POST', delete ? '' : '/leave') &&
        mounted) {
      context.go('/chats');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Group info')),
    body: BlocBuilder<GroupInfoCubit, GroupInfoState>(
      builder: (context, state) {
        final room = state.room;
        final colors = Theme.of(context).colorScheme;
        if (state.removed) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('This group is no longer available to you.'),
                TextButton(
                  onPressed: () => context.go('/chats'),
                  child: const Text('Back to chats'),
                ),
              ],
            ),
          );
        }
        if (room == null) {
          return Center(
            child: state.error == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(state.error!),
                      TextButton(
                        onPressed: cubit.load,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
          );
        }
        final busy = state.busy || _uploading;
        final me = context.read<AuthBloc>().state.user?.id;
        return RefreshIndicator(
          onRefresh: cubit.load,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: UserAvatar(
                  name: room.title,
                  url: room.avatarUrl,
                  radius: 44,
                ),
              ),
              Text(
                room.title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                '${room.type == 'GROUP_PUBLIC' ? 'Public' : 'Private'} group · ${room.memberCount} members',
                textAlign: TextAlign.center,
              ),
              if (room.description?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(room.description!),
                ),
              Text(
                room.messageHistoryVisibility == 'VIEW_AFTER_JOIN'
                    ? 'Members see messages sent after their latest join.'
                    : 'Members can see all group history.',
              ),
              if (busy) const LinearProgressIndicator(),
              if (state.error != null)
                Text(state.error!, style: TextStyle(color: colors.error)),
              if (room.canManage)
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: busy ? null : () => _edit(room),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit group'),
                    ),
                    TextButton.icon(
                      onPressed: busy ? null : _avatar,
                      icon: const Icon(Icons.photo_outlined),
                      label: const Text('Change avatar'),
                    ),
                    if (room.avatarUrl != null)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => cubit.act('DELETE', '/avatar'),
                        child: const Text('Remove avatar'),
                      ),
                  ],
                ),
              if (room.isOwner) ...[
                const Divider(),
                Text(
                  'Member permissions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SwitchListTile(
                  title: const Text('Send messages'),
                  value: room.membersCanSend,
                  onChanged: busy
                      ? null
                      : (value) => cubit.act('PATCH', '/permissions', {
                          'membersCanSend': value,
                          'membersCanInvite': room.membersCanInvite,
                        }),
                ),
                SwitchListTile(
                  title: const Text('Invite members'),
                  value: room.membersCanInvite,
                  onChanged: busy
                      ? null
                      : (value) => cubit.act('PATCH', '/permissions', {
                          'membersCanSend': room.membersCanSend,
                          'membersCanInvite': value,
                        }),
                ),
              ],
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Members',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (room.canInvite)
                    TextButton.icon(
                      onPressed: busy ? null : _add,
                      icon: const Icon(Icons.person_add_outlined),
                      label: const Text('Add member'),
                    ),
                ],
              ),
              for (final member in state.members)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: UserAvatar(
                    name: member['displayName'] as String? ?? 'Member',
                    url: member['avatarUrl'] as String?,
                    radius: 20,
                  ),
                  title: Text(
                    '${member['displayName']}${member['id'] == me ? ' (you)' : ''}',
                  ),
                  subtitle: Text(_role(member['role'] as String)),
                  trailing:
                      !busy &&
                          member['id'] != me &&
                          member['role'] != 'OWNER' &&
                          (room.isOwner ||
                              (room.canManage && member['role'] == 'MEMBER'))
                      ? PopupMenuButton<String>(
                          onSelected: (action) => _memberAction(action, member),
                          itemBuilder: (_) => [
                            if (room.isOwner) ...[
                              PopupMenuItem(
                                value: member['role'] == 'MEMBER'
                                    ? 'CO_OWNER'
                                    : 'MEMBER',
                                child: Text(
                                  member['role'] == 'MEMBER'
                                      ? 'Make Co-Owner'
                                      : 'Make Member',
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'transfer',
                                child: Text('Transfer ownership'),
                              ),
                            ],
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove member'),
                            ),
                          ],
                        )
                      : null,
                ),
              const Divider(),
              if (room.isOwner)
                const Text(
                  'Transfer ownership to another member before leaving.',
                ),
              if (!room.isOwner)
                TextButton(
                  onPressed: busy ? null : () => _exit(false),
                  child: Text(
                    'Leave group',
                    style: TextStyle(color: colors.error),
                  ),
                ),
              if (room.isOwner)
                TextButton(
                  onPressed: busy ? null : () => _exit(true),
                  child: Text(
                    'Delete group',
                    style: TextStyle(color: colors.error),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

String _role(String role) => switch (role) {
  'OWNER' => 'Owner',
  'CO_OWNER' => 'Co-Owner',
  _ => 'Member',
};

class _MemberSearch extends StatelessWidget {
  const _MemberSearch({required this.existing});
  final Set<dynamic> existing;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add member'),
    content: SizedBox(
      width: 420,
      height: 380,
      child: Column(
        children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Search name or username',
            ),
            onChanged: context.read<UserSearchCubit>().search,
          ),
          Expanded(
            child: BlocBuilder<UserSearchCubit, UserSearchState>(
              builder: (context, state) => ListView(
                children: [
                  if (state.loading) const LinearProgressIndicator(),
                  if (state.error != null) Text(state.error!),
                  for (final user in state.items.where(
                    (u) => !existing.contains(u.id),
                  ))
                    ListTile(
                      title: Text(user.displayName),
                      subtitle: Text(user.username ?? ''),
                      onTap: () => Navigator.pop(context, user),
                    ),
                  if (state.searched &&
                      !state.loading &&
                      state.items.every((u) => existing.contains(u.id)))
                    const Text('No new members found.'),
                  if (state.hasMore)
                    TextButton(
                      onPressed: state.loading
                          ? null
                          : context.read<UserSearchCubit>().more,
                      child: const Text('Load more'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ],
  );
}
