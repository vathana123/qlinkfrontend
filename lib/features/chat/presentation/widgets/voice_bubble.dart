import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';

class VoiceBubble extends StatelessWidget {
  const VoiceBubble({
    super.key,
    required this.message,
    this.roomId,
    this.createPlayer,
  });
  final AudioPlayer Function()? createPlayer;
  final ChatMessage message;
  final String? roomId;

  @override
  Widget build(BuildContext context) {
    final playback = context.read<ChatRepository>().voicePlayback;
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final state = playback.forFile(message.fileId);
        final duration = state.duration > Duration.zero
            ? state.duration.inMilliseconds
            : message.durationMs ?? 0;
        final seconds = (duration / 1000).ceil();
        return SizedBox(
          width: 220,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: state.playing
                        ? 'Pause voice message'
                        : 'Play voice message',
                    onPressed: !message.isConfirmed || state.loading
                        ? null
                        : () => playback.toggle(
                            message,
                            roomId: roomId,
                            createPlayer: createPlayer,
                          ),
                    icon: state.loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(state.playing ? Icons.pause : Icons.play_arrow),
                  ),
                  if (message.isConfirmed)
                    Expanded(
                      child: LinearProgressIndicator(
                        value:
                            (state.position.inMilliseconds /
                                    (duration > 0 ? duration : 1))
                                .clamp(0, 1),
                      ),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                  ),
                ],
              ),
              if (state.error != null)
                Text(
                  state.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        );
      },
    );
  }
}
