// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/voice_recorder_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/voice_input.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/voice_bubble.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/chat_screen.dart';

import 'support/fakes.dart';

class FakeRecorder implements VoiceRecorder {
  bool permission = true, disposed = false;
  int starts = 0, cancels = 0;
  Completer<bool>? permissionResult;
  String? path;
  final events = StreamController<RecordState>.broadcast();
  @override
  Stream<RecordState> get changes => events.stream;
  @override
  Future<bool> hasPermission() async =>
      permissionResult == null ? permission : permissionResult!.future;
  @override
  Future<void> start(String path) async {
    starts++;
    this.path = path;
    File(path).writeAsBytesSync(List.filled(100, 0));
  }

  @override
  Future<String?> stop() async => path;
  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await events.close();
  }
}

class ComposerChatCubit extends ChatCubit {
  ComposerChatCubit()
    : super(
        ChatRepository(ChatApi(Dio())),
        const Conversation(PublicUser('other', 'Other'), roomId: 'room'),
        'me',
      );
  final sent = <(String, int)>[];
  @override
  Future<bool> sendVoice(String path, int durationMs) async {
    sent.add((path, durationMs));
    return true;
  }
}

class FakePlayer extends AudioPlayer {
  bool active = false, released = false;
  int loads = 0, stops = 0;
  final updates = StreamController<PlayerState>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  @override
  bool get playing => active;
  @override
  ProcessingState get processingState => ProcessingState.ready;
  @override
  Stream<PlayerState> get playerStateStream => updates.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  void notify() => updates.add(PlayerState(active, ProcessingState.ready));
  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loads++;
    return const Duration(seconds: 1);
  }

  @override
  Future<void> play() async {
    active = true;
    notify();
  }

  @override
  Future<void> pause() async {
    active = false;
    notify();
  }

  @override
  Future<void> stop() async {
    active = false;
    stops++;
    notify();
  }

  @override
  Future<void> dispose() async {
    released = true;
    await super.dispose();
    await updates.close();
    await positions.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('qlink-voice-test');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  test(
    'permission denial, canceled permission request, and disposal never record',
    () async {
      final fake = FakeRecorder()..permission = false;
      final cubit = VoiceRecorderCubit(
        recorder: fake,
        pathFactory: () async => '${temporary.path}/test.wav',
      );
      await cubit.start();
      expect(cubit.state.phase, RecordingPhase.failed);
      expect(fake.starts, 0);
      fake.permissionResult = Completer<bool>();
      final start = cubit.start();
      final cancel = cubit.cancel();
      fake.permissionResult!.complete(true);
      await start;
      await cancel;
      expect(fake.starts, 0);
      expect(await cubit.finish(), isNull);
      await cubit.close();
      expect(fake.disposed, isTrue);
    },
  );
  test(
    'recording cancellation and interruption remove temporary audio',
    () async {
      final fake = FakeRecorder();
      final path = '${temporary.path}/cancel.wav';
      final cubit = VoiceRecorderCubit(
        recorder: fake,
        pathFactory: () async => path,
      );
      await cubit.start();
      expect(cubit.state.phase, RecordingPhase.recording);
      await cubit.cancel();
      expect(await File(path).exists(), isFalse);
      expect(await cubit.finish(), isNull);
      await cubit.start();
      fake.events.add(RecordState.pause);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cubit.state.phase, RecordingPhase.idle);
      await cubit.close();
      expect(fake.disposed, isTrue);
    },
  );
  test(
    'finish finalizes a recording and transfers ownership to send flow',
    () async {
      final fake = FakeRecorder();
      final path = '${temporary.path}/ok.wav';
      final cubit = VoiceRecorderCubit(
        recorder: fake,
        pathFactory: () async => path,
      );
      await cubit.start();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final result = await cubit.finish();
      expect(result?.$1, path);
      expect(result!.$2, greaterThanOrEqualTo(300));
      expect(await cubit.finish(), isNull);
      await cubit.close();
      expect(await File(path).exists(), isTrue);
    },
  );
  test('upload and send failures retain audio, retry reuses uploaded ID and message key', () async {
    var uploadFails = true, sendFails = true, uploads = 0;
    final keys = <String>[];
    final adapter = FakeAdapter((r) {
      if (r.path.endsWith('/storage/files')) {
        uploads++;
        return uploadFails
            ? response({'message': 'upload failed'}, status: 503)
            : response(envelope({'id': 'audio'}));
      }
      final body = r.data as Map;
      keys.add(body['clientMessageId'] as String);
      if (sendFails) return response({'message': 'send failed'}, status: 503);
      return response(
        envelope({
          'room': {
            'id': 'room',
            'participant': {'id': 'other', 'displayName': 'Other'},
          },
          'message': {
            'id': 'saved',
            'senderId': 'me',
            'clientMessageId': body['clientMessageId'],
            'type': 'VOICE',
            'content': '',
            'fileId': body['fileId'],
            'durationMs': 1000,
            'createdAt': '2026-10-19T00:00:00Z',
          },
        }),
      );
    });
    final repository = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
    );
    final conversation = Conversation(
      const PublicUser('other', 'Other'),
      roomId: 'room',
    );
    var cubit = ChatCubit(repository, conversation, 'me');
    final file = await File('${temporary.path}/upload.wav')
        .writeAsBytes(List.filled(100, 0));
    expect(await cubit.sendVoice(file.path, 1000), isFalse);
    expect(await file.exists(), isTrue);
    uploadFails = false;
    expect(await cubit.retry(cubit.state.messages.single), isFalse);
    expect(cubit.state.messages.single.fileId, 'audio');
    expect(uploads, 2);
    await cubit.close();
    cubit = ChatCubit(repository, conversation, 'me');
    expect(cubit.state.messages.single.delivery, Delivery.failed);
    sendFails = false;
    expect(await cubit.retry(cubit.state.messages.single), isTrue);
    expect(uploads, 2);
    expect(keys.toSet(), hasLength(1));
    expect(await file.exists(), isFalse);
    expect(cubit.state.messages.single.isVoice, isTrue);
    await cubit.close();
  });
  for (final brightness in Brightness.values) {
    testWidgets('mic/send switching trims whitespace in $brightness', (
      tester,
    ) async {
      final text = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: VoiceInput(controller: text, onSend: () {}, busy: false),
          ),
        ),
      );
      expect(find.byIcon(Icons.mic), findsOneWidget);
      text.text = '  ';
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.mic), findsOneWidget);
      text.text = 'hello';
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
      text.clear();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.mic), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      text.dispose();
    });
  }
  testWidgets(
    'tapping microphone hides input and Delete cancels without sending',
    (tester) async {
      final fake = FakeRecorder();
      final recorder = VoiceRecorderCubit(
        recorder: fake,
        pathFactory: () async => '${temporary.path}/gesture.wav',
      );
      final text = TextEditingController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: VoiceInput(
                controller: text,
                onSend: () {},
                busy: false,
                recorder: recorder,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Start recording'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(fake.starts, 1);
      expect(recorder.state.phase, RecordingPhase.recording);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Send voice message'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) =>
          widget is Text &&
          widget.semanticsLabel?.startsWith('Recording duration ') == true),
          findsOneWidget);
      await tester.tap(find.byTooltip('Cancel recording'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(recorder.state.phase, RecordingPhase.idle);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      text.dispose();
    },
  );
  testWidgets('composer sends a tapped recording through ChatCubit', (
    tester,
  ) async {
    final fake = FakeRecorder();
    final path = '${temporary.path}/composer.wav';
    final recorder = VoiceRecorderCubit(
      recorder: fake,
      pathFactory: () async => path,
    );
    final chat = ComposerChatCubit();
    final text = TextEditingController();
    await tester.pumpWidget(
      BlocProvider<ChatCubit>.value(
        value: chat,
        child: MaterialApp(
          home: Scaffold(
            body: VoiceInput(
              controller: text,
              onSend: () {},
              busy: false,
              recorder: recorder,
              attachmentButton: const Icon(Icons.add),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(recorder.state.elapsedMs, greaterThanOrEqualTo(1000));
    expect(find.byWidgetPredicate((widget) =>
        widget is Text &&
        widget.semanticsLabel?.startsWith('Recording duration ') == true),
        findsOneWidget);
    await tester.tap(find.byTooltip('Send voice message'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(chat.sent, hasLength(1));
    expect(chat.sent.single.$1, path);
    expect(chat.sent.single.$2, greaterThanOrEqualTo(300));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() => chat.close());
    text.dispose();
  });
  testWidgets(
    'voice bubbles render, pause/resume, stop the previous player and dispose',
    (tester) async {
      final a = FakePlayer(), b = FakePlayer();
      final repo = ChatRepository(ChatApi(Dio()));
      ChatMessage message(String id) => ChatMessage(
        id: id,
        senderId: 'other',
        clientMessageId: id,
        content: '',
        createdAt: DateTime.now(),
        type: 'VOICE',
        fileId: id,
        durationMs: 1000,
      );
      await tester.pumpWidget(
        RepositoryProvider.value(
          value: repo,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  VoiceBubble(message: message('a'), createPlayer: () => a),
                  VoiceBubble(message: message('b'), createPlayer: () => b),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('0:01'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Play voice message').first);
      await tester.pumpAndSettle();
      expect(a.active, isTrue);
      await tester.tap(find.byTooltip('Pause voice message'));
      await tester.pumpAndSettle();
      expect(a.active, isFalse);
      await tester.tap(find.byTooltip('Play voice message').first);
      await tester.pumpAndSettle();
      expect(a.loads, 1);
      await tester.tap(find.byTooltip('Play voice message'));
      await tester.pumpAndSettle();
      expect(a.active, isFalse);
      expect(b.active, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(a.released, isTrue);
      expect(b.released, isTrue);
    },
  );
  testWidgets(
    'playing voice survives row movement and scrolling, then stops on lifecycle and disposal',
    (tester) async {
      final player = FakePlayer();
      final scroll = ScrollController();
      final repo = ChatRepository(ChatApi(Dio()));
      ChatMessage voice(String id) => ChatMessage(
        id: id,
        senderId: 'other',
        clientMessageId: 'stable-voice',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'VOICE',
        fileId: 'voice-file',
        durationMs: 10000,
      );
      var messages = [voice('temporary')];
      Future<void> show() async {
        final indices = {
          for (var i = 0; i < messages.length; i++)
            chatMessageKey(messages[i]): i,
        };
        await tester.pumpWidget(
          RepositoryProvider.value(
            value: repo,
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: 160,
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: messages.length,
                    findChildIndexCallback: (key) => indices[key],
                    itemBuilder: (_, i) => SizedBox(
                      key: chatMessageKey(messages[i]),
                      height: 100,
                      child: messages[i].isVoice
                          ? VoiceBubble(
                              message: messages[i],
                              createPlayer: () => player,
                            )
                          : Text(messages[i].content),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show();
      await tester.tap(find.byTooltip('Play voice message'));
      await tester.pumpAndSettle();
      player.positions.add(const Duration(seconds: 3));
      await tester.pump();
      final original = tester.state(find.byType(VoiceBubble));
      messages = [
        ChatMessage(
          id: 'text',
          senderId: 'me',
          clientMessageId: 'text',
          content: 'new text',
          createdAt: DateTime.utc(2026, 1, 2),
        ),
        voice('server-id'),
      ];
      await show();
      expect(tester.state(find.byType(VoiceBubble)), same(original));
      expect(player.active, isTrue);
      expect(player.loads, 1);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .3,
      );
      messages.addAll(
        List.generate(
          30,
          (i) => ChatMessage(
            id: 'older-$i',
            senderId: 'me',
            clientMessageId: 'older-$i',
            content: 'older message $i',
            createdAt: DateTime.utc(2025),
          ),
        ),
      );
      await show();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(original.mounted, isTrue);
      expect(player.active, isTrue);
      expect(player.released, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(player.active, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(player.released, isTrue);
      scroll.dispose();
    },
  );

  test('playback streams only requested bytes through Dio', () async {
    final adapter = FakeAdapter(
      (r) => ResponseBody(
        Stream.value(Uint8List.fromList([0, 1, 2, 3, 4, 5])),
        200,
        headers: {
          'content-length': ['6'],
        },
      ),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final message = ChatMessage(
      id: 'id',
      senderId: 'other',
      clientMessageId: 'key',
      content: '',
      createdAt: DateTime.now(),
      type: 'VOICE',
      fileId: 'audio',
    );
    final token = CancelToken();
    final source = VoiceAudioSource(dio, message, token);
    final result = await source.request(2, 5);
    expect(await result.stream.expand((v) => v).toList(), [2, 3, 4]);
    expect(result.contentLength, 3);
    expect(
      adapter.requests.single.path,
      '/api/v1/storage/files/audio/download',
    );
    token.cancel();
    expect(token.isCancelled, isTrue);
  });
}
