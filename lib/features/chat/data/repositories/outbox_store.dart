import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

abstract class OutboxStore {
  Future<List<Map<String, dynamic>>> read(String account);
  Future<void> write(String account, List<Map<String, dynamic>> jobs);
  Future<String> retain(String account, String id, String path);
}

/// Injectable session store for tests and embedded clients.
class MemoryOutboxStore implements OutboxStore {
  final _data = <String, String>{};
  @override
  Future<List<Map<String, dynamic>>> read(String account) async =>
      ((jsonDecode(_data[account] ?? '[]')) as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList();
  @override
  Future<void> write(String account, List<Map<String, dynamic>> jobs) async {
    _data[account] = jsonEncode(jobs);
  }

  @override
  Future<String> retain(String account, String id, String path) async => path;
}

class SecureOutboxStore implements OutboxStore {
  SecureOutboxStore({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? directory,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _directory = directory ?? getApplicationSupportDirectory;
  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _directory;
  String _key(String account) =>
      'qlink.outbox.v1.${base64Url.encode(utf8.encode(account))}';
  @override
  Future<List<Map<String, dynamic>>> read(String account) async {
    final raw = await _storage.read(key: _key(account));
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((j) => Map<String, dynamic>.from(j as Map))
        .toList();
  }

  @override
  Future<void> write(String account, List<Map<String, dynamic>> jobs) =>
      _storage.write(key: _key(account), value: jsonEncode(jobs));
  @override
  Future<String> retain(String account, String id, String path) async {
    final root = await _directory();
    final folder = Directory(
      '${root.path}/outbox/${base64Url.encode(utf8.encode(account))}',
    );
    await folder.create(recursive: true);
    final target = '${folder.path}/${base64Url.encode(utf8.encode(id))}.media';
    if (File(path).absolute.path == File(target).absolute.path) return path;
    // Rename only after the complete copy is durable. Source picker files are never moved.
    final temporary = await File(path).copy('$target.tmp');
    await temporary.rename(target);
    return target;
  }
}
