import 'dart:io';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/repositories/private_media_cache.dart';

String readableFileSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class AttachmentBubble extends StatefulWidget {
  const AttachmentBubble({super.key, required this.message, this.roomId});
  final ChatMessage message;
  final String? roomId;
  @override
  State<AttachmentBubble> createState() => _AttachmentBubbleState();
}

class _AttachmentBubbleState extends State<AttachmentBubble> {
  CachedPhoto? _image;
  PrivateMediaCache? _media;
  String? _account;
  StreamSubscription<String?>? _cacheChanges;
  String? _error;
  bool _loading = false;
  var _cancel = CancelToken();
  int _generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.message.type != 'IMAGE') return;
    final media = context.read<ChatRepository>().media;
    if (_media != media) {
      if (_media != null) {
        _generation++;
        _cancel.cancel();
        _cancel = CancelToken();
        _image = null;
        _error = null;
        _loading = false;
      }
      unawaited(_cacheChanges?.cancel());
      _media = media;
      _account = media.account;
      _cacheChanges = media.changes.listen((id) {
        if (!mounted || id != null && id != widget.message.fileId) return;
        _generation++;
        _cancel.cancel();
        _cancel = CancelToken();
        setState(() {
          _image = null;
          _loading = false;
          _error = id == null ? null : 'Image unavailable. Tap to retry.';
        });
        if (id == null && media.account == _account) {
          scheduleMicrotask(() {
            if (mounted) _ensureImage();
          });
        }
      });
    }
    _track();
    _image ??= widget.message.fileId == null
        ? null
        : media.peekPhoto(widget.message.fileId!);
    _ensureImage();
  }

  void _track() {
    final id = widget.message.fileId;
    if (id != null) _media?.track(id, widget.message.id, widget.roomId);
  }

  void _seedPreview() {
    final id = widget.message.fileId;
    if (id != null &&
        _image != null &&
        widget.message.senderId == _media?.account) {
      unawaited(_media!.seedPhoto(id, _image!.bytes).catchError((Object _) {}));
    }
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
    _track();
    if (old.fileId == null && next.fileId != null) _seedPreview();
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
    _track();
    final media = context.read<ChatRepository>().media;
    final generation = _generation;
    bool current() => mounted && generation == _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Retain the sender's preview bytes before the send flow deletes its file.
      final localPath = widget.message.localPath;
      if (localPath != null && widget.message.senderId == media.account) {
        try {
          final image = await CachedPhoto.decode(
            await File(localPath).readAsBytes(),
          );
          if (!current()) return;
          setState(() => _image = image);
          _seedPreview();
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
      final image = await media.photo(widget.message.fileId!);
      if (current()) {
        setState(() => _image = image);
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
    final image = _image!;
    final media = _media!;
    final generation = media.generation;
    final id = widget.message.fileId;
    var unavailable = false;
    final title = widget.message.attachment?.originalName ?? 'Image';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: StreamBuilder<String?>(
            stream: media.changes,
            builder: (context, snapshot) {
              if (snapshot.data != null && snapshot.data == id) {
                unavailable = true;
              }
              if (generation != media.generation || unavailable) {
                return const Center(child: Text('Image unavailable.'));
              }
              return Center(
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 5,
                  child: Image(
                    image: image.preview,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text('Image unavailable.'),
                  ),
                ),
              );
            },
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
    unawaited(_cacheChanges?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    if (m.hidden || m.deleted) return const Text('Attachment unavailable');
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
                borderRadius: BorderRadius.circular(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 320,
                    maxHeight: 360,
                  ),
                  child: _image != null
                      ? AspectRatio(
                          aspectRatio: _image!.aspectRatio,
                          child: Image(
                            image: _image!.thumbnail,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => TextButton(
                              onPressed: () {
                                if (m.fileId != null) {
                                  _media?.invalidate(m.fileId!);
                                }
                                _image = null;
                                _loadImage();
                              },
                              child: const Text(
                                'Image preview unavailable. Tap to retry.',
                              ),
                            ),
                          ),
                        )
                      : m.localPath != null && m.senderId == _media?.account
                      ? Image(
                          image: ResizeImage(
                            FileImage(File(m.localPath!)),
                            width: 640,
                            height: 720,
                            policy: ResizeImagePolicy.fit,
                          ),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.image_not_supported_outlined),
                        )
                      : m.fileId != null &&
                            _media?.cachedAspectRatio(m.fileId!) != null
                      ? AspectRatio(
                          aspectRatio: _media!.cachedAspectRatio(m.fileId!)!,
                          child: const Center(
                            child: Icon(Icons.image_outlined),
                          ),
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
