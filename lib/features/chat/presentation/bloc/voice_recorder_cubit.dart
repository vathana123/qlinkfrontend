import 'dart:async';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

enum RecordingPhase { idle, starting, recording, stopping, failed }

class RecordingState {
  const RecordingState(this.phase, {this.elapsedMs = 0, this.error});
  final RecordingPhase phase;
  final int elapsedMs;
  final String? error;
}

abstract class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start(String path);
  Future<String?> stop();
  Future<void> cancel();
  Future<void> dispose();
  Stream<RecordState> get changes;
}

class DeviceVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _instance;
  AudioRecorder get _recorder => _instance ??= AudioRecorder();
  @override
  Future<bool> hasPermission() => _recorder.hasPermission();
  @override
  Stream<RecordState> get changes => _recorder.onStateChanged();
  @override
  Future<void> start(String path) => _recorder.start(
    const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
    ),
    path: path,
  );
  @override
  Future<String?> stop() => _recorder.stop();
  @override
  Future<void> cancel() async {
    await _instance?.cancel();
  }

  @override
  Future<void> dispose() async {
    await _instance?.dispose();
  }
}

class VoiceRecorderCubit extends Cubit<RecordingState> {
  VoiceRecorderCubit({
    VoiceRecorder? recorder,
    Future<String> Function()? pathFactory,
  }) : recorder = recorder ?? DeviceVoiceRecorder(),
       pathFactory = pathFactory ?? _newPath,
       super(const RecordingState(RecordingPhase.idle));
  final VoiceRecorder recorder;
  final Future<String> Function() pathFactory;
  static Future<String> _newPath() async {
    final directory = await getTemporaryDirectory();
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    await for (final entry in directory.list()) {
      if (entry is File &&
          entry.uri.pathSegments.last.startsWith('qlink-voice-') &&
          entry.path.endsWith('.wav')) {
        try {
          if ((await entry.lastModified()).isBefore(cutoff)) {
            await entry.delete();
          }
        } catch (_) {}
      }
    }
    return '${directory.path}/qlink-voice-${const Uuid().v4()}.wav';
  }

  Timer? _timer;
  StreamSubscription<RecordState>? _changes;
  final _watch = Stopwatch();
  bool _held = false, _disposed = false;
  Future<void>? _starting;
  String? _path;
  void _state(RecordingState value) {
    if (!isClosed && !_disposed) emit(value);
  }

  Future<void> start() {
    if (state.phase == RecordingPhase.starting ||
        state.phase == RecordingPhase.recording ||
        state.phase == RecordingPhase.stopping) {
      return Future.value();
    }
    _held = true;
    return _starting = _start();
  }

  Future<void> _start() async {
    _state(const RecordingState(RecordingPhase.starting));
    try {
      if (!await recorder.hasPermission()) {
        throw StateError(
          'Microphone permission is required. Enable it in Settings.',
        );
      }
      if (!_held || _disposed) return;
      _path = await pathFactory();
      if (!_held || _disposed) return;
      await recorder.start(_path!);
      if (!_held || _disposed) {
        await recorder.cancel();
        return;
      }
      await _changes?.cancel();
      _changes = recorder.changes.listen((value) {
        if (state.phase == RecordingPhase.recording &&
            value != RecordState.record) {
          unawaited(cancel());
        }
      });
      _watch
        ..reset()
        ..start();
      _state(const RecordingState(RecordingPhase.recording));
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (_watch.elapsedMilliseconds >= 120000) {
          unawaited(cancel());
          return;
        }
        _state(
          RecordingState(
            RecordingPhase.recording,
            elapsedMs: _watch.elapsedMilliseconds,
          ),
        );
      });
    } catch (e) {
      _held = false;
      try {
        await recorder.cancel();
      } catch (_) {}
      _state(
        RecordingState(
          RecordingPhase.failed,
          error: e is StateError
              ? e.message.toString()
              : 'Unable to start recording.',
        ),
      );
    }
  }

  Future<(String, int)?> finish() async {
    if (!_held) return null;
    _held = false;
    if (state.phase == RecordingPhase.starting) {
      await _starting;
      await cancel();
      return null;
    }
    if (state.phase != RecordingPhase.recording) return null;
    _timer?.cancel();
    _watch.stop();
    _state(const RecordingState(RecordingPhase.stopping));
    try {
      final path = await recorder.stop();
      final duration = _watch.elapsedMilliseconds;
      if (path == null ||
          _disposed ||
          duration < 300 ||
          duration > 120000 ||
          await File(path).length() > 4000000) {
        await _remove();
        _state(const RecordingState(RecordingPhase.idle));
        return null;
      }
      _path = null;
      _state(const RecordingState(RecordingPhase.idle));
      return (path, duration);
    } catch (_) {
      await _remove();
      _state(
        const RecordingState(
          RecordingPhase.failed,
          error: 'Unable to finalize recording.',
        ),
      );
      return null;
    }
  }

  Future<void> _remove() async {
    final path = _path;
    _path = null;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<void> cancel() async {
    _held = false;
    _timer?.cancel();
    _watch.stop();
    await _starting;
    try {
      await recorder.cancel();
    } catch (_) {}
    await _remove();
    _state(const RecordingState(RecordingPhase.idle));
  }

  @override
  Future<void> close() async {
    _disposed = true;
    await cancel();
    await _changes?.cancel();
    await recorder.dispose();
    return super.close();
  }
}
