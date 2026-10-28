import 'chat_models.dart';

class SharedFile {
  const SharedFile(this.path, this.name, this.mime, this.size);
  final String path, name, mime;
  final int size;
}

class ShareDraft {
  const ShareDraft({
    this.id,
    this.text = '',
    this.files = const [],
    this.message,
    this.sourceRoom,
    this.error,
  });
  final String? id, sourceRoom, error;
  final String text;
  final List<SharedFile> files;
  final ChatMessage? message;
  bool get valid =>
      error == null &&
      (message != null || text.trim().isNotEmpty || files.isNotEmpty);

  factory ShareDraft.fromPlatform(Map<Object?, Object?> value) {
    final id = value['id'] as String?;
    final text = value['text'] as String? ?? '';
    final raw = value['files'] as List? ?? [];
    final files = <SharedFile>[];
    var error = value['error'] as String?;
    var total = 0;
    if (text.length > 4000 || raw.length > 10) {
      error = 'Share up to 4000 characters or 10 files.';
    }
    for (final item in raw.take(10)) {
      final map = Map<Object?, Object?>.from(item as Map);
      final path = map['path'] as String? ?? '';
      final name = map['name'] as String? ?? '';
      final size = map['size'] as int? ?? 0;
      total += size;
      if (path.isEmpty ||
          name.isEmpty ||
          size <= 0 ||
          size > 32 * 1024 * 1024) {
        error = 'A shared file is empty, unavailable, or too large.';
      }
      files.add(
        SharedFile(
          path,
          name,
          map['mime'] as String? ?? 'application/octet-stream',
          size,
        ),
      );
    }
    if (total > 64 * 1024 * 1024) error = 'Shared files exceed 64 MB.';
    return ShareDraft(id: id, text: text, files: files, error: error);
  }
}
