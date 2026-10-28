import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/models/chat_models.dart';
import '../../data/models/share_draft.dart';
import '../../data/repositories/chat_repository.dart';
import '../bloc/share_cubit.dart';

class ShareRequest {
  const ShareRequest(this.draft, {this.onRelease});
  final ShareDraft draft;
  final Future<void> Function()? onRelease;
}

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.draft, this.onRelease});
  final ShareDraft draft;
  final Future<void> Function()? onRelease;
  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  late final ShareCubit _cubit;
  late final String? _account;
  late final _text = TextEditingController(text: widget.draft.text);
  ChatRoom? _selected;
  bool _sent = false;
  bool _released = false;
  Future<void> _release() async {
    if (_released) return;
    _released = true;
    await widget.onRelease?.call();
  }

  @override
  void initState() {
    super.initState();
    _account = context.read<AuthBloc>().state.user?.id;
    _cubit = ShareCubit(context.read<ChatRepository>())..load();
  }

  @override
  void dispose() {
    _text.dispose();
    unawaited(_cubit.close());
    if (!_sent) unawaited(_release());
    super.dispose();
  }

  void _send() {
    if (_sent ||
        _selected == null ||
        _account == null ||
        context.read<AuthBloc>().state.user?.id != _account ||
        !widget.draft.valid ||
        _text.text.length > 4000 ||
        (widget.draft.message == null &&
            widget.draft.files.isEmpty &&
            _text.text.trim().isEmpty)) {
      return;
    }
    _sent = true;
    final work = _cubit.enqueue(
      widget.draft,
      _selected!,
      _account,
      _text.text,
      onRetained: () => unawaited(_release()),
    );
    // Retained files survive navigation, connection loss and process restarts.
    unawaited(
      Future.wait(work).then((results) async {
        if (results.every((sent) => sent)) await _release();
      }),
    );
    context.pushReplacement(
      '/conversation',
      extra: Conversation.fromRoom(_selected!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final sameAccount =
        context.select((AuthBloc b) => b.state.user?.id) == _account;
    return Scaffold(
      appBar: BlurAppBar(
        title: draft.message == null ? 'Share to qLink' : 'Forward message',
      ),
      body: !sameAccount
          ? const Center(child: Text('Account changed. Share again.'))
          : Column(
              children: [
                Flexible(
                  flex: 2,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (draft.error != null)
                          Text(
                            draft.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        if (draft.message case final message?)
                          Text(
                            message.type == 'TEXT'
                                ? message.content
                                : '${message.type} · ${message.attachment?.originalName ?? 'Voice message'}',
                          ),
                        if (draft.message == null)
                          TextField(
                            controller: _text,
                            maxLength: 4000,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Shared text',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        for (final file in draft.files)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: file.mime.startsWith('image/')
                                ? Image.file(
                                    File(file.path),
                                    width: 48,
                                    height: 48,
                                    cacheWidth: 96,
                                    cacheHeight: 96,
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.broken_image_outlined),
                                  )
                                : const Icon(Icons.insert_drive_file_outlined),
                            title: Text(file.name),
                            subtitle: Text('${(file.size / 1024).ceil()} KB'),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  flex: 3,
                  child: BlocBuilder<ShareCubit, ShareState>(
                    bloc: _cubit,
                    builder: (context, state) => ListView(
                      children: [
                        if (state.rooms.isEmpty &&
                            !state.loading &&
                            state.error == null)
                          const ListTile(
                            title: Text(
                              'No eligible conversations. Start a chat first.',
                            ),
                          ),
                        for (final room in state.rooms)
                          ListTile(
                            title: Text(room.title),
                            leading: Icon(
                              room.isGroup
                                  ? Icons.group_outlined
                                  : Icons.person_outline,
                            ),
                            selected: _selected?.id == room.id,
                            trailing: _selected?.id == room.id
                                ? const Icon(Icons.check_circle)
                                : null,
                            onTap: () => setState(() => _selected = room),
                          ),
                        if (state.error != null)
                          ListTile(
                            title: Text(state.error!),
                            trailing: TextButton(
                              onPressed: _cubit.load,
                              child: const Text('Retry'),
                            ),
                          ),
                        if (state.loading)
                          const Center(child: CircularProgressIndicator())
                        else if (state.more && state.error == null)
                          TextButton(
                            onPressed: _cubit.load,
                            child: const Text('More conversations'),
                          ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton.icon(
                      onPressed: _selected != null && draft.valid && !_sent
                          ? _send
                          : null,
                      icon: const Icon(Icons.send),
                      label: Text(
                        _selected == null
                            ? 'Select a conversation'
                            : 'Send to ${_selected!.title}',
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
