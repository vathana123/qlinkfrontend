import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/datasources/attachment_picker.dart';
import '../bloc/attachment_cubit.dart';
import '../bloc/chat_cubit.dart';

class AttachmentButton extends StatefulWidget {
  const AttachmentButton({super.key, required this.busy, this.picker});
  final bool busy;
  final AttachmentPicker? picker;
  @override
  State<AttachmentButton> createState() => _AttachmentButtonState();
}

class _AttachmentButtonState extends State<AttachmentButton> {
  late final AttachmentCubit _cubit = AttachmentCubit(
    context.read<ChatCubit>(),
    picker: widget.picker,
  );
  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  Future<void> _pick(AttachmentSource source) async {
    await _cubit.pick(source);
    if (!mounted || _cubit.state.files.isEmpty) return;
    final files = _cubit.state.files;
    final selected = files.toSet();
    final confirmed = await showDialog<List<XFile>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            source == AttachmentSource.photo
                ? 'Selected photos'
                : 'Selected files',
          ),
          content: SizedBox(
            width: 420,
            height: MediaQuery.sizeOf(context).height * .45,
            child: ListView.builder(
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return CheckboxListTile(
                  value: selected.contains(file),
                  title: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  secondary:
                      source == AttachmentSource.photo ||
                          source == AttachmentSource.image
                      ? SizedBox(
                          width: 48,
                          height: 48,
                          child: Image.file(
                            File(file.path),
                            fit: BoxFit.cover,
                            cacheWidth: 96,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.image_outlined),
                          ),
                        )
                      : const Icon(Icons.insert_drive_file_outlined),
                  onChanged: (value) => setDialogState(() {
                    if (value == true) {
                      selected.add(file);
                    } else {
                      selected.remove(file);
                    }
                  }),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, selected.toList()),
              child: Text('Done (${selected.length})'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (confirmed == null) {
      _cubit.cancel();
    } else {
      await _cubit.confirm(confirmed);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => BlocConsumer<AttachmentCubit, AttachmentSelection>(
    bloc: _cubit,
    listener: (context, state) {
      if (state.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(state.error!)));
      }
    },
    builder: (context, state) {
      final colors = Theme.of(context).colorScheme;
      return PopupMenuButton<AttachmentSource>(
        tooltip: 'Attach files',
        enabled: !widget.busy && !state.busy,
        icon: Icon(
          Icons.add,
          color: widget.busy ? colors.onSurfaceVariant : colors.primary,
        ),
        color: colors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: _pick,
        itemBuilder: (context) => [
          _item(
            AttachmentSource.photo,
            Icons.photo_library_outlined,
            'Photo',
            colors,
          ),
          _item(AttachmentSource.image, Icons.image_outlined, 'Image', colors),
          _item(
            AttachmentSource.document,
            Icons.description_outlined,
            'Document',
            colors,
          ),
          _item(
            AttachmentSource.downloads,
            Icons.download_outlined,
            'Downloads',
            colors,
          ),
        ],
      );
    },
  );
  PopupMenuItem<AttachmentSource> _item(
    AttachmentSource source,
    IconData icon,
    String label,
    ColorScheme colors,
  ) => PopupMenuItem(
    value: source,
    child: Row(
      children: [
        Icon(icon, color: colors.primary),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: colors.onSurface)),
      ],
    ),
  );
}
