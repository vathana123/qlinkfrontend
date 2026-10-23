import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qlinkfrontend/features/chat/data/datasources/attachment_picker.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/chat_api.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';
import 'package:qlinkfrontend/features/chat/data/repositories/chat_repository.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/attachment_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/bloc/chat_cubit.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/attachment_button.dart';
import 'package:qlinkfrontend/features/chat/presentation/widgets/attachment_bubble.dart';

import 'support/fakes.dart';

import 'package:qlinkfrontend/features/auth/data/models/app_user.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/chat/presentation/screens/chat_screen.dart';
import 'package:qlinkfrontend/features/chat/data/realtime/chat_event.dart';

class MediaAuth extends AuthBloc {
  MediaAuth() : super(AuthRepository(Dio(), MemoryTokens(), FakeOAuth()));
  void account(String? id) => emit(
    id == null
        ? const AuthUnauthenticated()
        : AuthAuthenticated(AppUser(id: id, displayName: id, status: 'ACTIVE')),
  );
}

class FakePicker extends AttachmentPicker {
  List<XFile> files = [];
  final prepared = <AttachmentSource>[];
  @override
  Future<List<XFile>> pick(AttachmentSource source) async => files;
  @override
  Future<PreparedAttachment> prepare(
    XFile file,
    AttachmentSource source,
    int maxBytes,
    Map<String, dynamic> extensions,
  ) async {
    prepared.add(source);
    return PreparedAttachment(
      file.path,
      AttachmentMetadata(file.name, 'image/jpeg', await file.length()),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('row identity uses sender/client IDs and falls back to server ID', () {
    ChatMessage message(String id, String sender, String client) => ChatMessage(
      id: id,
      senderId: sender,
      clientMessageId: client,
      content: '',
      createdAt: DateTime.utc(2026),
    );
    expect(
      chatMessageKey(message('temporary', 'me', 'client')),
      chatMessageKey(message('server', 'me', 'client')),
    );
    expect(
      chatMessageKey(message('server', 'me', 'client')),
      isNot(chatMessageKey(message('server', 'other', 'client'))),
    );
    expect(
      chatMessageKey(message('server', 'me', '')),
      chatMessageKey(message('server', 'me', '')),
    );
    expect(
      chatMessageKey(message('server', 'me', '')),
      isNot(chatMessageKey(message('different', 'me', ''))),
    );
  });
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('qlink-attachments-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('Photo compression resizes, respects EXIF orientation and preserves original', () async {
    final random = Random(42);
    final photo = img.Image(width: 1900, height: 900);
    for (final pixel in photo) {
      pixel.setRgb(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
    photo.exif.imageIfd.orientation = 6;
    final original = img.encodeJpg(photo, quality: 96);
    final file = await File('${temp.path}/original.jpg').writeAsBytes(original);
    final picker = AttachmentPicker(temporaryDirectory: () async => temp);
    final result = await picker.prepare(
      XFile(file.path),
      AttachmentSource.photo,
      25000000,
      {'jpg': 'image/jpeg'},
    );
    expect(await file.readAsBytes(), original);
    final compressed = img.decodeJpg(await File(result.path).readAsBytes())!;
    expect(max(compressed.width, compressed.height), 1600);
    expect(compressed.height, greaterThan(compressed.width));
    expect(result.metadata.sizeBytes, lessThan(original.length));
    expect(result.path, isNot(file.path));
  });
  test(
    'Image, Document and Downloads preserve exact bytes and filenames',
    () async {
      final original = img.encodeJpg(img.Image(width: 1800, height: 800));
      final file = await File('${temp.path}/original.jpg')
          .writeAsBytes(original);
      final picker = AttachmentPicker(temporaryDirectory: () async => temp);
      for (final source in [
        AttachmentSource.image,
        AttachmentSource.document,
        AttachmentSource.downloads,
      ]) {
        final result = await picker.prepare(
          XFile(file.path),
          source,
          25000000,
          {'jpg': 'image/jpeg'},
        );
        expect(await File(result.path).readAsBytes(), original);
        expect(result.metadata.originalName, 'original.jpg');
        expect(result.metadata.sizeBytes, original.length);
        expect(result.path, isNot(file.path));
      }
    },
  );
  test(
    'Small photos, animated/unsupported formats and invalid sizes are safe',
    () async {
      final file = await File('${temp.path}/small.jpg')
          .writeAsBytes(img.encodeJpg(img.Image(width: 10, height: 10)));
      expect(compressPhoto(file.path), file.path);
      final gif = await File('${temp.path}/animation.gif')
          .writeAsString('GIF89a');
      expect(compressPhoto(gif.path), gif.path);
      final picker = AttachmentPicker(temporaryDirectory: () async => temp);
      await expectLater(
        picker.prepare(XFile(file.path), AttachmentSource.image, 1, {
          'jpg': 'image/jpeg',
        }),
        throwsStateError,
      );
      await expectLater(
        picker.prepare(XFile(gif.path), AttachmentSource.downloads, 100, {}),
        throwsStateError,
      );
    },
  );
  test('Upload failure and lost send response retry without duplicate message or re-upload', () async {
    var failUpload = true, failSend = true, uploads = 0;
    final keys = <String>[];
    final metadata = {
      'originalName': 'notes.txt',
      'contentType': 'text/plain',
      'sizeBytes': 5,
    };
    final adapter = FakeAdapter((request) {
      if (request.path.endsWith('/policy')) {
        return response(
          envelope({
            'maxSizeBytes': 1000,
            'extensions': {'txt': 'text/plain'},
          }),
        );
      }
      if (request.path == '/api/v1/storage/files') {
        uploads++;
        if (failUpload) return response({}, status: 503);
        return response(envelope({'id': 'remote-file'}));
      }
      final body = request.data as Map;
      keys.add(body['clientMessageId'] as String);
      expect(body['type'], 'FILE');
      expect(body['fileId'], 'remote-file');
      if (failSend) return response({}, status: 503);
      return response(
        envelope({
          'room': {'id': 'room'},
          'message': {
            'id': 'saved',
            'senderId': 'me',
            'clientMessageId': body['clientMessageId'],
            'type': 'FILE',
            'fileId': 'remote-file',
            'content': '',
            'attachment': metadata,
            'createdAt': '2026-10-19T00:00:00Z',
          },
        }),
      );
    });
    final repository = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
    );
    const conversation = Conversation(
      PublicUser('other', 'Other'),
      roomId: 'room',
    );
    var cubit = ChatCubit(repository, conversation, 'me');
    final file = await File('${temp.path}/notes.txt').writeAsString('Hello');
    expect(
      await cubit.sendAttachment(
        file.path,
        AttachmentMetadata.fromJson(metadata),
      ),
      isFalse,
    );
    expect(await file.exists(), isTrue);
    failUpload = false;
    expect(await cubit.retry(cubit.state.messages.single), isFalse);
    expect(cubit.state.messages.single.fileId, 'remote-file');
    await cubit.close();
    cubit = ChatCubit(repository, conversation, 'me');
    failSend = false;
    expect(await cubit.retry(cubit.state.messages.single), isTrue);
    expect(uploads, 2);
    expect(keys.toSet(), hasLength(1));
    expect(cubit.state.messages, hasLength(1));
    expect(cubit.state.messages.single.attachment!.originalName, 'notes.txt');
    expect(await file.exists(), isFalse);
    await cubit.close();
  });
  test('Selection cancellation sends nothing; multiple photos wait for confirmation', () async {
    final picker = FakePicker();
    final adapter = FakeAdapter(
      (_) => response(
        envelope({
          'maxSizeBytes': 1000,
          'extensions': {'jpg': 'image/jpeg'},
        }),
      ),
    );
    final chat = ChatCubit(
      ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter)),
      const Conversation(PublicUser('other', 'Other'), roomId: 'room'),
      'me',
    );
    final cubit = AttachmentCubit(chat, picker: picker);
    await cubit.pick(AttachmentSource.photo);
    expect(cubit.state.files, isEmpty);
    picker.files = [XFile('a.jpg'), XFile('b.jpg')];
    await cubit.pick(AttachmentSource.photo);
    expect(cubit.state.files, hasLength(2));
    expect(picker.prepared, isEmpty);
    expect(adapter.requests, isEmpty);
    cubit.cancel();
    expect(cubit.state.files, isEmpty);
    await cubit.close();
    await chat.close();
  });

  test(
    'Confirmed multiple photos upload and send sequentially through ChatCubit',
    () async {
      final picker = FakePicker();
      for (var i = 0; i < 2; i++) {
        final file = await File('${temp.path}/photo$i.jpg')
            .writeAsBytes([1, 2, 3]);
        picker.files.add(XFile(file.path));
      }
      var uploads = 0;
      final adapter = FakeAdapter((request) {
        if (request.path.endsWith('/policy')) {
          return response(
            envelope({
              'maxSizeBytes': 1000,
              'extensions': {'jpg': 'image/jpeg'},
            }),
          );
        }
        if (request.path == '/api/v1/storage/files') {
          return response(envelope({'id': 'file${++uploads}'}));
        }
        final body = request.data as Map;
        return response(
          envelope({
            'room': {'id': 'room'},
            'message': {
              'id': 'saved$uploads',
              'senderId': 'me',
              'clientMessageId': body['clientMessageId'],
              'type': body['type'],
              'fileId': body['fileId'],
              'content': '',
              'attachment': {
                'originalName': 'photo.jpg',
                'contentType': 'image/jpeg',
                'sizeBytes': 3,
              },
              'createdAt': '2026-10-19T00:00:00Z',
            },
          }),
        );
      });
      final chat = ChatCubit(
        ChatRepository(ChatApi(Dio()..httpClientAdapter = adapter)),
        const Conversation(PublicUser('other', 'Other'), roomId: 'room'),
        'me',
      );
      final cubit = AttachmentCubit(chat, picker: picker);
      await cubit.pick(AttachmentSource.photo);
      await cubit.confirm(cubit.state.files);
      expect(picker.prepared, [AttachmentSource.photo, AttachmentSource.photo]);
      expect(uploads, 2);
      expect(chat.state.messages, hasLength(2));
      expect(
        chat.state.messages.every(
          (m) => m.type == 'IMAGE' && m.delivery == Delivery.sent,
        ),
        isTrue,
      );
      await cubit.close();
      await chat.close();
    },
  );

  testWidgets(
    'Photo selection shows checkboxes and Done; cancellation never uploads',
    (tester) async {
      final picker = FakePicker()
        ..files = [XFile('first.jpg'), XFile('second.jpg')];
      final chat = ChatCubit(
        ChatRepository(ChatApi(Dio())),
        const Conversation(PublicUser('other', 'Other')),
        'me',
      );
      await tester.pumpWidget(
        BlocProvider.value(
          value: chat,
          child: MaterialApp(
            home: Scaffold(body: AttachmentButton(busy: false, picker: picker)),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      expect(find.text('Done (2)'), findsOneWidget);
      await tester.tap(find.text('second.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('Done (1)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(picker.prepared, isEmpty);
      expect(chat.state.messages, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(chat.close);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('Four vertical attachment options in $brightness', (
      tester,
    ) async {
      final chat = ChatCubit(
        ChatRepository(ChatApi(Dio())),
        const Conversation(PublicUser('other', 'Other')),
        'me',
      );
      await tester.pumpWidget(
        BlocProvider.value(
          value: chat,
          child: MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const Scaffold(body: AttachmentButton(busy: false)),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      var previous = -1.0;
      for (final label in ['Photo', 'Image', 'Document', 'Downloads']) {
        expect(find.text(label), findsOneWidget);
        final y = tester.getCenter(find.text(label)).dy;
        expect(y, greaterThan(previous));
        previous = y;
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(chat.close);
    });
  }

  testWidgets('Image preview downloads through Dio and opens full screen', (
    tester,
  ) async {
    final bytes = img.encodePng(img.Image(width: 20, height: 10));
    final adapter = FakeAdapter(
      (request) => ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      ),
    );
    final repository = ChatRepository(
      ChatApi(Dio()..httpClientAdapter = adapter),
    );
    final message = ChatMessage(
      id: 'image',
      senderId: 'other',
      clientMessageId: 'image',
      content: '',
      createdAt: DateTime.now(),
      type: 'IMAGE',
      fileId: 'remote-image',
      attachment: AttachmentMetadata('photo.png', 'image/png', bytes.length),
    );
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: repository,
        child: MaterialApp(
          home: Scaffold(body: AttachmentBubble(message: message)),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(
      adapter.requests.single.path,
      '/api/v1/storage/files/remote-image/download',
    );
    expect(find.byType(Image), findsOneWidget);
    await tester.runAsync(
      () => precacheImage(
        tester.widget<Image>(find.byType(Image)).image,
        tester.element(find.byType(Image)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('photo.png'), findsOneWidget);
  });

  testWidgets(
    'chat insertions and progress preserve photos; account changes discard them',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 20, height: 10));
      final events = StreamController<ChatEvent>.broadcast();
      final photo = ChatMessage(
        id: 'saved-photo',
        senderId: 'other',
        clientMessageId: 'photo-key',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'IMAGE',
        fileId: 'photo-file',
        attachment: AttachmentMetadata('photo.png', 'image/png', bytes.length),
      );
      final adapter = FakeAdapter((request) {
        if (request.path.endsWith('/download')) {
          return ResponseBody.fromBytes(bytes, 200);
        }
        if (request.method == 'POST') {
          final body = request.data as Map;
          return response(
            envelope({
              'room': {
                'id': 'room',
                'participant': {'id': 'other', 'displayName': 'Other'},
              },
              'message': {
                'id': 'saved-text',
                'senderId': 'me',
                'clientMessageId': body['clientMessageId'],
                'content': body['content'],
                'type': 'TEXT',
                'createdAt': '2026-10-20T00:00:00Z',
              },
            }),
          );
        }
        return response(envelope({'items': [], 'nextCursor': null}));
      });
      final repository = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
        events: events.stream,
      );
      final auth = MediaAuth()..account('me');
      await tester.pumpWidget(
        RepositoryProvider.value(
          value: repository,
          child: BlocProvider<AuthBloc>.value(
            value: auth,
            child: const MaterialApp(
              home: ChatScreen(
                conversation: Conversation(
                  PublicUser('other', 'Other'),
                  roomId: 'room',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      events.add(ChatEvent('photo-event', 'room', 'PERSONAL', photo));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final original = tester.state(find.byType(AttachmentBubble));
      final chat = tester
          .element(find.byType(AttachmentBubble))
          .read<ChatCubit>();
      await tester.runAsync(() => chat.send('sent text'));
      await tester.pumpAndSettle();
      events.add(
        ChatEvent(
          'text-event',
          'room',
          'PERSONAL',
          ChatMessage(
            id: 'received-text',
            senderId: 'other',
            clientMessageId: 'received-key',
            content: 'received text',
            createdAt: DateTime.utc(2026, 10, 20, 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final progress in [.1, .5, .9]) {
        // Exercise the same state shape emitted by upload progress without uploading.
        // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
        chat.emit(
          ChatState(
            roomId: 'room',
            sending: true,
            messages: [
              ChatMessage(
                id: 'upload',
                senderId: 'me',
                clientMessageId: 'upload',
                content: '',
                createdAt: DateTime.utc(2026, 10, 20, 2),
                type: 'FILE',
                delivery: Delivery.sending,
                uploadProgress: progress,
              ),
              ...chat.state.messages.where((m) => m.id != 'upload'),
            ],
          ),
        );
        await tester.pump();
      }
      expect(
        tester.state(
          find.byWidgetPredicate(
            (w) => w is AttachmentBubble && w.message.type == 'IMAGE',
          ),
        ),
        same(original),
      );
      expect(
        adapter.requests.where((r) => r.path.endsWith('/download')),
        hasLength(1),
      );
      expect(chat.state.messages.map((m) => m.id), [
        'upload',
        'saved-text',
        'received-text',
        'saved-photo',
      ]);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.reverse, isTrue);
      final scroll = list.controller!;
      scroll.jumpTo(20);
      await tester.pump();
      expect(scroll.offset, 20);
      auth.account('second-account');
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentBubble), findsNothing);
      expect(original.mounted, isFalse);
      events.add(ChatEvent('photo-event', 'room', 'PERSONAL', photo));
      await tester.pumpAndSettle();
      expect(
        adapter.requests.where((r) => r.path.endsWith('/download')),
        hasLength(2),
      );
      auth.account(null);
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentBubble), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await events.close();
        await auth.close();
      });
    },
  );

  testWidgets(
    'photo confirmation retains local bytes and ignores stale downloads',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 20, height: 10));
      final local = File('${temp.path}/preview.png')..writeAsBytesSync(bytes);
      final pending = Completer<ResponseBody>();
      var fail = false;
      final adapter = FakeAdapter(
        (request) => fail
            ? ResponseBody.fromBytes([], 503)
            : request.path.contains('/stale/')
            ? pending.future
            : ResponseBody.fromBytes(bytes, 200),
      );
      final repository = ChatRepository(
        ChatApi(Dio()..httpClientAdapter = adapter),
      );
      ChatMessage photo({
        String id = 'temporary',
        String? file,
        String? path,
        Delivery delivery = Delivery.sent,
      }) => ChatMessage(
        id: id,
        senderId: 'me',
        clientMessageId: 'stable',
        content: '',
        createdAt: DateTime.utc(2026),
        type: 'IMAGE',
        fileId: file,
        localPath: path,
        delivery: delivery,
        attachment: AttachmentMetadata('photo.png', 'image/png', bytes.length),
      );
      Future<void> show(ChatMessage message) async {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            RepositoryProvider.value(
              value: repository,
              child: MaterialApp(
                home: Scaffold(
                  body: AttachmentBubble(
                    key: chatMessageKey(message),
                    message: message,
                  ),
                ),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump();
          final images = tester.widgetList<Image>(find.byType(Image));
          final ready = images.any((image) {
            final provider = image.image;
            return provider is MemoryImage ||
                provider is ResizeImage &&
                    provider.imageProvider is MemoryImage;
          });
          if (ready ||
              find
                  .text('Image unavailable. Tap to retry.')
                  .evaluate()
                  .isNotEmpty ||
              (message.delivery == Delivery.sending &&
                  message.localPath == null) ||
              (message.fileId == 'stale' &&
                  adapter.requests.any((r) => r.path.contains('/stale/')))) {
            return;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        throw StateError('Image did not reach the expected loading state');
      }

      await show(photo(path: local.path, delivery: Delivery.sending));
      await tester.pumpAndSettle();
      final original = tester.state(find.byType(AttachmentBubble));
      final provider = tester.widget<Image>(find.byType(Image)).image;
      local.deleteSync();
      await show(photo(id: 'server', file: 'confirmed'));
      expect(tester.state(find.byType(AttachmentBubble)), same(original));
      expect(tester.widget<Image>(find.byType(Image)).image, provider);
      expect(adapter.requests, isEmpty);
      await show(photo(id: 'server', file: 'stale'));
      for (
        var attempt = 0;
        attempt < 100 &&
            !adapter.requests.any((r) => r.path.contains('/stale/'));
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(adapter.requests.any((r) => r.path.contains('/stale/')), isTrue);
      await show(photo(id: 'server', file: 'replacement'));
      final replacement = tester.widget<Image>(find.byType(Image)).image;
      pending.complete(ResponseBody.fromBytes([0], 200));
      await tester.pumpAndSettle();
      expect(tester.widget<Image>(find.byType(Image)).image, replacement);
      expect(find.text('Image unavailable. Tap to retry.'), findsNothing);
      expect(adapter.requests, hasLength(2));
      fail = true;
      await show(photo(id: 'server', file: 'retry'));
      expect(find.text('Image unavailable. Tap to retry.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Image unavailable. Tap to retry.'));
      await tester.pumpAndSettle();
      expect(find.text('Image unavailable. Tap to retry.'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(adapter.requests, hasLength(4));
      await tester.pumpWidget(const SizedBox());
      await show(photo(delivery: Delivery.sending));
      expect(adapter.requests, hasLength(4));
      await show(photo(id: 'server', file: 'confirmed-without-local-preview'));
      expect(adapter.requests, hasLength(5));
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    for (final portrait in [true, false]) {
      testWidgets(
        'Photo keeps aspect ratio ($brightness, portrait=$portrait)',
        (tester) async {
          final bytes = img.encodePng(
            img.Image(
              width: portrait ? 100 : 400,
              height: portrait ? 400 : 100,
            ),
          );
          final adapter = FakeAdapter(
            (_) => ResponseBody.fromBytes(bytes, 200),
          );
          final repository = ChatRepository(
            ChatApi(Dio()..httpClientAdapter = adapter),
          );
          final photo = ChatMessage(
            id: 'photo',
            senderId: 'other',
            clientMessageId: 'photo',
            content: '',
            createdAt: DateTime.utc(2026),
            type: 'IMAGE',
            fileId: 'file',
          );
          await tester.pumpWidget(
            RepositoryProvider.value(
              value: repository,
              child: MaterialApp(
                theme: ThemeData(brightness: brightness),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: 240,
                      child: AttachmentBubble(message: photo),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
          final image = tester.widget<Image>(find.byType(Image));
          expect(image.fit, BoxFit.contain);
          final size = tester.getSize(find.byType(Image));
          expect(size.width, lessThanOrEqualTo(240));
          expect(size.height, lessThanOrEqualTo(360));
          expect(size.width / size.height, closeTo(portrait ? .25 : 4, .01));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(repository.dispose);
        },
      );
    }
  }

  testWidgets('File bubble shows filename and size without sending progress', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'a',
      senderId: 'me',
      clientMessageId: 'a',
      content: '',
      createdAt: DateTime.now(),
      type: 'FILE',
      delivery: Delivery.sending,
      uploadProgress: .5,
      attachment: const AttachmentMetadata(
        'report.pdf',
        'application/pdf',
        2048,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AttachmentBubble(message: message)),
      ),
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('Uploading 50%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
