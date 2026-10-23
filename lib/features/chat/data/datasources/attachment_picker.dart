import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chat_models.dart';

enum AttachmentSource { photo, image, document, downloads }

class PreparedAttachment {
  const PreparedAttachment(this.path, this.metadata);
  final String path;
  final AttachmentMetadata metadata;
}

class AttachmentPicker {
  AttachmentPicker({this.temporaryDirectory = getTemporaryDirectory});
  final Future<Directory> Function() temporaryDirectory;

  /// Enough local metadata to show a message before requesting upload policy.
  Future<AttachmentMetadata> describe(XFile file) async {
    const types = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'csv': 'text/csv',
      'json': 'application/json',
      'doc': 'application/msword',
      'xls': 'application/vnd.ms-excel',
      'ppt': 'application/vnd.ms-powerpoint',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    };
    return AttachmentMetadata(
      file.name,
      types[file.name.split('.').last.toLowerCase()] ??
          file.mimeType ??
          'application/octet-stream',
      await file.length(),
    );
  }

  Future<List<XFile>> pick(AttachmentSource source) async {
    if (source == AttachmentSource.photo) {
      // Native gallery supplies multi-selection indicators and confirmation.
      return ImagePicker().pickMultiImage(requestFullMetadata: false);
    }
    String? directory;
    if (source == AttachmentSource.downloads &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      try {
        directory = (await getDownloadsDirectory())?.path;
      } catch (_) {}
    }
    final images = source == AttachmentSource.image;
    return openFiles(
      initialDirectory: directory,
      confirmButtonText: 'Done',
      acceptedTypeGroups: source == AttachmentSource.downloads
          ? const []
          : [
              XTypeGroup(
                label: images ? 'Images' : 'Documents',
                extensions: images
                    ? ['jpg', 'jpeg', 'png', 'gif', 'webp']
                    : [
                        'pdf',
                        'doc',
                        'docx',
                        'xls',
                        'xlsx',
                        'ppt',
                        'pptx',
                        'txt',
                        'csv',
                      ],
                mimeTypes: images
                    ? ['image/jpeg', 'image/png', 'image/gif', 'image/webp']
                    : [
                        'application/pdf',
                        'application/msword',
                        'application/vnd.ms-excel',
                        'application/vnd.ms-powerpoint',
                        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
                        'text/plain',
                        'text/csv',
                      ],
                uniformTypeIdentifiers: images
                    ? ['public.image']
                    : ['public.content'],
              ),
            ],
    );
  }

  Future<PreparedAttachment> prepare(
    XFile file,
    AttachmentSource source,
    int maxBytes,
    Map<String, dynamic> extensions,
  ) async {
    final size = await file.length();
    if (size == 0) throw StateError('${file.name} is empty.');
    final extension = file.name.split('.').last.toLowerCase();
    if (!extensions.containsKey(extension)) {
      throw StateError('${file.name}: this format is not supported.');
    }
    // Bound memory before decoding. Only a private copy is modified.
    if (size > maxBytes) {
      throw StateError('${file.name} exceeds the upload limit.');
    }
    final directory = await (await temporaryDirectory()).createTemp(
      'qlink-attachment-',
    );
    try {
      var name = file.name.replaceAll('\\', '/').split('/').last;
      var mime = extensions[extension] as String;
      final path = '${directory.path}/payload.$extension';
      await file.saveTo(
        path,
      ); // Always own the copy: ChatCubit may delete it after success.
      var output = path;
      if (source == AttachmentSource.photo) {
        final compressed = await compute(compressPhoto, path);
        if (compressed != path) {
          output = compressed;
          name = '${name.substring(0, name.lastIndexOf('.'))}.jpg';
          mime = 'image/jpeg';
          await File(path).delete();
        }
      }
      return PreparedAttachment(
        output,
        AttachmentMetadata(name, mime, await File(output).length()),
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }
}

/// Runs in an isolate. Only JPEG and opaque PNG photos are recompressed.
/// Animation, transparency and unsupported formats retain their original bytes.
String compressPhoto(String path) {
  final extension = path.split('.').last.toLowerCase();
  if (!['jpg', 'jpeg', 'png'].contains(extension)) return path;
  try {
    final bytes = File(path).readAsBytesSync();
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width * info.height > 40000000) return path;
    final decoded = decoder!.decode(bytes);
    if (decoded == null || decoded.numFrames > 1) return path;
    if (decoded.hasAlpha &&
        decoded.any((pixel) => pixel.a != pixel.maxChannelValue)) {
      return path;
    }
    var photo = img.bakeOrientation(decoded);
    final oversized = photo.width > 1600 || photo.height > 1600;
    if (!oversized && bytes.length < 256 * 1024) return path;
    if (oversized) {
      photo = img.copyResize(
        photo,
        width: photo.width >= photo.height ? 1600 : null,
        height: photo.height > photo.width ? 1600 : null,
        interpolation: img.Interpolation.average,
      );
    }
    final encoded = img.encodeJpg(photo, quality: 78);
    if (encoded.length >= bytes.length) return path;
    final target = '$path.compressed.jpg';
    File(target).writeAsBytesSync(encoded, flush: true);
    return target;
  } catch (_) {
    return path; // Backend still validates content before publication.
  }
}
