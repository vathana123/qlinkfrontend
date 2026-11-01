import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

class CachedPhoto {
  CachedPhoto(this.bytes, this.width, this.height)
    : thumbnail = ResizeImage(
        MemoryImage(bytes),
        width: 640,
        height: 720,
        policy: ResizeImagePolicy.fit,
      ),
      preview = ResizeImage(
        MemoryImage(bytes),
        width: 2048,
        height: 2048,
        policy: ResizeImagePolicy.fit,
      );
  final Uint8List bytes;
  final int width, height;
  final ImageProvider thumbnail, preview;
  double get aspectRatio => width / height;
  static Future<CachedPhoto> decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return CachedPhoto(bytes, descriptor.width, descriptor.height);
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> evict() async {
    await thumbnail.evict();
    await preview.evict();
  }
}

enum MediaCategory { photos, audio, files }

class CacheUsage {
  const CacheUsage(this.bytes);
  final Map<MediaCategory, int> bytes;
  int get total => bytes.values.fold(0, (sum, value) => sum + value);
  int operator [](MediaCategory category) => bytes[category] ?? 0;
}

class _MediaFile {
  _MediaFile(this.file, this.size, this.validatedAt, this.category);
  final File file;
  final int size;
  final DateTime validatedAt;
  final MediaCategory category;
  double? aspectRatio;
}

class _References {
  final messages = <String>{}, rooms = <String>{};
}

/// Private, session-only cache. File names never contain URLs or credentials.
/// Cache hits require the same active account; logout cancels work and purges
/// both disk files and this cache's decoded Flutter image entries.
class PrivateMediaCache {
  // Serialize session-folder creation across cache instances so recovery never
  // sweeps a folder still used by another live instance in this process.
  static Future<void>? _folderWork;
  static final _activeFolders = <String>{};
  PrivateMediaCache(
    this.dio, {
    Future<Directory> Function()? directory,
    this.maxDiskBytes = 128 * 1024 * 1024,
    this.maxPhotoBytes = 16 * 1024 * 1024,
    this.maxEntries = 256,
    this.maxFileBytes = 32 * 1024 * 1024,
    this.maxAge = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _directory = directory ?? getTemporaryDirectory,
       _now = now ?? DateTime.now;
  final Dio dio;
  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final int maxDiskBytes, maxPhotoBytes, maxEntries, maxFileBytes;
  final Duration maxAge;
  final _files = <String, _MediaFile>{};
  final _photos = <String, CachedPhoto>{};
  final _references = <String, _References>{};
  final _downloads = <String, Future<File>>{};
  final _photoLoads = <String, Future<CachedPhoto>>{};
  final _seeds = <String, Future<void>>{};
  final _cancels = <String, CancelToken>{};
  final _pins = <String>{};
  final _clearing = <String>{};
  final _storageChanges = StreamController<void>.broadcast();
  Stream<void> get storageChanges => _storageChanges.stream;
  void _storageChanged() {
    if (!_storageChanges.isClosed) _storageChanges.add(null);
  }

  /// Counts completed reusable files once, even when multiple messages reference one ID.
  Future<CacheUsage> usage() async {
    final generation = _generation;
    if (_account != null && !_disposed) {
      try {
        await _cacheFolder();
      } catch (_) {
        if (generation != _generation) return const CacheUsage({});
        rethrow;
      }
    }
    final totals = <MediaCategory, int>{};
    for (final entry in _files.values.toList()) {
      final stat = await entry.file.stat();
      if (generation != _generation) return const CacheUsage({});
      if (stat.type == FileSystemEntityType.file) {
        totals.update(
          entry.category,
          (value) => value + stat.size,
          ifAbsent: () => stat.size,
        );
      }
    }
    return CacheUsage(Map.unmodifiable(totals));
  }

  /// Local cache only. Outbox/picker paths never enter this registry. Active
  /// playback, downloads, decoding and upload-preview seeds remain protected.
  Future<CacheUsage> clearCached(Set<MediaCategory> categories) async {
    final generation = _generation;
    Object? failure;
    for (final item in _files.entries.toList()) {
      final id = item.key, entry = item.value;
      if (generation != _generation) return const CacheUsage({});
      if (!categories.contains(entry.category) ||
          _pins.contains(id) ||
          _downloads.containsKey(id) ||
          _photoLoads.containsKey(id) ||
          _seeds.containsKey(id) ||
          !_clearing.add(id)) {
        continue;
      }
      try {
        if (await entry.file.exists()) await entry.file.delete();
        if (generation != _generation) return const CacheUsage({});
        if (identical(_files[id], entry)) {
          _removeStored(id);
          _references.remove(id);
          if (!_changes.isClosed) _changes.add(id);
        }
      } on FileSystemException catch (error) {
        failure = error;
      } finally {
        _clearing.remove(id);
      }
    }
    await _cleanup;
    _storageChanged();
    if (failure != null) {
      throw StateError('Some cached files could not be cleared. Please retry.');
    }
    return usage();
  }

  final _waiters = Queue<Completer<void>>();
  final _changes = StreamController<String?>.broadcast(sync: true);
  Stream<String?> get changes => _changes.stream;
  String? _account;
  String? get account => _account;
  int _generation = 0,
      _diskBytes = 0,
      _photoBytes = 0,
      _active = 0,
      _serial = 0;
  int get generation => _generation;
  int get diskBytes => _diskBytes;
  int get photoBytes => _photoBytes;
  int get entryCount => _files.length;
  Future<Directory>? _folder;
  Future<void> _cleanup = Future.value();
  bool _disposed = false;

  void _later(Future<void> work) {
    _cleanup = Future.wait([_cleanup, work])
        .then<void>((_) {})
        .catchError((Object _) {});
  }

  void setAccount(String? account) {
    if (account == _account) return;
    _account = account;
    clear();
  }

  void clear() {
    _generation++;
    for (final cancel in _cancels.values) {
      cancel.cancel('Media access changed');
    }
    _cancels.clear();
    for (final waiter in _waiters) {
      waiter.completeError(StateError('Media access changed'));
    }
    _waiters.clear();
    _downloads.clear();
    _photoLoads.clear();
    _seeds.clear();
    for (final photo in _photos.values) {
      _later(photo.evict());
    }
    _photos.clear();
    _files.clear();
    _references.clear();
    _pins.clear();
    _diskBytes = _photoBytes = 0;
    _storageChanged();
    final oldFolder = _folder;
    _folder = null;
    if (oldFolder != null) {
      _later(
        oldFolder.then((folder) async {
          try {
            if (await folder.exists()) await folder.delete(recursive: true);
          } finally {
            _activeFolders.remove(folder.path);
          }
        }),
      );
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  void _check(int generation) {
    if (_disposed || _account == null || generation != _generation) {
      throw StateError('Media access changed. Please reopen the conversation.');
    }
  }

  bool _fresh(_MediaFile entry) =>
      _now().difference(entry.validatedAt) < maxAge;
  void track(String fileId, String messageId, String? roomId) {
    if (_account == null) return;
    final references = _references.remove(fileId) ?? _References();
    references.messages.add(messageId);
    if (roomId != null) references.rooms.add(roomId);
    _references[fileId] = references;
    while (_references.length > maxEntries + _pins.length) {
      final victim = _references.keys
          .where((key) => !_pins.contains(key))
          .firstOrNull;
      if (victim == null) break;
      invalidate(victim);
    }
  }

  void invalidateMessage(String id) {
    for (final file
        in _references.keys
            .where((key) => _references[key]!.messages.contains(id))
            .toList()) {
      invalidate(file);
    }
  }

  void invalidateRoom(String id) {
    for (final file
        in _references.keys
            .where((key) => _references[key]!.rooms.contains(id))
            .toList()) {
      invalidate(file);
    }
  }

  void invalidate(String id) {
    _cancels.remove(id)?.cancel('Media unavailable');
    _downloads.remove(id);
    _photoLoads.remove(id);
    _removeStored(id);
    _references.remove(id);
    _pins.remove(id);
    if (!_changes.isClosed) _changes.add(id);
  }

  void _removeStored(String id) {
    final photo = _photos.remove(id);
    if (photo != null) {
      _photoBytes -= photo.bytes.length;
      _later(photo.evict());
    }
    final entry = _files.remove(id);
    if (entry != null) {
      _diskBytes -= entry.size;
      _later(
        entry.file.exists().then((exists) async {
          if (exists) await entry.file.delete();
        }),
      );
    }
    _storageChanged();
  }

  void pin(String id) => _pins.add(id);
  void unpin(String id) {
    _pins.remove(id);
    _prune();
  }

  void _prune({String? protect}) {
    while (_files.length > maxEntries || _diskBytes > maxDiskBytes) {
      final victim = _files.keys
          .where((key) => key != protect && !_pins.contains(key))
          .firstOrNull;
      if (victim == null) break;
      invalidate(victim);
    }
  }

  Future<Directory> _cacheFolder() {
    if (_folder != null) return _folder!;
    final generation = _generation;
    final account = base64Url.encode(utf8.encode(_account!));
    final ready = Completer<Directory>();
    _folder = ready.future;
    final previous = _folderWork;
    final completed = Completer<void>();
    _folderWork = completed.future;
    unawaited(() async {
      try {
        if (previous != null) await previous;
        _check(generation);
        final parent = await _directory();
        _check(generation);
        final root = await Directory('${parent.path}/qlink-media-v1/$account')
            .create(recursive: true);
        // Only our own account's abandoned session folders; never picker,
        // outbox, other-account directories or symlinks.
        await for (final entry in root.list(followLinks: false)) {
          final name = entry.path.replaceAll('\\', '/').split('/').last;
          if (entry is Directory &&
              name.startsWith('session-') &&
              !_activeFolders.contains(entry.path)) {
            await entry.delete(recursive: true);
          }
        }
        _check(generation);
        final folder = await root.createTemp('session-');
        if (generation != _generation || _disposed) {
          await folder.delete(recursive: true);
          _check(generation);
        }
        _activeFolders.add(folder.path);
        ready.complete(folder);
      } catch (error, stack) {
        if (identical(_folder, ready.future)) _folder = null;
        ready.completeError(error, stack);
      } finally {
        if (identical(_folderWork, completed.future)) _folderWork = null;
        completed.complete();
      }
    }());
    return ready.future;
  }

  Future<void> _acquire() async {
    if (_active < 4) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<File> file(
    String id, {
    bool voice = false,
    MediaCategory? category,
    String? filename,
  }) {
    final generation = _generation;
    _check(generation);
    if (_clearing.contains(id)) {
      return Future.error(StateError('Cache is being cleared. Please retry.'));
    }
    final pending = _downloads[id];
    if (pending != null) return pending;
    if (_downloads.length >= 32) {
      return Future.error(StateError('Media queue is busy. Please retry.'));
    }
    final cancel = CancelToken();
    _cancels[id] = cancel;
    late final Future<File> operation;
    operation =
        _load(
          id,
          generation,
          cancel,
          voice,
          category ?? (voice ? MediaCategory.audio : MediaCategory.files),
          filename,
        ).whenComplete(() {
          if (identical(_downloads[id], operation)) {
            _downloads.remove(id);
            _cancels.remove(id);
          }
        });
    _downloads[id] = operation;
    return operation;
  }

  Future<File> _load(
    String id,
    int generation,
    CancelToken cancel,
    bool voice,
    MediaCategory category,
    String? filename,
  ) async {
    var acquired = false;
    File? temporary;
    try {
      final existing = _files[id];
      if (existing != null &&
          _fresh(existing) &&
          await existing.file.exists()) {
        _check(generation);
        if (cancel.isCancelled) throw cancel.cancelError!;
        _files.remove(id);
        _files[id] = existing;
        return existing.file;
      }
      if (existing != null) _removeStored(id);
      await _acquire();
      acquired = true;
      _check(generation);
      if (cancel.isCancelled) throw cancel.cancelError!;
      final folder = await _cacheFolder();
      _check(generation);
      final name = '${base64Url.encode(utf8.encode(id))}-${_serial++}';
      temporary = File('${folder.path}/$name.part');
      final response = await dio.get<ResponseBody>(
        '/api/v1/storage/files/${Uri.encodeComponent(id)}/download',
        options: Options(
          responseType: ResponseType.stream,
          extra: {'expectedAccountId': _account},
        ),
        cancelToken: cancel,
      );
      final declared = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      final limit = maxFileBytes < maxDiskBytes ? maxFileBytes : maxDiskBytes;
      final sink = temporary.openWrite();
      var size = 0;
      try {
        await for (final chunk in response.data!.stream) {
          _check(generation);
          if (cancel.isCancelled) throw cancel.cancelError!;
          size += chunk.length;
          if (size > limit) throw StateError('Media file is too large.');
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (size == 0 || (declared != null && declared != size)) {
        throw StateError('Incomplete media download. Please retry.');
      }
      _check(generation);
      if (cancel.isCancelled) throw cancel.cancelError!;
      final extension = filename?.split('.').last.toLowerCase();
      final suffix =
          extension != null && RegExp(r'^[a-z0-9]{1,10}$').hasMatch(extension)
          ? extension
          : voice
          ? 'wav'
          : 'media';
      final saved = await temporary.rename('${folder.path}/$name.$suffix');
      temporary = saved;
      _check(generation);
      if (cancel.isCancelled) throw cancel.cancelError!;
      _files[id] = _MediaFile(saved, size, _now(), category);
      _diskBytes += size;
      temporary = null;
      _storageChanged();
      _prune(protect: id);
      return saved;
    } on DioException catch (error) {
      if (generation == _generation) {
        if (error.response?.statusCode == 401) {
          clear();
        } else if ([403, 404].contains(error.response?.statusCode)) {
          invalidate(id);
        }
      }
      rethrow;
    } finally {
      if (acquired) _release();
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } on FileSystemException {
        /* Cache cleanup must not mask a failed request. */
      }
    }
  }

  CachedPhoto? peekPhoto(String id) {
    if (_account == null || _disposed) return null;
    final entry = _files[id];
    if (entry == null || !_fresh(entry)) return null;
    final photo = _photos.remove(id);
    if (photo != null) {
      _photos[id] = photo;
      _files.remove(id);
      _files[id] = entry;
    }
    return photo;
  }

  bool isFresh(String id) =>
      _account != null && _files[id] != null && _fresh(_files[id]!);

  double? cachedAspectRatio(String id) =>
      isFresh(id) ? _files[id]?.aspectRatio : null;

  Future<CachedPhoto> photo(String id) {
    final ready = peekPhoto(id);
    if (ready != null) return Future.value(ready);
    final pending = _photoLoads[id];
    if (pending != null) return pending;
    late final Future<CachedPhoto> operation;
    operation = _photo(id).whenComplete(() {
      if (identical(_photoLoads[id], operation)) _photoLoads.remove(id);
    });
    return _photoLoads[id] = operation;
  }

  Future<CachedPhoto> _photo(String id) async {
    final generation = _generation;
    await _seeds[id];
    _check(generation);
    final seeded = peekPhoto(id);
    if (seeded != null) return seeded;
    final cached = await file(id, category: MediaCategory.photos);
    final entry = _files[id];
    final bytes = await cached.readAsBytes();
    _check(generation);
    if (entry == null || !identical(_files[id], entry)) {
      throw StateError('Image unavailable.');
    }
    try {
      return await _rememberPhoto(id, bytes, generation, entry);
    } catch (_) {
      if (identical(_files[id], entry)) invalidate(id);
      rethrow;
    }
  }

  Future<CachedPhoto> _rememberPhoto(
    String id,
    Uint8List bytes,
    int generation,
    _MediaFile entry,
  ) async {
    final photo = await CachedPhoto.decode(bytes);
    _check(generation);
    if (!identical(_files[id], entry)) throw StateError('Image unavailable.');
    entry.aspectRatio = photo.aspectRatio;
    while (_photos.isNotEmpty &&
        (_photoBytes + bytes.length > maxPhotoBytes ||
            _photos.length >= maxEntries)) {
      final victim = _photos.remove(_photos.keys.first)!;
      _photoBytes -= victim.bytes.length;
      _later(victim.evict());
    }
    if (bytes.length <= maxPhotoBytes) {
      _photos[id] = photo;
      _photoBytes += bytes.length;
    }
    return photo;
  }

  Future<void> seedPhoto(String id, Uint8List bytes) {
    final pending = _seeds[id];
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _seedPhoto(id, bytes).whenComplete(() {
      if (identical(_seeds[id], operation)) _seeds.remove(id);
    });
    return _seeds[id] = operation;
  }

  Future<void> _seedPhoto(String id, Uint8List bytes) async {
    final generation = _generation;
    _check(generation);
    if (bytes.length > maxFileBytes || bytes.length > maxDiskBytes) return;
    if (peekPhoto(id) != null ||
        _downloads.containsKey(id) ||
        _clearing.contains(id)) {
      return;
    }
    final folder = await _cacheFolder();
    _check(generation);
    final file = await File(
      '${folder.path}/${base64Url.encode(utf8.encode(id))}-${_serial++}.media',
    ).writeAsBytes(bytes, flush: true);
    try {
      _check(generation);
      final old = _files[id];
      if (old != null) _removeStored(id);
      final entry = _MediaFile(
        file,
        bytes.length,
        _now(),
        MediaCategory.photos,
      );
      _files[id] = entry;
      _diskBytes += bytes.length;
      _storageChanged();
      await _rememberPhoto(id, bytes, generation, entry);
      _prune(protect: id);
    } catch (_) {
      if (generation == _generation && _files[id]?.file.path == file.path) {
        _removeStored(id);
      }
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    clear();
    _account = null;
    await _cleanup;
    await _changes.close();
    await _storageChanges.close();
  }
}
