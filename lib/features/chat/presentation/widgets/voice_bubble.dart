// StreamAudioSource is the package-supported adapter for authenticated Dio streaming.
// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';

/// All bytes pass through the existing authenticated Dio instance, including refresh.
/// The storage endpoint streams the file; satisfy player ranges without buffering it.
class VoiceAudioSource extends StreamAudioSource {
  VoiceAudioSource(this.dio, this.message, this.cancelToken);
  final Dio dio;
  final ChatMessage message;
  final CancelToken cancelToken;
  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final response = await dio.get<ResponseBody>(
      '/api/v1/storage/files/${message.fileId}/download',
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancelToken,
    );
    final length = int.parse(response.headers.value('content-length')!);
    final from = (start ?? 0).clamp(0, length);
    final to = (end ?? length).clamp(from, length);
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: to - from,
      offset: from,
      contentType: 'audio/wav',
      stream: _slice(response.data!.stream, from, to),
    );
  }

  Stream<List<int>> _slice(Stream<List<int>> input, int start, int end) async* {
    var offset = 0;
    await for (final chunk in input) {
      final next = offset + chunk.length;
      if (next > start && offset < end) {
        yield chunk.sublist(
          (start - offset).clamp(0, chunk.length),
          (end - offset).clamp(0, chunk.length),
        );
      }
      offset = next;
      if (offset >= end) break;
    }
  }
}

class VoiceBubble extends StatefulWidget {
  const VoiceBubble({super.key, required this.message, this.createPlayer});
  final AudioPlayer Function()? createPlayer;
  final ChatMessage message;
  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> with WidgetsBindingObserver {
  static _VoiceBubbleState? _active;
  late final _player = widget.createPlayer?.call() ?? AudioPlayer();
  CancelToken? _cancel;
  StreamSubscription<PlayerState>? _subscription;
  StreamSubscription<PlayerException>? _errors;
  bool _loading = false, _loaded = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _errors = _player.errorStream.listen((_) {
      if (mounted) {
        setState(() {
          _loaded = false;
          _loading = false;
          _error = 'Audio unavailable. Tap to retry.';
        });
      }
    });
    _subscription = _player.playerStateStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _stop() async {
    _generation++;
    _loaded = false;
    _cancel?.cancel();
    await _player.stop();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop());
  }

  Future<void> _toggle() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }
    final previous = _active;
    _active = this;
    if (previous != null && previous != this) await previous._stop();
    if (!mounted || _active != this) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_loaded) {
        _cancel?.cancel();
        _cancel = CancelToken();
        await _player.setAudioSource(
          VoiceAudioSource(
            context.read<ChatRepository>().api.dio,
            widget.message,
            _cancel!,
          ),
        );
        _loaded = true;
      }
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      if (!mounted || generation != _generation || _active != this) return;
      setState(() => _loading = false);
      await _player.play();
    } catch (_) {
      _loaded = false;
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'Audio unavailable. Tap to retry.';
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_active == this) _active = null;
    _generation++;
    _cancel?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_errors?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final seconds = ((m.durationMs ?? 0) / 1000).ceil();
    return SizedBox(
      width: 220,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: _player.playing
                    ? 'Pause voice message'
                    : 'Play voice message',
                onPressed: m.delivery != Delivery.sent || _loading
                    ? null
                    : _toggle,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_player.playing ? Icons.pause : Icons.play_arrow),
              ),
              Expanded(
                child: StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (context, snapshot) => LinearProgressIndicator(
                    value: m.delivery == Delivery.sending
                        ? m.uploadProgress
                        : ((snapshot.data?.inMilliseconds ?? 0) /
                                  (m.durationMs ?? 1))
                              .clamp(0.0, 1.0),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
              ),
            ],
          ),
          if (m.delivery == Delivery.sending)
            Text(
              m.uploadProgress < 1
                  ? 'Uploading ${(m.uploadProgress * 100).round()}%'
                  : 'Sending…',
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
