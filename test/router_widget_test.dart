import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/app.dart';
import 'package:qlinkfrontend/app/router/app_router.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:qlinkfrontend/core/network/api_endpoints.dart';
import 'package:qlinkfrontend/core/network/dio_client.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';
import 'package:qlinkfrontend/features/auth/data/models/app_user.dart';
import 'package:qlinkfrontend/features/auth/data/repositories/auth_repository.dart';
import 'package:qlinkfrontend/features/auth/presentation/bloc/auth_bloc.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final user = AppUser.fromJson(userJson);
  test('redirect table prevents unauthenticated access and loops', () {
    expect(authRedirect(const AuthInitial(), '/chats'), '/startup');
    expect(authRedirect(const AuthInitial(), '/startup'), null);
    for (final path in ['/chats', '/profile', '/profile/edit', '/startup']) {
      expect(authRedirect(const AuthUnauthenticated(), path), '/signin');
    }
    expect(authRedirect(const AuthUnauthenticated(), '/signin'), null);
    expect(authRedirect(const AuthFailure('Error'), '/signup'), null);
    expect(authRedirect(AuthAuthenticated(user), '/signin'), '/chats');
    expect(authRedirect(AuthAuthenticated(user), '/chats'), null);
    expect(authRedirect(AuthLoading(user: user), '/profile'), null);
    expect(authRedirect(const AuthLoading(), '/signup'), null);
  });
  Future<AuthBloc> mount(
    WidgetTester tester, {
    bool signedIn = false,
    ThemeMode mode = ThemeMode.system,
  }) async {
    SharedPreferences.setMockInitialValues({
      ThemeCubit.preferenceKey: mode.name,
    });
    final storage = MemoryTokens();
    if (signedIn) storage.tokens = const TokenPair('access', 'refresh');
    final client = DioClient(storage);
    client.dio.httpClientAdapter = FakeAdapter(
      (r) => response(
        envelope(
          r.path == ApiEndpoints.me
              ? userJson
              : r.path == '/api/v1/chat/rooms'
              ? {'content': <Object>[], 'last': true}
              : null,
        ),
      ),
    );
    final bloc = AuthBloc(AuthRepository(client.dio, storage, FakeOAuth()));
    await tester.pumpWidget(
      QLinkApp(
        auth: bloc,
        theme: ThemeCubit(await SharedPreferences.getInstance()),
      ),
    );
    bloc.add(const AuthStarted());
    await tester.pumpAndSettle();
    return bloc;
  }

  testWidgets('small sign-in and signup layouts support large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await mount(tester);
    expect(find.text('Welcome back'), findsOneWidget);
    await tester.ensureVisible(find.text('Create an account'));
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    expect(find.text('Create your account'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('home, profile, theme and signout work in ${mode.name}', (
      tester,
    ) async {
      await mount(tester, signedIn: true, mode: mode);
      expect(find.text('Messages'), findsOneWidget);
      await tester.tap(find.byTooltip('Your profile'));
      await tester.pumpAndSettle();
      expect(find.text('maya@example.com'), findsOneWidget);
      for (final appearance in ['Dark', 'Light', 'System']) {
        await Scrollable.ensureVisible(
          tester.element(find.text(appearance)),
          alignment: .3,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(appearance));
        await tester.pumpAndSettle();
        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.getString(ThemeCubit.preferenceKey),
          appearance.toLowerCase(),
        );
      }
      await tester.scrollUntilVisible(
        find.text('Sign out'),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Sign out')),
        alignment: .3,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(tester.takeException(), null);
    });
  }
}
