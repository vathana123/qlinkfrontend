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
  final _cancel = CancelToken();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.message.type == 'IMAGE' &&
        widget.message.delivery == Delivery.sent &&
        _image == null &&
        !_loading &&
        _error == null) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await context
          .read<ChatRepository>()
          .api
          .dio
          .get<List<int>>(
            '/api/v1/storage/files/${widget.message.fileId}/download',
            options: Options(responseType: ResponseType.bytes),
            cancelToken: _cancel,
          );
      if (mounted) setState(() => _image = Uint8List.fromList(response.data!));
    } catch (_) {
      if (mounted) setState(() => _error = 'Image unavailable. Tap to retry.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open() async {
    if (_loading || widget.message.delivery != Delivery.sent) return;
    final dio = context.read<ChatRepository>().api.dio;
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
      await dio.download(
        '/api/v1/storage/files/${widget.message.fileId}/download',
        path,
        cancelToken: _cancel,
      );
      if (!mounted) return;
      final result = await OpenFile.open(path);
      if (result.type != ResultType.done) throw StateError(result.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Unable to open file. Install a compatible app or tap to retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _preview() {
    if (_image == null) {
      _loadImage();
      return;
    }
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
              child: Image.memory(_image!, fit: BoxFit.contain),
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
    _cancel.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final metadata = m.attachment;
    final colors = Theme.of(context).colorScheme;
    final image = m.type == 'IMAGE';
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (image)
            InkWell(
              onTap: m.delivery == Delivery.sent ? _preview : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _image != null
                    ? Image.memory(
                        _image!,
                        width: 240,
                        fit: BoxFit.contain,
                        cacheWidth: 640,
                        errorBuilder: (_, _, _) =>
                            const Text('Image preview unavailable'),
                      )
                    : m.localPath != null
                    ? Image.file(
                        File(m.localPath!),
                        width: 240,
                        fit: BoxFit.contain,
                        cacheWidth: 640,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.image_not_supported_outlined),
                      )
                    : SizedBox(
                        height: 120,
                        child: Center(
                          child: _loading
                              ? const CircularProgressIndicator()
                              : const Icon(Icons.image_outlined),
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
          if (metadata != null)
            Text(
              readableFileSize(metadata.sizeBytes),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (m.delivery == Delivery.sending) ...[
            LinearProgressIndicator(value: m.uploadProgress),
            Text(
              m.uploadProgress < 1
                  ? 'Uploading ${(m.uploadProgress * 100).round()}%'
                  : 'Sending…',
            ),
          ],
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
