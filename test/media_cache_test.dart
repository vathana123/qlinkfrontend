import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:just_audio/just_audio.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/private_media_cache.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/voice_playback_controller.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/attachment_bubble.dart';
import 'package:qlinkfrontend/core/network/auth_interceptor.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';

import 'support/fakes.dart';
import 'support/media.dart';
import 'voice_test.dart' show FakePlayer;

class BrokenVoicePlayer extends FakePlayer {
  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    throw StateError('Invalid voice file');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qlink-media-test-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'background pause prevents a pending download from starting playback',
    () async {
      final responseReady = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) => responseReady.future);
      final cache = PrivateMediaCache(
        Dio()..httpClientAdapter = adapter,
        directory: () async => directory,
      )..setAccount('alice');
      final playback = VoicePlaybackController(cache);
      final player = FakePlayer();
      final message = ChatMessage(
        id: 'voice',
        senderId: 'sender',
        clientMessageId: 'voice',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'VOICE',
        fileId: 'voice',
        durationMs: 1000,
      );
      final pending = playback.toggle(message, createPlayer: () => player);
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await playback.pause();
      responseReady.complete(ResponseBody.fromBytes([1, 2, 3], 200));
      await pending;
      expect(player.active, isFalse);
      expect(player.loads, 0);
      expect(playback.forFile('voice').loading, isFalse);
      await playback.toggle(message, createPlayer: () => player);
      expect(player.active, isTrue);
      expect(adapter.requests, hasLength(1));
      await playback.close();
      await cache.dispose();
    },
  );

  test(
    'media uses authenticated Dio refresh without persisting credentials',
    () async {
      final tokens = MemoryTokens()
        ..tokens = const TokenPair('expired-access', 'refresh-token');
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
      dio.options.extra['authenticatedAccountId'] = 'alice';
      dio.interceptors.add(AuthInterceptor(dio, tokens));
      final adapter = FakeAdapter((request) {
        if (request.path.endsWith('/refresh')) {
          return response(
            envelope({
              'accessToken': 'fresh-access',
              'refreshToken': 'fresh-refresh',
            }),
          );
        }
        if (request.headers['Authorization'] == 'Bearer expired-access') {
          return response({}, status: 401);
        }
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });
      dio.httpClientAdapter = adapter;
      final cache = PrivateMediaCache(dio, directory: () async => directory)
        ..setAccount('alice');
      final saved = await cache.file('voice');
      expect(tokens.tokens!.accessToken, 'fresh-access');
      expect(
        adapter.requests.where((request) => request.path.endsWith('/refresh')),
        hasLength(1),
      );
      await cache.file('voice');
      expect(adapter.requests, hasLength(3));
      expect(await saved.readAsBytes(), [1, 2, 3]);
      expect(saved.path, isNot(contains('access')));
      expect(saved.path, isNot(contains('refresh')));
      await cache.dispose();
    },
  );

  testWidgets('account switch clears mounted local previews', (tester) async {
    final bytes = img.encodePng(img.Image(width: 20, height: 10));
    final local = File('${directory.path}/sender-preview.png')
      ..writeAsBytesSync(bytes);
    final adapter = FakeAdapter((_) => ResponseBody.fromBytes([], 403));
    final repository = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
      mediaDirectory: () async => directory,
    )..setAccount('alice');
    final message = ChatMessage(
      id: 'photo',
      senderId: 'alice',
      clientMessageId: 'photo',
      content: '',
      createdAt: DateTime.utc(2026),
      type: 'IMAGE',
      fileId: 'photo',
      localPath: local.path,
    );
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: repository,
        child: MaterialApp(
          home: Scaffold(body: AttachmentBubble(message: message)),
        ),
      ),
    );
    await pumpMedia(tester, () => repository.media.peekPhoto('photo') != null);
    expect(find.byType(Image), findsOneWidget);
    repository.setAccount('bob');
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(repository.media.peekPhoto('photo'), isNull);
    expect(adapter.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await runMediaTask(tester, repository.dispose);
  });

  test('concurrent photo requests share a download, bytes, dimensions and bounded image providers', () async {
    final bytes = img.encodePng(img.Image(width: 100, height: 1200));
    final adapter = FakeAdapter((_) => ResponseBody.fromBytes(bytes, 200));
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final photos = await Future.wait(
      List.generate(8, (_) => cache.photo('photo')),
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.extra['expectedAccountId'], 'alice');
    expect(photos.every((photo) => identical(photo, photos.first)), isTrue);
    expect(cache.peekPhoto('photo'), same(photos.first));
    expect(photos.first.aspectRatio, 1 / 12);
    final provider = photos.first.thumbnail as ResizeImage;
    expect(provider.width, 640);
    expect(provider.height, 720);
    expect(provider.policy, ResizeImagePolicy.fit);
    expect(provider.allowUpscaling, isFalse);
    await cache.photo('photo');
    expect(adapter.requests, hasLength(1));
    await cache.dispose();
  });

  test(
    'encoded memory eviction reuses disk and retains the original aspect ratio',
    () async {
      final bytes = img.encodePng(img.Image(width: 40, height: 20));
      final adapter = FakeAdapter((_) => ResponseBody.fromBytes(bytes, 200));
      final cache = PrivateMediaCache(
        Dio()..httpClientAdapter = adapter,
        directory: () async => directory,
        maxPhotoBytes: bytes.length,
      )..setAccount('alice');
      await cache.photo('a');
      await cache.photo('b');
      expect(cache.peekPhoto('a'), isNull);
      expect(cache.cachedAspectRatio('a'), 2);
      expect(cache.photoBytes, lessThanOrEqualTo(bytes.length));
      final restored = await cache.photo('a');
      expect(restored.width, 40);
      expect(restored.height, 20);
      expect(adapter.requests, hasLength(2));
      await cache.dispose();
    },
  );

  test(
    'disk LRU, TTL and missing files evict safely and permit fresh downloads',
    () async {
      var clock = DateTime.utc(2026);
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes([1, 2, 3], 200),
      );
      final cache = PrivateMediaCache(
        Dio()..httpClientAdapter = adapter,
        directory: () async => directory,
        maxDiskBytes: 6,
        now: () => clock,
      )..setAccount('alice');
      await cache.file('a');
      await cache.file('b');
      await cache.file('a');
      await cache.file('c');
      expect(cache.entryCount, 2);
      expect(cache.diskBytes, 6);
      await cache.file('a');
      expect(adapter.requests, hasLength(3));
      await cache.file('b');
      expect(adapter.requests, hasLength(4));
      clock = clock.add(const Duration(minutes: 16));
      final expired = await cache.file('b');
      expect(adapter.requests, hasLength(5));
      await expired.delete();
      await cache.file('b');
      expect(adapter.requests, hasLength(6));
      await cache.dispose();
    },
  );

  test('failed, truncated and oversized downloads are not cached and can be retried', () async {
    int status = 404, size = 3;
    bool truncated = false;
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        List.filled(size, 1),
        status,
        headers: truncated
            ? {
                'content-length': ['8'],
              }
            : {},
      ),
    );
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
      maxFileBytes: 6,
    )..setAccount('alice');
    await expectLater(cache.file('file'), throwsA(isA<DioException>()));
    status = 200;
    truncated = true;
    await expectLater(cache.file('file'), throwsStateError);
    truncated = false;
    size = 7;
    await expectLater(cache.file('file'), throwsStateError);
    expect(cache.entryCount, 0);
    size = 3;
    expect(await (await cache.file('file')).length(), 3);
    expect(adapter.requests, hasLength(4));
    await cache.dispose();
  });

  test('logout/account switching cancels late work and never reuses another account file', () async {
    final delayed = Completer<ResponseBody>();
    final adapter = FakeAdapter(
      (request) => request.extra['expectedAccountId'] == 'alice'
          ? delayed.future
          : ResponseBody.fromBytes([9, 8, 7], 200),
    );
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final stale = cache.file('shared-id');
    final rejected = expectLater(
      stale,
      throwsA(anyOf(isA<DioException>(), isA<StateError>())),
    );
    while (adapter.requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    cache.setAccount('bob');
    final bob = await cache.file('shared-id');
    delayed.complete(ResponseBody.fromBytes([1, 2, 3], 200));
    await rejected;
    expect(await bob.readAsBytes(), [9, 8, 7]);
    expect(adapter.requests, hasLength(2));
    cache.setAccount(null);
    expect(() => cache.file('shared-id'), throwsStateError);
    expect(cache.entryCount, 0);
    await cache.dispose();
    expect(await bob.exists(), isFalse);
  });

  test('membership/deletion invalidation and terminal authentication failures clear private media', () async {
    int status = 200;
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes([1, 2, 3], status),
    );
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    cache.track('a', 'message', 'group');
    await cache.file('a');
    cache.invalidateMessage('message');
    expect(cache.entryCount, 0);
    cache.track('a', 'message', 'group');
    await cache.file('a');
    cache.invalidateRoom('group');
    expect(cache.entryCount, 0);
    await cache.file('a');
    status = 401;
    await expectLater(cache.file('other'), throwsA(isA<DioException>()));
    expect(cache.entryCount, 0);
    await cache.dispose();
  });

  test('one shared voice player retains source/position on pause and clears on account switch', () async {
    final adapter = FakeAdapter((_) => ResponseBody.fromBytes([1, 2, 3], 200));
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final playback = VoicePlaybackController(cache);
    final player = FakePlayer(length: const Duration(seconds: 10));
    ChatMessage voice(String id) => ChatMessage(
      id: id,
      senderId: 'sender',
      clientMessageId: id,
      content: '',
      createdAt: DateTime.utc(2026),
      type: 'VOICE',
      fileId: id,
      durationMs: 10000,
    );
    await playback.toggle(voice('a'), createPlayer: () => player);
    player.positions.add(const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
    await playback.toggle(voice('a'));
    await playback.toggle(voice('a'));
    expect(player.loads, 1);
    expect((player.source as UriAudioSource).uri.scheme, 'file');
    expect((player.source as UriAudioSource).uri.path, endsWith('.wav'));
    expect(adapter.requests, hasLength(1));
    expect(playback.forFile('a').position, const Duration(seconds: 3));
    await playback.toggle(voice('b'));
    expect(playback.forFile('a').playing, isFalse);
    expect(playback.forFile('b').playing, isTrue);
    expect(player.loads, 2);
    cache.setAccount('bob');
    expect(playback.forFile('b').playing, isFalse);
    expect(playback.forFile('a').position, Duration.zero);
    await playback.close();
    await cache.dispose();
    expect(player.released, isTrue);
  });

  test('downloads are limited to four concurrent requests', () async {
    var active = 0, maximum = 0;
    final gate = Completer<void>();
    final adapter = FakeAdapter((_) async {
      active++;
      if (active > maximum) maximum = active;
      await gate.future;
      active--;
      return ResponseBody.fromBytes([1, 2, 3], 200);
    });
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final downloads = List.generate(10, (index) => cache.file('file-$index'));
    while (adapter.requests.length < 4) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(adapter.requests, hasLength(4));
    gate.complete();
    await Future.wait(downloads);
    expect(maximum, 4);
    await cache.dispose();
  });

  test('invalid audio is evicted and retry creates a usable source', () async {
    final adapter = FakeAdapter((_) => ResponseBody.fromBytes([1, 2, 3], 200));
    final cache = PrivateMediaCache(
      Dio()..httpClientAdapter = adapter,
      directory: () async => directory,
    )..setAccount('alice');
    final playback = VoicePlaybackController(cache);
    final bad = BrokenVoicePlayer(), good = FakePlayer();
    final message = ChatMessage(
      id: 'voice',
      senderId: 'sender',
      clientMessageId: 'voice',
      content: '',
      createdAt: DateTime.utc(2026),
      type: 'VOICE',
      fileId: 'voice',
      durationMs: 1000,
    );
    await playback.toggle(message, createPlayer: () => bad);
    expect(playback.forFile('voice').error, isNotNull);
    expect(cache.entryCount, 0);
    await playback.toggle(message, createPlayer: () => good);
    expect(playback.forFile('voice').playing, isTrue);
    expect(adapter.requests, hasLength(2));
    await playback.close();
    await cache.dispose();
  });

  testWidgets(
    'disposed photo rows return immediately with the same dimensions and no new GET',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 120, height: 1200));
      final adapter = FakeAdapter((_) => ResponseBody.fromBytes(bytes, 200));
      final repository = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        mediaDirectory: () async => directory,
      )..setAccount('alice');
      await runMediaTask(tester, () async {
        await repository.media.photo('photo');
      });
      final scroll = ScrollController();
      final message = ChatMessage(
        id: 'photo',
        senderId: 'sender',
        clientMessageId: 'photo',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'IMAGE',
        fileId: 'photo',
      );
      await tester.pumpWidget(
        RepositoryProvider.value(
          value: repository,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 400,
                child: ListView.builder(
                  controller: scroll,
                  itemCount: 40,
                  itemBuilder: (_, index) => SizedBox(
                    height: 400,
                    child: index == 0
                        ? AttachmentBubble(message: message)
                        : Text('row $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await runMediaTask(
        tester,
        () => precacheImage(
          repository.media.peekPhoto('photo')!.thumbnail,
          tester.element(find.byType(Image)),
        ),
      );
      final decoded = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(decoded.width, lessThanOrEqualTo(640));
      expect(decoded.height, lessThanOrEqualTo(720));
      expect(decoded.width / decoded.height, closeTo(.1, .002));
      final original = tester.element(find.byType(AttachmentBubble));
      final size = tester.getSize(find.byType(Image));
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(original.mounted, isFalse);
      scroll.jumpTo(0);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.getSize(find.byType(Image)), size);
      expect(adapter.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await runMediaTask(tester, repository.dispose);
      scroll.dispose();
    },
  );
}
