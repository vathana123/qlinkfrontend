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
    if (state.busy) return;
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
    if (state.busy || files.isEmpty || _source == null) return;
    final source = _source!;
    final api = chat.repository.api;
    final selectedPicker = picker;
    emit(const AttachmentSelection(busy: true));
    final pending = <Future<bool>>[];
    final failures = <String>[];
    for (final file in files) {
      try {
        final metadata = await selectedPicker.describe(file);
        pending.add(
          chat.sendAttachment(
            file.path,
            metadata,
            ownsFile: false,
            prepare: (cancel) async {
              final policy = await api.uploadPolicy(cancelToken: cancel);
              if (cancel.isCancelled) throw cancel.cancelError!;
              return selectedPicker.prepare(
                file,
                source,
                policy['maxSizeBytes'] as int,
                policy['extensions'] as Map<String, dynamic>,
              );
            },
          ),
        );
      } catch (e) {
        failures.add(chatError(e));
      }
    }
    // Selection is complete; uploads continue in the session queue, independently
    // of this control and of the conversation screen's lifetime.
    if (!isClosed) {
      emit(
        AttachmentSelection(
          error: failures.isEmpty ? null : failures.join('\n'),
        ),
      );
    }
    await Future.wait(pending);
  }
}
