import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/chat_cubit.dart';
import '../bloc/voice_recorder_cubit.dart';

class VoiceInput extends StatefulWidget {
  const VoiceInput({
    super.key,
    required this.controller,
    required this.onSend,
    required this.busy,
    this.recorder,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool busy;
  final VoiceRecorderCubit? recorder;
  @override
  State<VoiceInput> createState() => _VoiceInputState();
}

class _VoiceInputState extends State<VoiceInput> with WidgetsBindingObserver {
  late final VoiceRecorderCubit recorder =
      widget.recorder ?? VoiceRecorderCubit();
  bool cancelled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(recorder.cancel());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(recorder.close());
    super.dispose();
  }

  Future<void> finish() async {
    if (cancelled) return;
    final chat = context.read<ChatCubit>();
    final result = await recorder.finish();
    if (result != null) await chat.sendVoice(result.$1, result.$2);
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<VoiceRecorderCubit, RecordingState>(
        bloc: recorder,
        builder: (context, state) {
          final colors = Theme.of(context).colorScheme;
          final active = state.phase == RecordingPhase.recording;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active)
                Text(
                  '${(state.elapsedMs / 1000).floor()}s',
                  style: TextStyle(color: colors.primary),
                ),
              if (state.error != null)
                Tooltip(
                  message: state.error!,
                  child: Icon(Icons.error_outline, color: colors.error),
                ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (context, value, _) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: value.text.trim().isNotEmpty
                      ? IconButton.filled(
                          key: const ValueKey('send'),
                          tooltip: 'Send message',
                          onPressed: widget.busy ? null : widget.onSend,
                          icon: const Icon(Icons.send_rounded),
                        )
                      : Listener(
                          onPointerCancel: (_) {
                            cancelled = true;
                            unawaited(recorder.cancel());
                          },
                          child: GestureDetector(
                            key: const ValueKey('mic'),
                            onLongPressStart: widget.busy
                                ? null
                                : (_) {
                                    cancelled = false;
                                    unawaited(recorder.start());
                                  },
                            onLongPressMoveUpdate: (event) {
                              if (event.offsetFromOrigin.dx < -70) {
                                cancelled = true;
                                unawaited(recorder.cancel());
                              }
                            },
                            onLongPressEnd: (_) => unawaited(finish()),
                            onLongPressCancel: () =>
                                unawaited(recorder.cancel()),
                            child: Tooltip(
                              triggerMode: TooltipTriggerMode.manual,
                              message: active
                                  ? 'Slide left to cancel'
                                  : 'Hold to record; slide left to cancel',
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: EdgeInsets.all(active ? 16 : 12),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: active
                                      ? colors.errorContainer
                                      : colors.primaryContainer,
                                ),
                                child: Icon(
                                  Icons.mic,
                                  color: active
                                      ? colors.onErrorContainer
                                      : colors.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ],
          );
        },
      );
}
