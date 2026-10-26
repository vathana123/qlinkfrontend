import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/chat_models.dart';
import '../../data/models/search_models.dart';
import '../bloc/chat_search_cubit.dart';
import 'search_highlight.dart';

class ChatSearchPanel extends StatefulWidget {
  const ChatSearchPanel({
    super.key,
    required this.onMessage,
    this.onRoom,
    this.onClose,
  });
  final Future<void> Function(MessageMatch) onMessage;
  final Future<void> Function(ChatRoom)? onRoom;
  final VoidCallback? onClose;
  @override
  State<ChatSearchPanel> createState() => _ChatSearchPanelState();
}

class _ChatSearchPanelState extends State<ChatSearchPanel> {
  final _text = TextEditingController();
  String? _selected;
  bool _opening = false;
  Future<void> _select(MessageMatch match) async {
    if (_opening) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _opening = true;
      _selected = match.message.id;
    });
    try {
      await widget.onMessage(match);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => BlocBuilder<ChatSearchCubit, ChatSearchState>(
    builder: (context, state) {
      final cubit = context.read<ChatSearchCubit>();
      final selected = state.messages.indexWhere(
        (m) => m.message.id == _selected,
      );
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _text,
              autofocus: true,
              maxLength: 100,
              onChanged: cubit.change,
              decoration: InputDecoration(
                hintText: widget.onClose == null
                    ? 'Search conversations and messages'
                    : 'Search this conversation',
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _text.clear();
                    cubit.change('');
                  },
                ),
              ),
            ),
          ),
          if (widget.onClose != null)
            Row(
              children: [
                IconButton(
                  tooltip: 'Close search',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    selected < 0
                        ? '${state.messages.length} matches'
                        : '${selected + 1} of ${state.messages.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Previous match',
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: _opening || selected <= 0
                      ? null
                      : () => _select(state.messages[selected - 1]),
                ),
                IconButton(
                  tooltip: 'Next match',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed:
                      _opening ||
                          state.messages.isEmpty ||
                          selected + 1 >= state.messages.length
                      ? null
                      : () => _select(state.messages[selected + 1]),
                ),
              ],
            ),
          if (state.loading || _opening) const LinearProgressIndicator(),
          if (state.error != null)
            Row(
              children: [
                Expanded(child: Text(state.error!)),
                TextButton(
                  onPressed: state.loading ? null : cubit.retry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: ListView(
              children: [
                if (state.query.length < 2)
                  const ListTile(title: Text('Enter at least 2 characters.')),
                if (!state.loading &&
                    state.error == null &&
                    state.query.length >= 2 &&
                    state.rooms.isEmpty &&
                    state.messages.isEmpty)
                  const ListTile(title: Text('No results found.')),
                if (state.rooms.isNotEmpty)
                  const ListTile(title: Text('Conversations')),
                for (final room in state.rooms)
                  ListTile(
                    leading: Icon(
                      room.isGroup
                          ? Icons.group_outlined
                          : Icons.chat_bubble_outline,
                    ),
                    title: SearchHighlight(room.title, state.query),
                    subtitle: room.participant?.username == null
                        ? null
                        : SearchHighlight(
                            '@${room.participant!.username}',
                            state.query,
                          ),
                    onTap: _opening ? null : () => widget.onRoom?.call(room),
                  ),
                if (state.messages.isNotEmpty && widget.onClose == null)
                  const ListTile(title: Text('Messages')),
                for (final match in state.messages)
                  ListTile(
                    selected: match.message.id == _selected,
                    title: SearchHighlight(
                      searchPreview(match.message.content, state.query),
                      state.query,
                      maxLines: 3,
                    ),
                    subtitle: Text(
                      '${match.room.title} · ${match.message.senderDisplayName ?? ''}\n${match.message.createdAt.toLocal()}',
                    ),
                    onTap: _opening ? null : () => _select(match),
                  ),
                if (state.roomCursor != null || state.messageCursor != null)
                  TextButton(
                    onPressed: state.loading ? null : cubit.more,
                    child: const Text('Load more results'),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
