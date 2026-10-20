import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/widgets/user_avatar.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/models/chat_models.dart';
import '../bloc/group_creation_cubit.dart';

class SelectGroupMembersScreen extends StatefulWidget {
  const SelectGroupMembersScreen({super.key, required this.cubit});
  final GroupCreationCubit cubit;
  @override
  State<SelectGroupMembersScreen> createState() =>
      _SelectGroupMembersScreenState();
}

class _SelectGroupMembersScreenState extends State<SelectGroupMembersScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.cubit.state.contacts.isEmpty) widget.cubit.loadContacts();
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
    value: widget.cubit,
    child: BlocConsumer<GroupCreationCubit, GroupCreationState>(
      listenWhen: (previous, current) =>
          previous.created == null && current.created != null,
      listener: (context, state) {
        if (state.created != null) {
          final conversation = Conversation.fromRoom(state.created!);
          // Return through Home so its existing refresh-on-return runs.
          final router = GoRouter.of(context);
          router.pop();
          router.pop();
          router.push('/conversation', extra: conversation);
        }
      },
      builder: (context, state) => PopScope(
        canPop: !state.creating,
        child: Scaffold(
          appBar: const BlurAppBar(title: 'Select Members'),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextFormField(
                    initialValue: state.query,
                    decoration: const InputDecoration(
                      hintText: 'Filter contacts',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: widget.cubit.search,
                  ),
                ),
                if (state.loading || state.creating)
                  const LinearProgressIndicator(),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      state.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      if (!state.loading && state.filtered.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No matching contacts.'),
                        ),
                      for (final user in state.filtered)
                        CheckboxListTile(
                          key: ValueKey(user.id),
                          secondary: UserAvatar(
                            name: user.displayName,
                            url: user.avatarUrl,
                          ),
                          title: Text(user.displayName),
                          subtitle: user.username == null
                              ? null
                              : Text('@${user.username}'),
                          value: state.selected.contains(user.id),
                          onChanged: state.creating
                              ? null
                              : (_) => widget.cubit.toggle(user.id),
                        ),
                      if (state.hasMore && !state.loading)
                        TextButton(
                          onPressed: state.creating
                              ? null
                              : widget.cubit.loadContacts,
                          child: Text(
                            state.error == null
                                ? 'Load more contacts'
                                : 'Retry loading contacts',
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${state.selected.length} selected'),
                      ),
                      FilledButton(
                        onPressed: state.selected.isEmpty || state.creating
                            ? null
                            : widget.cubit.create,
                        child: Text(state.creating ? 'Creating…' : 'Create'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
