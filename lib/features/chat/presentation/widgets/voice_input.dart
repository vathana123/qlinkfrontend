import 'dart:async';
import 'dart:math' as math;

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
    this.attachmentButton,
    this.recorder,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool busy;
  final Widget? attachmentButton;
  final VoiceRecorderCubit? recorder;
  @override
  State<VoiceInput> createState() => _VoiceInputState();
}

class _VoiceInputState extends State<VoiceInput> with WidgetsBindingObserver {
  late final VoiceRecorderCubit recorder =
      widget.recorder ?? VoiceRecorderCubit();
  bool _finishing = false, _cancelling = false;

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

  Future<void> _cancel() async {
    if (_cancelling || _finishing) return;
    setState(() => _cancelling = true);
    await recorder.cancel();
    if (mounted) setState(() => _cancelling = false);
  }

  Future<void> finish() async {
    if (_finishing || _cancelling || widget.busy) return;
    final chat = context.read<ChatCubit>();
    setState(() => _finishing = true);
    try {
      final result = await recorder.finish();
      if (result != null) unawaited(chat.sendVoice(result.$1, result.$2));
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => BlocBuilder<VoiceRecorderCubit, RecordingState>(
    bloc: recorder,
    builder: (context, state) {
      final colors = Theme.of(context).colorScheme;
      final recording = state.phase == RecordingPhase.recording;
      final recordingMode =
          recording ||
          state.phase == RecordingPhase.starting ||
          state.phase == RecordingPhase.stopping ||
          _cancelling;
      final busy = widget.busy || _finishing || _cancelling;
      final seconds = state.elapsedMs ~/ 1000;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(state.error!, style: TextStyle(color: colors.error)),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: recordingMode
                ? [
                    IconButton.filledTonal(
                      tooltip: 'Cancel recording',
                      style: IconButton.styleFrom(
                        backgroundColor: colors.errorContainer,
                        foregroundColor: colors.onErrorContainer,
                      ),
                      onPressed: busy || state.phase == RecordingPhase.stopping
                          ? null
                          : _cancel,
                      icon: const Icon(Icons.delete_outline),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Semantics(
                        label: 'Recording voice message',
                        child: ExcludeSemantics(
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.circle,
                                  size: 10,
                                  color: colors.error,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final count = (constraints.maxWidth / 8)
                                          .floor()
                                          .clamp(1, 32);
                                      // Decorative animation: the recorder exposes no amplitude stream.
                                      return Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: List.generate(count, (index) {
                                          final wave = math
                                              .sin(
                                                state.elapsedMs / 180 +
                                                    index * .9,
                                              )
                                              .abs();
                                          return AnimatedContainer(
                                            duration: const Duration(
                                              milliseconds: 100,
                                            ),
                                            width: 3,
                                            height: recording
                                                ? 6 + wave * 26
                                                : 6,
                                            decoration: BoxDecoration(
                                              color: colors.error,
                                              borderRadius:
                                                  BorderRadius.circular(3),
                                            ),
                                          );
                                        }),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                      semanticsLabel: 'Recording duration $seconds seconds',
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Send voice message',
                      onPressed: recording && !busy ? finish : null,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ]
                : [
                    if (widget.attachmentButton != null)
                      widget.attachmentButton!,
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 4000,
                        decoration: InputDecoration(
                          hintText: 'Enter message...',
                          counterText: '',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        textCapitalization: TextCapitalization.sentences,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: widget.controller,
                      builder: (context, value, _) {
                        final typing = value.text.trim().isNotEmpty;
                        return IconButton.filled(
                          tooltip: typing ? 'Send message' : 'Start recording',
                          onPressed: busy
                              ? null
                              : typing
                              ? widget.onSend
                              : () {
                                  FocusScope.of(context).unfocus();
                                  unawaited(recorder.start());
                                },
                          icon: Icon(typing ? Icons.send_rounded : Icons.mic),
                        );
                      },
                    ),
                  ],
          ),
        ],
      );
    },
  );
}
