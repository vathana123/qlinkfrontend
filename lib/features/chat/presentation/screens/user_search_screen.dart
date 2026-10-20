import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/widgets/user_avatar.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../../user/presentation/bloc/user_search_cubit.dart';
import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/datasources/chat_api.dart';

class UserSearchScreen extends StatelessWidget {
  const UserSearchScreen({super.key});
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (c) => UserSearchCubit(c.read<ChatRepository>()),
    child: const _SearchView(),
  );
}

class _SearchView extends StatefulWidget {
  const _SearchView();
  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  bool _opening = false;
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _open(PublicUser user) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final conversation = await context.read<ChatRepository>().conversation(
        user,
      );
      if (mounted) await context.push('/conversation', extra: conversation);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(chatError(e))));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: BlurAppBar(
      title: 'Search users',
      actions: [
        IconButton(
          tooltip: 'Scan QR code',
          onPressed: () => context.push('/scan'),
          icon: const Icon(Icons.qr_code_scanner),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            autofocus: true,
            controller: _text,
            maxLength: 254,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (value) {
              setState(() {});
              context.read<UserSearchCubit>().search(value);
            },
            decoration: InputDecoration(
              hintText: 'Search by name, username, email or phone',
              counterText: '',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _text.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _text.clear();
                        setState(() {});
                        context.read<UserSearchCubit>().search('');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        if (_opening) const LinearProgressIndicator(),
        Expanded(
          child: BlocBuilder<UserSearchCubit, UserSearchState>(
            builder: (context, state) => ListView(
              children: [
                if (state.loading)
                  const Center(child: CircularProgressIndicator()),
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(state.error!),
                        TextButton(
                          onPressed: () =>
                              context.read<UserSearchCubit>().retry(),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                if (!state.loading &&
                    state.error == null &&
                    state.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        state.searched ? 'No users found.' : 'Find someone by name, username or their full email or international phone number.',
                      ),
                    ),
                  ),
                for (final user in state.items)
                  ListTile(
                    leading: UserAvatar(
                      name: user.displayName,
                      url: user.avatarUrl,
                    ),
                    title: Text(user.displayName),
                    subtitle: user.username == null
                        ? null
                        : Text('@${user.username}'),
                    onTap: _opening ? null : () => _open(user),
                  ),
                if (state.hasMore)
                  TextButton(
                    onPressed: state.loading
                        ? null
                        : () => context.read<UserSearchCubit>().more(),
                    child: const Text('Load more'),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
