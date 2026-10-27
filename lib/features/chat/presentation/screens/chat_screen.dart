import '../../data/datasources/chat_api.dart';

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
import '../bloc/chat_search_cubit.dart';
import '../widgets/chat_search_panel.dart';
import '../widgets/voice_input.dart';
import '../widgets/attachment_button.dart';
import '../widgets/attachment_bubble.dart';
import '../widgets/voice_bubble.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({
    super.key,
    required this.conversation,
    this.initialMessageId,
  });
  final Conversation conversation;
  final String? initialMessageId;
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
      child: _ChatView(
        conversation: conversation,
        initialMessageId: initialMessageId,
      ),
    );
  }
}

// The server ID can change when an optimistic message is acknowledged.
Key chatMessageKey(ChatMessage message) => message.clientMessageId.isNotEmpty
    ? ValueKey(('client', message.senderId, message.clientMessageId))
    : ValueKey(('server', message.id));

class _ChatView extends StatefulWidget {
  const _ChatView({required this.conversation, this.initialMessageId});
  final Conversation conversation;
  final String? initialMessageId;
  @override
  State<_ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<_ChatView> with WidgetsBindingObserver {
  late final ChatRepository _mediaRepository;
  Timer? _seenTimer;
  Timer? _highlightTimer;
  ChatSearchCubit? _search;
  bool _jumping = false;
  void _toggleSearch() {
    if (_search != null) {
      unawaited(_search!.close());
      setState(() => _search = null);
    } else {
      final chat = context.read<ChatCubit>();
      if (chat.state.roomId == null) return;
      setState(
        () => _search = ChatSearchCubit(
          chat.repository,
          roomId: chat.state.roomId,
        ),
      );
    }
  }

  Future<void> _jumpToSearchMessage(String id) async {
    if (_jumping) return;
    setState(() => _jumping = true);
    final found = await context.read<ChatCubit>().jumpToMessage(id);
    if (!mounted) return;
    if (found) {
      await _scrollToMessage(id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message unavailable. Refresh search and try again.'),
        ),
      );
    }
    if (mounted) setState(() => _jumping = false);
  }

  String? _settingsRoom;
  bool _notificationsMuted = false;
  Future<void> _loadNotificationSettings() async {
    final cubit = context.read<ChatCubit>(),
        room = context.read<ChatCubit>().state.roomId;
    if (room == null || room == _settingsRoom) return;
    _settingsRoom = room;
    try {
      final settings = await cubit.repository.api.get(
        'chat/rooms/$room/notifications',
      );
      if (mounted) {
        setState(() => _notificationsMuted = settings['muted'] == true);
      }
    } catch (_) {
      _settingsRoom = null;
    }
  }

  Future<void> _toggleNotifications() async {
    final cubit = context.read<ChatCubit>(),
        room = context.read<ChatCubit>().state.roomId;
    if (room == null) return;
    try {
      await cubit.repository.api.dio.put<dynamic>(
        '/api/v1/chat/rooms/$room/notifications',
        data: {'muted': !_notificationsMuted},
      );
      if (mounted) setState(() => _notificationsMuted = !_notificationsMuted);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(chatError(e))));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _mediaRepository = context.read<ChatRepository>();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_scheduleSeen);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadNotificationSettings());
      if (mounted && widget.initialMessageId != null) {
        unawaited(_jumpToSearchMessage(widget.initialMessageId!));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleSeen();
      unawaited(context.read<ChatCubit>().synchronize());
    }
  }

  void _scheduleSeen() {
    _seenTimer?.cancel();
    _seenTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          (WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed)) {
        return;
      }
      final cubit = context.read<ChatCubit>();
      final viewport = _listKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
        return;
      }
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final appBarBottom = MediaQuery.paddingOf(context).top + kToolbarHeight;
      final visibleTop = viewportTop > appBarBottom
          ? viewportTop
          : appBarBottom;
      final visibleBottom = viewportTop + viewport.size.height;
      final visible = cubit.state.messages.where((m) {
        final box = _messageKeys[m.id]?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return false;
        final top = box.localToGlobal(Offset.zero).dy;
        return top < visibleBottom && top + box.size.height > visibleTop;
      });
      if (cubit.state.roomId != null) {
        cubit.repository.acknowledge(cubit.state.roomId!, visible, seen: true);
      }
    });
  }

  ChatMessage? _editing;
  String _draft = '';
  bool _saving = false;
  String? _highlight;
  final _messageKeys = <String, GlobalKey>{};
  final _listKey = GlobalKey();
  final _text = TextEditingController();
  final _scroll = ScrollController();
  @override
  void dispose() {
    _mediaRepository.pauseVoiceForRoom(widget.conversation.roomId);
    _seenTimer?.cancel();
    _highlightTimer?.cancel();
    unawaited(_search?.close());
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_scheduleSeen);
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

  Future<void> _actions(ChatMessage message) async {
    if (!message.isConfirmed) {
      final cubit = context.read<ChatCubit>();
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.delivery == Delivery.failed)
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('Retry'),
                  onTap: () => Navigator.pop(context, 'retry'),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Discard pending message'),
                onTap: () => Navigator.pop(context, 'discard'),
              ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      if (action == 'retry') unawaited(cubit.retry(message));
      if (action == 'discard') await cubit.discard(message);
      return;
    }
    final cubit = context.read<ChatCubit>();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!message.deleted && cubit.state.canSend)
              ListTile(
                dense: true,
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
            if (!message.deleted &&
                message.type == 'TEXT' &&
                cubit.state.canSend &&
                message.senderId == cubit.senderId)
              ListTile(
                dense: true,
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for Me'),
              onTap: () => Navigator.pop(context, 'me'),
            ),
            if (message.canDeleteForEveryone)
              ListTile(
                dense: true,
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('Delete for Everyone'),
                onTap: () => Navigator.pop(context, 'everyone'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (_search != null && (action == 'reply' || action == 'edit')) {
      _toggleSearch();
    }
    if (action == 'reply') {
      if (_editing != null) _cancelEdit();
      cubit.selectReply(message);
    } else if (action == 'edit') {
      cubit.selectReply(null);
      setState(() {
        if (_editing == null) _draft = _text.text;
        _editing = message;
        _text.text = message.content;
      });
    } else {
      await cubit.deleteMessage(message, everyone: action == 'everyone');
    }
  }

  void _cancelEdit() {
    setState(() {
      _editing = null;
      _text.text = _draft;
    });
  }

  Future<void> _saveEdit() async {
    if (_saving || _editing == null) return;
    setState(() => _saving = true);
    final saved = await context.read<ChatCubit>().editMessage(
      _editing!,
      _text.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) _cancelEdit();
  }

  Future<void> _showOriginal(ReplyPreview preview) async {
    final cubit = context.read<ChatCubit>();
    final found = !preview.unavailable && await cubit.findOriginal(preview.id);
    if (!mounted) return;
    if (!found) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Original message is unavailable.')),
      );
      return;
    }
    await _scrollToMessage(preview.id);
  }

  Future<void> _scrollToMessage(String id) async {
    setState(() => _highlight = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlight = null);
    });
    await WidgetsBinding.instance.endOfFrame;
    // Walk the lazy list by viewport so variable-height media bubbles remain accurate.
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
    while (mounted && _scroll.hasClients) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;
      final target = _messageKeys[id]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: .5,
          duration: const Duration(milliseconds: 200),
        );
        return;
      }
      final next = (_scroll.offset + _scroll.position.viewportDimension * .8)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      if (next <= _scroll.offset) return;
      _scroll.jumpTo(next);
    }
  }

  Widget _quote(ReplyPreview reply) => InkWell(
    onTap: () => _showOriginal(reply),
    child: Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      child: Text(
        '${reply.senderDisplayName == null ? '' : '${reply.senderDisplayName}\n'}${reply.content}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );

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
          if (chat.roomId != null && !chat.removed)
            IconButton(
              tooltip: 'Search this conversation',
              onPressed: _toggleSearch,
              icon: const Icon(Icons.search),
            ),
          if (!conversation.isGroup)
            UserAvatar(
              name: conversation.title,
              url: conversation.avatarUrl,
              radius: 18,
            ),
          const SizedBox(width: 16),
          if (chat.roomId != null && !chat.removed)
            IconButton(
              tooltip: _notificationsMuted
                  ? 'Unmute conversation'
                  : 'Mute conversation',
              onPressed: _toggleNotifications,
              icon: Icon(
                _notificationsMuted
                    ? Icons.notifications_off_outlined
                    : Icons.notifications_outlined,
              ),
            ),
          // IconButton(
          //   tooltip: 'Refresh messages',
          //   onPressed: () => context.read<ChatCubit>().synchronize(),
          //   icon: const Icon(Icons.refresh),
          // ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: BlocConsumer<ChatCubit, ChatState>(
          listenWhen: (previous, current) =>
              previous.messages != current.messages ||
              previous.removed != current.removed,
          listener: (context, state) {
            if (state.removed && _search != null) _toggleSearch();
            final visibleIds = state.messages.map((m) => m.id).toSet();
            _messageKeys.removeWhere((id, _) => !visibleIds.contains(id));
            unawaited(_loadNotificationSettings());
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scheduleSeen();
            });
            if (_editing != null &&
                (state.removed ||
                    !state.messages.any(
                      (m) => m.id == _editing!.id && !m.deleted,
                    ))) {
              _cancelEdit();
            }
            if (_jumping ||
                state.contextMessageId != null ||
                !_scroll.hasClients ||
                _scroll.offset > 100) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  !_jumping &&
                  _scroll.hasClients &&
                  _scroll.offset <= 100) {
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
                if (_search != null && !state.removed)
                  Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.paddingOf(context).top + kToolbarHeight,
                    ),
                    child: SizedBox(
                      height:
                          ((MediaQuery.sizeOf(context).height -
                                      MediaQuery.viewInsetsOf(context).bottom) *
                                  .4)
                              .clamp(150, 280),
                      child: BlocProvider.value(
                        value: _search!,
                        child: ChatSearchPanel(
                          onClose: _toggleSearch,
                          onMessage: (match) =>
                              _jumpToSearchMessage(match.message.id),
                        ),
                      ),
                    ),
                  ),
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
                          child: state.cursor != null
                              ? TextButton(
                                  onPressed: state.loading
                                      ? null
                                      : () => context.read<ChatCubit>().load(),
                                  child: const Text('Load older messages'),
                                )
                              : Text(
                                  state.roomId == null
                                      ? 'Say hello to ${conversation.title}'
                                      : 'No messages yet',
                                ),
                        )
                      : ListView.builder(
                          key: _listKey,
                          controller: _scroll,
                          reverse: true,
                          padding: EdgeInsets.only(
                            top: _search != null
                                ? 16
                                : MediaQuery.paddingOf(context).top +
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
                              child: GestureDetector(
                                key: _messageKeys.putIfAbsent(
                                  message.id,
                                  () => GlobalKey(),
                                ),
                                onLongPress: () => _actions(message),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  padding: message.type == 'IMAGE'
                                      ? const EdgeInsets.all(4)
                                      : const EdgeInsets.fromLTRB(
                                          14,
                                          10,
                                          14,
                                          8,
                                        ),
                                  constraints: BoxConstraints(
                                    maxWidth:
                                        (MediaQuery.sizeOf(context).width * .82)
                                            .clamp(0.0, 560.0),
                                  ),
                                  decoration: BoxDecoration(
                                    border: message.id == _highlight
                                        ? Border.all(
                                            color: colors.primary,
                                            width: 2,
                                          )
                                        : Border.all(
                                            color: colors.outlineVariant
                                                .withValues(alpha: .35),
                                          ),
                                    color: mine
                                        ? colors.primaryContainer
                                        : colors.surfaceContainer,
                                    borderRadius: BorderRadius.only(
                                      topLeft: const Radius.circular(20),
                                      topRight: const Radius.circular(20),
                                      bottomLeft: Radius.circular(
                                        mine ? 20 : 6,
                                      ),
                                      bottomRight: Radius.circular(
                                        mine ? 6 : 20,
                                      ),
                                    ),
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
                                      if (message.reply != null)
                                        _quote(message.reply!),
                                      if (message.deleted)
                                        const Text(
                                          'Message deleted',
                                          style: TextStyle(
                                            fontStyle: FontStyle.italic,
                                          ),
                                        )
                                      else if (message.isVoice)
                                        VoiceBubble(
                                          message: message,
                                          roomId: state.roomId,
                                        )
                                      else if (message.isAttachment)
                                        AttachmentBubble(
                                          message: message,
                                          roomId: state.roomId,
                                        )
                                      else
                                        Text(
                                          message.content,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyLarge
                                              ?.copyWith(
                                                height: 1.4,
                                                color: mine
                                                    ? colors.onPrimaryContainer
                                                    : colors.onSurface,
                                              ),
                                        ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${messageTime(message.displayTime)}${message.editedAt != null && !message.deleted ? ' · Edited' : ''}${mine ? ' · ${message.statusText}' : ''}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: mine
                                                  ? colors.onPrimaryContainer
                                                        .withValues(alpha: .75)
                                                  : colors.onSurfaceVariant,
                                            ),
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
                              ),
                            );
                          },
                        ),
                ),
                if (context.read<ChatCubit>().replyTo != null)
                  Row(
                    children: [
                      Expanded(
                        child: _quote(
                          ReplyPreview.fromMessage(
                            context.read<ChatCubit>().replyTo!,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cancel reply',
                        onPressed: () =>
                            context.read<ChatCubit>().selectReply(null),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                if (state.contextMessageId != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (state.newerCursor != null)
                        Expanded(
                          child: TextButton(
                            onPressed: state.loading || _jumping
                                ? null
                                : () => context.read<ChatCubit>().loadNewer(),
                            child: const Text(
                              'Load newer messages',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      Expanded(
                        child: TextButton(
                          onPressed: state.loading || _jumping
                              ? null
                              : () async {
                                  await context
                                      .read<ChatCubit>()
                                      .returnToLatest();
                                  if (mounted && _scroll.hasClients) {
                                    _scroll.jumpTo(0);
                                  }
                                },
                          child: const Text(
                            'Back to latest',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                if (_editing != null && _search == null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        const Text('Edit message'),
                        TextField(
                          controller: _text,
                          maxLength: 4000,
                          minLines: 1,
                          maxLines: 5,
                          enabled: !_saving,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _saving ? null : _cancelEdit,
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: _saving ? null : _saveEdit,
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (_editing == null && _search == null)
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
                            attachmentButton: const AttachmentButton(
                              busy: false,
                            ),
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
