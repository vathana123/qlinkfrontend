import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/app.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:qlinkfrontend/core/network/api_endpoints.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:qlinkfrontend/features/user/presentation/bloc/profile_cubit.dart';
import 'package:qlinkfrontend/features/chat/data/datasources/attachment_picker.dart';
import 'package:qlinkfrontend/features/chat/data/models/chat_models.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'profile edits retain form on conflict, publish changes and preserve Home rooms',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      var current = Map<String, dynamic>.from(userJson);
      var rooms = 0;
      var conflict = true;
      client.dio.httpClientAdapter = FakeAdapter((r) {
        if (r.path == ApiEndpoints.me) return response(envelope(current));
        if (r.path == '/api/v1/chat/rooms') {
          rooms++;
          return response(envelope({'content': <Object>[], 'last': true}));
        }
        if (r.path == ProfileCubit.path && r.method == 'PATCH') {
          if (conflict) {
            return response({
              'success': false,
              'message': 'This username is already taken',
            }, status: 409);
          }
          current = {...current, ...Map<String, dynamic>.from(r.data as Map)};
          return response(envelope(current));
        }
        return response(envelope(null));
      });
      final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
      await tester.pumpWidget(
        QLinkApp(
          auth: auth,
          theme: ThemeCubit(await SharedPreferences.getInstance()),
        ),
      );
      auth.add(const AuthStarted());
      await tester.pumpAndSettle();
      final initialRooms = rooms;
      expect(find.text('Maya Chen'), findsOneWidget);
      await tester.tap(find.byTooltip('Your profile'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Edit profile'));
      await tester.tap(find.text('Edit profile'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'New Name');
      await tester.enterText(find.byType(TextFormField).at(1), 'new_name');
      await tester.scrollUntilVisible(
        find.text('Save profile'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(find.text('This username is already taken'), findsOneWidget);
      expect(find.text('New Name'), findsOneWidget);
      conflict = false;
      await tester.scrollUntilVisible(
        find.text('Save profile'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(auth.state.user?.displayName, 'New Name');
      expect(auth.state.user?.username, 'new_name');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Messages'), findsOneWidget);
      expect(rooms, initialRooms);
      expect(find.text('New Name'), findsOneWidget);
      expect(find.text('@new_name'), findsOneWidget);
      expect(find.byTooltip('Search users'), findsOneWidget);
      expect(find.byTooltip('Scan QR code'), findsOneWidget);
      expect(find.byTooltip('More options'), findsOneWidget);
      await tester.tap(find.text('New Name'));
      await tester.pumpAndSettle();
      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'duplicate profile saves are ignored while a request is pending',
    () async {
      final storage = MemoryTokens()
        ..tokens = const TokenPair('access', 'refresh');
      final client = DioClient(storage);
      final pending = Completer<void>();
      var writes = 0;
      final started = Completer<void>();
      client.dio.httpClientAdapter = FakeAdapter((r) async {
        if (r.method == 'PATCH') {
          writes++;
          started.complete();
          await pending.future;
        }
        return response(envelope(userJson));
      });
      final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
      auth.add(const AuthStarted());
      await auth.stream.firstWhere((state) => state is AuthAuthenticated);
      final cubit = ProfileCubit(auth);
      final first = cubit.save('Name', 'name');
      await cubit.save('Name', 'name');
      await started.future;
      expect(writes, 1);
      pending.complete();
      await first;
      expect(cubit.state.saved, isTrue);
      await cubit.close();
      await auth.close();
    },
  );
  test('avatar upload failure retains bytes for retry; removal and refresh publish authoritative data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qlink-profile-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/avatar.png')
        .writeAsBytes([1, 2, 3]);
    final image = PreparedAttachment(
      file.path,
      const AttachmentMetadata('avatar.png', 'image/png', 3),
    );
    final storage = MemoryTokens()
      ..tokens = const TokenPair('access', 'refresh');
    final client = DioClient(storage);
    var current = Map<String, dynamic>.from(userJson);
    var failUpload = true;
    var uploads = 0;
    client.dio.httpClientAdapter = FakeAdapter((r) {
      if (r.method == 'PUT') {
        uploads++;
        if (failUpload) {
          return response({'message': 'Storage unavailable'}, status: 503);
        }
        current = {
          ...current,
          'avatarUrl': '/api/v1/storage/files/11111111-1111-1111-1111-111111111111/download',
        };
      }
      if (r.method == 'DELETE') current = {...current, 'avatarUrl': null};
      return response(envelope(current));
    });
    final auth = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
    auth.add(const AuthStarted());
    await auth.stream.firstWhere((state) => state is AuthAuthenticated);
    final cubit = ProfileCubit(auth);
    await cubit.save('Name', 'name', image: image);
    expect(cubit.state.error, isNotNull);
    expect(await file.exists(), isTrue);
    failUpload = false;
    final changed = auth.stream.firstWhere(
      (state) => state.user?.avatarUrl != null,
    );
    await cubit.save('Name', 'name', image: image);
    await changed;
    expect(uploads, 2);
    final removed = auth.stream.firstWhere(
      (state) => state.user?.avatarUrl == null,
    );
    await cubit.save('Name', 'name', removeAvatar: true);
    await removed;
    current = {...current, 'displayName': 'Changed on another device'};
    final refreshed = auth.stream.firstWhere(
      (state) => state.user?.displayName == 'Changed on another device',
    );
    await cubit.refresh();
    await refreshed;
    await cubit.close();
    await auth.close();
  });
}
