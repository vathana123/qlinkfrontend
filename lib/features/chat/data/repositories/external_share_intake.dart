import 'dart:async';

import 'package:flutter/services.dart';

import '../models/share_draft.dart';

/// Android retains its private copies until the preview is cancelled or the
/// outbox has retained them. No authentication information crosses this channel.
class ExternalShareIntake {
  ExternalShareIntake({this.channel = const MethodChannel('qlink/share')});
  final MethodChannel channel;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  void start() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'available') _changes.add(null);
    });
  }

  Future<ShareDraft?> pending() async {
    try {
      final value = await channel.invokeMapMethod<Object?, Object?>('pending');
      return value == null ? null : ShareDraft.fromPlatform(value);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return const ShareDraft(
        error: 'Unable to read the shared content. Please share it again.',
      );
    }
  }

  Future<void> discard(String? id) async {
    if (id == null) return;
    try {
      await channel.invokeMethod<void>('discard', id);
    } on PlatformException {
      /* Temporary cache is also evicted natively. */
    }
  }

  Future<void> dispose() async {
    channel.setMethodCallHandler(null);
    await _changes.close();
  }
}
