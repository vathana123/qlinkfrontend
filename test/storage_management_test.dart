import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/private_media_cache.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/voice_playback_controller.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/shared_media_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/shared_media_screen.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/storage_screen.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/chat_info_screen.dart';

import 'privacy_test.dart' show SignedInAuth;
import 'voice_test.dart' show FakePlayer;
import 'support/fakes.dart';
import 'support/media.dart';

Map<String, dynamic> mediaMessage(
  String id, {
  String type = 'IMAGE',
  bool hidden = false,
}) => {
  'id': id,
  'roomId': 'r',
  'senderId': 'peer',
  'clientMessageId': id,
  'content': '',
  'type': type,
  'fileId': 'shared-file',
  'createdAt': '2026-10-28T10:00:00Z',
  'hidden': hidden,
  'attachment': {
    'originalName': 'photo.png',
    'contentType': 'image/png',
    'sizeBytes': 3,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qlink-storage-test-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('storage measurement recovers abandoned sessions without deleting another live cache or account', () async {
    final account = base64Url.encode(utf8.encode('alice'));
    final stale = await File(
      '${directory.path}/qlink-media-v1/$account/session-abandoned/file.media',
    ).create(recursive: true);
    await stale.writeAsBytes([1, 2]);
    final other = await File(
      '${directory.path}/qlink-media-v1/other/session-old/file.media',
    ).create(recursive: true);
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromBytes([3, 4, 5], 200),
      );
    final first = PrivateMediaCache(dio, directory: () async => directory)
      ..setAccount('alice');
    expect((await first.usage()).total, 0);
    expect(await stale.exists(), false);
    final live = await first.file('live');
    final second = PrivateMediaCache(dio, directory: () async => directory)
      ..setAccount('alice');
    await second.usage();
    expect(await live.exists(), true);
    expect(await other.exists(), true);
    await second.dispose();
    await first.dispose();
  });

  test('usage deduplicates forwards; selective clearing preserves outbox and playing audio without server deletes', () async {
    final adapter = FakeAdapter((_) => ResponseBody.fromBytes([1, 2, 3], 200));
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final outbox = await File('${directory.path}/outbox/pending.media')
        .create(recursive: true);
    await outbox.writeAsBytes([8, 9]);
    final photo = img.encodePng(img.Image(width: 20, height: 10));
    await cache.seedPhoto('photo', photo);
    cache.track('photo', 'original', 'room');
    cache.track('photo', 'forward', 'other-room');
    final document = await cache.file('document', filename: 'report.pdf');
    await cache.file('document', filename: 'report.pdf');
    final playback = VoicePlaybackController(cache), player = FakePlayer();
    await playback.toggle(
      ChatMessage(
        id: 'voice',
        senderId: 'peer',
        clientMessageId: 'v',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'VOICE',
        fileId: 'voice',
        durationMs: 1000,
      ),
      createPlayer: () => player,
    );
    var usage = await cache.usage();
    expect(usage[MediaCategory.photos], photo.length);
    expect(usage[MediaCategory.audio], 3);
    expect(usage[MediaCategory.files], 3);
    expect(adapter.requests.length, 2);
    expect(document.path, endsWith('.pdf'));
    await cache.clearCached({MediaCategory.photos});
    expect(cache.peekPhoto('photo'), isNull);
    expect(await document.exists(), true);
    usage = await cache.clearCached(MediaCategory.values.toSet());
    expect(usage.total, 3);
    expect(player.active, true);
    expect(await outbox.readAsBytes(), [8, 9]);
    expect(adapter.requests.every((r) => r.method == 'GET'), true);
    await playback.close();
    expect((await cache.clearCached({MediaCategory.audio})).total, 0);
    await cache.dispose();
  });

  test('pending downloads survive selective cleanup; account switch rejects late media and clears usage', () async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => pending.future);
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final download = cache.file('file');
    while (adapter.requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await cache.clearCached(MediaCategory.values.toSet());
    pending.complete(ResponseBody.fromBytes([1, 2, 3], 200));
    expect(await (await download).readAsBytes(), [1, 2, 3]);
    expect((await cache.usage()).total, 3);
    cache.setAccount('bob');
    expect((await cache.usage()).total, 0);
    expect(adapter.requests.single.extra['expectedAccountId'], 'alice');
    await cache.dispose();
  });

  test('shared-media pagination deduplicates messages, removes hidden media and rejects stale accounts', () async {
    Completer<ResponseBody>? pending;
    final events = StreamController<ChatEvent>.broadcast(sync: true);
    final adapter = FakeAdapter(
      (r) =>
          pending?.future ??
          response(
            envelope({
              'items': r.queryParameters['cursor'] == null
                  ? [mediaMessage('a')]
                  : [mediaMessage('a'), mediaMessage('b')],
              'nextCursor': r.queryParameters['cursor'] == null ? 'next' : null,
            }),
          ),
    );
    final repo = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      events: events.stream,
      mediaDirectory: () async => directory,
    )..setAccount('alice');
    final cubit = SharedMediaCubit(repo, 'r', 'alice');
    await cubit.load();
    await cubit.load();
    expect(cubit.state.items.length, 2);
    expect(cubit.state.hasMore, false);
    events.add(
      ChatEvent(
        'e',
        'r',
        'PERSONAL',
        ChatMessage.fromJson(mediaMessage('a', hidden: true)),
        type: 'MESSAGE_HIDDEN',
      ),
    );
    expect(cubit.state.items.single.id, 'b');
    pending = Completer<ResponseBody>();
    final load = cubit.load(refresh: true);
    await Future<void>.delayed(Duration.zero);
    repo.setAccount('bob');
    pending.complete(
      response(
        envelope({
          'items': [mediaMessage('c')],
        }),
      ),
    );
    await load;
    expect(cubit.state.items, isEmpty);
    expect(cubit.state.unavailable, true);
    await cubit.close();
    await repo.dispose();
    await events.close();
  });

  test(
    'membership revocation cancels pending media and hides existing entries',
    () async {
      final events = StreamController<ChatEvent>.broadcast(sync: true);
      final repo = ChatRepository(
        ChatApi(
          Dio()
            ..httpClientAdapter = FakeAdapter(
              (_) => response(
                envelope({
                  'items': [mediaMessage('a')],
                }),
              ),
            ),
        ),
        events: events.stream,
      )..setAccount('alice');
      final cubit = SharedMediaCubit(repo, 'r', 'alice');
      await cubit.load();
      events.add(
        const ChatEvent('e', 'r', 'GROUP_PRIVATE', null, type: 'GROUP_REMOVED'),
      );
      expect(cubit.state.unavailable, true);
      expect(cubit.state.items, isEmpty);
      await cubit.close();
      await repo.dispose();
      await events.close();
    },
  );

  testWidgets(
    'Chat Info opens Shared Media categories and Storage & Data clears selected files in both themes',
    (tester) async {
      for (final brightness in Brightness.values) {
        final auth = SignedInAuth();
        final adapter = FakeAdapter(
          (r) => r.path.endsWith('/download')
              ? ResponseBody.fromBytes([1, 2, 3], 200)
              : response(envelope({'items': []})),
        );
        final repo = ChatRepository(
          ChatApi(Dio()..httpClientAdapter = adapter),
          mediaDirectory: () async => directory,
        )..setAccount('user-1');
        await runMediaTask(tester, () async {
          await repo.media.file('file');
        });
        final router = GoRouter(
          initialLocation: '/info',
          routes: [
            GoRoute(
              path: '/info',
              builder: (_, _) => const ChatInfoScreen(
                conversation: Conversation(
                  PublicUser('peer', 'Peer'),
                  roomId: 'r',
                ),
              ),
            ),
            GoRoute(
              path: '/rooms/:id/media',
              builder: (_, _) => const SharedMediaScreen(roomId: 'r'),
            ),
            GoRoute(path: '/storage', builder: (_, _) => const StorageScreen()),
          ],
        );
        await tester.pumpWidget(
          RepositoryProvider.value(
            value: repo,
            child: BlocProvider<AuthBloc>.value(
              value: auth,
              child: MaterialApp.router(
                routerConfig: router,
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.blue,
                    brightness: brightness,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Shared Media'));
        await tester.pumpAndSettle();
        expect(find.text('Photos'), findsOneWidget);
        expect(find.text('Voice'), findsOneWidget);
        expect(find.text('Files'), findsOneWidget);
        await tester.tap(find.text('Voice'));
        await tester.pumpAndSettle();
        expect(adapter.requests.last.queryParameters['category'], 'VOICE');
        router.go('/storage');
        await tester.pumpAndSettle();
        await pumpMedia(tester, () => find.text('3 B').evaluate().isNotEmpty);
        await tester.tap(find.text('Clear selected cache'));
        await pumpMedia(tester, () => repo.media.entryCount == 0);
        expect(adapter.requests.any((r) => r.method == 'DELETE'), false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        router.dispose();
        await runMediaTask(tester, repo.dispose);
        await tester.runAsync(auth.close);
      }
    },
  );
}
