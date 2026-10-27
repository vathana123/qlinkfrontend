import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';

import '../models/chat_models.dart';
import 'private_media_cache.dart';

typedef VoicePlayerFactory = AudioPlayer Function();

class VoicePlaybackState {
  const VoicePlaybackState({
    this.fileId,
    this.loading = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });
  final String? fileId, error;
  final bool loading, playing;
  final Duration position, duration;
}

/// One player per account session. Bubble disposal only removes a listener;
/// it never tears down the active source or loses its position.
class VoicePlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  VoicePlaybackController(this.media) {
    WidgetsBinding.instance.addObserver(this);
    _cacheChanges = media.changes.listen((id) {
      if (id == null || id == _fileId) reset();
      if (id == null) {
        _positions.clear();
      } else {
        _positions.remove(id);
      }
    });
  }
  final PrivateMediaCache media;
  late final StreamSubscription<String?> _cacheChanges;
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _states;
  StreamSubscription<Duration>? _ticks;
  StreamSubscription<PlayerException>? _errors;
  final _positions = <String, (Duration, Duration)>{};
  String? _fileId, _roomId, _error;
  Duration _position = Duration.zero, _duration = Duration.zero;
  bool _loading = false, _loaded = false, _disposed = false;
  int _generation = 0;
  Future<void> _retired = Future.value();

  VoicePlaybackState forFile(String? id) {
    final saved = _positions[id];
    return VoicePlaybackState(
      fileId: id,
      loading: id != null && id == _fileId && _loading,
      playing: id != null && id == _fileId && (_player?.playing ?? false),
      position: id == _fileId ? _position : saved?.$1 ?? Duration.zero,
      duration: id == _fileId ? _duration : saved?.$2 ?? Duration.zero,
      error: id == _fileId ? _error : null,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _remember() {
    final id = _fileId;
    if (id == null) return;
    _positions.remove(id);
    _positions[id] = (_position, _duration);
    while (_positions.length > 128) {
      _positions.remove(_positions.keys.first);
    }
  }

  AudioPlayer _getPlayer(VoicePlayerFactory? factory) {
    if (_player != null) return _player!;
    final player = _player = factory?.call() ?? AudioPlayer();
    _states = player.playerStateStream.listen((_) => _notify());
    _ticks = player.positionStream.listen((position) {
      if (!_loaded) return;
      _position = position;
      _remember();
      _notify();
    });
    _errors = player.errorStream.listen((_) {
      _loaded = _loading = false;
      _error = 'Audio unavailable. Tap to retry.';
      _notify();
    });
    return player;
  }

  Future<void> toggle(
    ChatMessage message, {
    String? roomId,
    VoicePlayerFactory? createPlayer,
  }) async {
    final id = message.fileId;
    if (_disposed ||
        !message.isConfirmed ||
        message.hidden ||
        message.deleted ||
        id == null ||
        media.account == null ||
        (_loading && _fileId == id)) {
      return;
    }
    media.track(id, message.id, roomId);
    final player = _getPlayer(createPlayer);
    if (_fileId == id && player.playing) {
      await player.pause();
      _notify();
      return;
    }
    final request = ++_generation;
    final accountGeneration = media.generation;
    final same = _fileId == id;
    _remember();
    if (!same) {
      await player.pause();
      if (_disposed || request != _generation) return;
      final previous = _fileId;
      _fileId = id;
      if (previous != null) media.unpin(previous);
      _roomId = roomId;
      _position = _positions[id]?.$1 ?? Duration.zero;
      _duration =
          _positions[id]?.$2 ?? Duration(milliseconds: message.durationMs ?? 0);
      _loaded = false;
    }
    if (_loaded && !media.isFresh(id)) _loaded = false;
    _loading = !_loaded;
    _error = null;
    media.pin(id);
    _notify();
    try {
      if (!_loaded) {
        final file = await media.file(id, voice: true);
        if (_disposed ||
            request != _generation ||
            accountGeneration != media.generation) {
          return;
        }
        final duration = await player.setAudioSource(
          AudioSource.uri(Uri.file(file.path)),
          initialPosition: _position,
        );
        if (_disposed ||
            request != _generation ||
            accountGeneration != media.generation) {
          return;
        }
        if (duration != null) _duration = duration;
        _loaded = true;
      }
      if (player.processingState == ProcessingState.completed) {
        _position = Duration.zero;
        await player.seek(Duration.zero);
      }
      if (_disposed ||
          request != _generation ||
          accountGeneration != media.generation) {
        return;
      }
      _loading = false;
      _remember();
      _notify();
      // just_audio's play future completes on pause/end, not when playback starts.
      unawaited(
        player.play().catchError((Object _) {
          if (!_disposed && request == _generation) {
            _failed(id);
          }
        }),
      );
    } catch (_) {
      if (!_disposed &&
          accountGeneration == media.generation &&
          (request == _generation || _fileId == null)) {
        _failed(id);
      }
    }
  }

  void _failed(String id) {
    media.invalidate(id);
    _fileId = id;
    _loaded = _loading = false;
    _error = 'Audio unavailable. Tap to retry.';
    _notify();
  }

  Future<void> pause() async {
    _generation++;
    _loading = false;
    await _player?.pause();
    _remember();
    _notify();
  }

  void pauseRoom(String? id) {
    if (_roomId == id) unawaited(pause());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(pause());
  }

  void reset() {
    _generation++;
    final old = _player;
    _player = null;
    final subscriptions = [
      _states?.cancel(),
      _ticks?.cancel(),
      _errors?.cancel(),
    ];
    _states = null;
    _ticks = null;
    _errors = null;
    final previous = _fileId;
    _fileId = _roomId = _error = null;
    if (previous != null) media.unpin(previous);
    _position = _duration = Duration.zero;
    _loading = _loaded = false;
    _retired = Future.wait<void>([
      _retired,
      ...subscriptions.whereType<Future<void>>(),
      if (old != null) old.dispose(),
    ]).then<void>((_) {}).catchError((Object _) {});
    _notify();
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _cacheChanges.cancel();
    reset();
    _positions.clear();
    await _retired;
    super.dispose();
  }
}
