import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';

String readableFileSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class AttachmentBubble extends StatefulWidget {
  const AttachmentBubble({super.key, required this.message});
  final ChatMessage message;
  @override
  State<AttachmentBubble> createState() => _AttachmentBubbleState();
}

class _AttachmentBubbleState extends State<AttachmentBubble> {
  Uint8List? _image;
  String? _error;
  bool _loading = false;
  var _cancel = CancelToken();
  int _generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureImage();
  }

  @override
  void didUpdateWidget(covariant AttachmentBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.message;
    final next = widget.message;
    final sameMessage =
        old.senderId == next.senderId &&
        (old.clientMessageId.isNotEmpty
            ? old.clientMessageId == next.clientMessageId
            : old.id == next.id);
    // A newly assigned file ID is the normal upload acknowledgement.
    if (!sameMessage ||
        old.type != next.type ||
        (old.fileId != null && old.fileId != next.fileId) ||
        (old.localPath != null &&
            next.localPath != null &&
            old.localPath != next.localPath)) {
      _generation++;
      _cancel.cancel();
      _cancel = CancelToken();
      _image = null;
      _error = null;
      _loading = false;
    }
    _ensureImage();
  }

  void _ensureImage() {
    if (widget.message.type == 'IMAGE' &&
        (widget.message.localPath != null || widget.message.isConfirmed) &&
        _image == null &&
        !_loading &&
        _error == null) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    if (_loading) return;
    final repository = context.read<ChatRepository>();
    final generation = _generation;
    bool current() => mounted && generation == _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Retain the sender's preview bytes before the send flow deletes its file.
      final localPath = widget.message.localPath;
      if (localPath != null) {
        try {
          final bytes = await File(localPath).readAsBytes();
          if (!current()) return;
          setState(() => _image = bytes);
          return;
        } catch (_) {
          if (!current()) return;
          // A confirmed message can still be downloaded if local cleanup won.
        }
      }
      if (!current() ||
          !widget.message.isConfirmed ||
          widget.message.fileId == null) {
        return;
      }
      final bytes = await repository.imageBytes(
        widget.message.fileId!,
        _cancel,
      );
      if (current()) {
        setState(() => _image = bytes);
      }
    } catch (_) {
      if (current()) {
        setState(() => _error = 'Image unavailable. Tap to retry.');
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    if (_loading || !widget.message.isConfirmed) return;
    final generation = _generation;
    bool current() => mounted && generation == _generation;
    final repository = context.read<ChatRepository>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folder = await (await getTemporaryDirectory()).createTemp(
        'qlink-download-',
      );
      final name = widget.message.attachment!.originalName.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );
      final path = '${folder.path}/$name';
      if (!current()) return;
      await repository.downloadFile(widget.message.fileId!, path, _cancel);
      if (!current()) return;
      final result = await OpenFile.open(path);
      if (result.type != ResultType.done) throw StateError(result.message);
    } catch (_) {
      if (current()) {
        setState(
          () => _error =
              'Unable to open file. Install a compatible app or tap to retry.',
        );
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  void _preview() {
    if (_image == null) {
      _loadImage();
      return;
    }
    final bytes = _image!;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(widget.message.attachment?.originalName ?? 'Image'),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 5,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  IconData get _icon {
    final extension = widget.message.attachment?.originalName
        .split('.')
        .last
        .toLowerCase();
    if (extension == 'pdf') return Icons.picture_as_pdf_outlined;
    if (['xls', 'xlsx', 'csv'].contains(extension)) {
      return Icons.table_chart_outlined;
    }
    if (['ppt', 'pptx'].contains(extension)) return Icons.slideshow;
    if (['doc', 'docx', 'txt'].contains(extension)) {
      return Icons.description_outlined;
    }
    if (widget.message.attachment?.contentType.startsWith('audio/') == true) {
      return Icons.audio_file_outlined;
    }
    if (widget.message.attachment?.contentType.startsWith('video/') == true) {
      return Icons.video_file_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  void dispose() {
    _generation++;
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final metadata = m.attachment;
    final colors = Theme.of(context).colorScheme;
    final image = m.type == 'IMAGE';
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: image ? 320 : 240),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (image)
            InkWell(
              onTap: _image != null || m.isConfirmed ? _preview : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 320,
                    maxHeight: 360,
                  ),
                  child: _image != null
                      ? Image.memory(
                          _image!,
                          fit: BoxFit.contain,
                          cacheWidth: 640,
                          errorBuilder: (_, _, _) =>
                              const Text('Image preview unavailable'),
                        )
                      : m.localPath != null
                      ? Image.file(
                          File(m.localPath!),
                          fit: BoxFit.contain,
                          cacheWidth: 640,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.image_not_supported_outlined),
                        )
                      : SizedBox(
                          height: 120,
                          child: Center(
                            child: _loading && m.isConfirmed
                                ? const CircularProgressIndicator()
                                : const Icon(Icons.image_outlined),
                          ),
                        ),
                ),
              ),
            ),
          if (!image)
            InkWell(
              onTap: _loading ? null : _open,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(_icon, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        metadata?.originalName ?? 'File',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_loading)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(Icons.download_outlined, color: colors.primary),
                  ],
                ),
              ),
            ),
          if (metadata != null && !image)
            Text(
              readableFileSize(metadata.sizeBytes),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (_error != null)
            TextButton(
              onPressed: image ? _loadImage : _open,
              child: Text(_error!, style: TextStyle(color: colors.error)),
            ),
        ],
      ),
    );
  }
}
