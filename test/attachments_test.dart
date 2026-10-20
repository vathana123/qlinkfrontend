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

  testWidgets('File bubble shows filename size and upload progress', (
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
    expect(find.text('Uploading 50%'), findsOneWidget);
  });
}
