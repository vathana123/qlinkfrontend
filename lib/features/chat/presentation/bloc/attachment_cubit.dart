import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/datasources/attachment_picker.dart';
import '../../data/datasources/chat_api.dart';
import 'chat_cubit.dart';

class AttachmentSelection {
  const AttachmentSelection({
    this.files = const [],
    this.busy = false,
    this.error,
  });
  final List<XFile> files;
  final bool busy;
  final String? error;
}

class AttachmentCubit extends Cubit<AttachmentSelection> {
  AttachmentCubit(this.chat, {AttachmentPicker? picker})
    : picker = picker ?? AttachmentPicker(),
      super(const AttachmentSelection());
  final ChatCubit chat;
  final AttachmentPicker picker;
  AttachmentSource? _source;
  Future<void> pick(AttachmentSource source) async {
    if (state.busy || chat.state.sending) return;
    _source = source;
    emit(const AttachmentSelection(busy: true));
    try {
      final files = await picker.pick(source);
      if (!isClosed) emit(AttachmentSelection(files: files));
    } catch (e) {
      if (!isClosed) emit(AttachmentSelection(error: chatError(e)));
    }
  }

  void cancel() {
    if (!isClosed) emit(const AttachmentSelection());
  }

  Future<void> confirm(List<XFile> files) async {
    if (state.busy || files.isEmpty || _source == null || chat.state.sending) {
      return;
    }
    emit(const AttachmentSelection(busy: true));
    final failures = <String>[];
    try {
      final policy = await chat.repository.api.get('storage/files/policy');
      for (final file in files) {
        if (isClosed || chat.isClosed) break;
        try {
          final prepared = await picker.prepare(
            file,
            _source!,
            policy['maxSizeBytes'] as int,
            policy['extensions'] as Map<String, dynamic>,
          );
          if (isClosed || chat.isClosed || chat.state.sending) {
            await File(prepared.path).delete();
            break;
          }
          await chat.sendAttachment(prepared.path, prepared.metadata);
        } catch (e) {
          failures.add(chatError(e));
        }
      }
      if (!isClosed) {
        emit(
          AttachmentSelection(
            error: failures.isEmpty ? null : failures.join('\n'),
          ),
        );
      }
    } catch (e) {
      if (!isClosed) emit(AttachmentSelection(error: chatError(e)));
    }
  }
}
