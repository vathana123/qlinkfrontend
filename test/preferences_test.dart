import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qlinkfrontend/app/theme/theme_cubit.dart';
import 'package:qlinkfrontend/core/storage/token_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('theme defaults to system; persists and restores each choice', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cubit = ThemeCubit(prefs);
    expect(cubit.state, ThemeMode.system);
    for (final mode in ThemeMode.values) {
      await cubit.setTheme(mode);
      expect(cubit.state, mode);
      expect(prefs.getString(ThemeCubit.preferenceKey), mode.name);
      final restored = ThemeCubit(prefs);
      expect(restored.state, mode);
      await restored.close();
    }
    await cubit.close();
  });
  test('unknown theme preference falls back to system', () async {
    SharedPreferences.setMockInitialValues({
      ThemeCubit.preferenceKey: 'invalid',
    });
    final cubit = ThemeCubit(await SharedPreferences.getInstance());
    expect(cubit.state, ThemeMode.system);
    await cubit.close();
  });
  test('rapid theme selections persist the final choice', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cubit = ThemeCubit(prefs);
    await Future.wait([
      cubit.setTheme(ThemeMode.dark),
      cubit.setTheme(ThemeMode.light),
    ]);
    expect(prefs.getString(ThemeCubit.preferenceKey), 'light');
    expect(cubit.state, ThemeMode.light);
    await cubit.close();
  });
  test(
    'secure token pair round trip and deletion leaves preferences untouched',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({
        ThemeCubit.preferenceKey: 'dark',
      });
      final storage = TokenStorage();
      expect(await storage.read(), null);
      await storage.write(const TokenPair('access', 'refresh'));
      expect((await storage.read())?.accessToken, 'access');
      expect((await storage.read())?.refreshToken, 'refresh');
      await storage.clear();
      expect(await storage.read(), null);
      expect((await SharedPreferences.getInstance()).getKeys(), {
        ThemeCubit.preferenceKey,
      });
    },
  );
  for (final malformed in ['invalid json', '[]', '{"accessToken":"access"}']) {
    test('malformed secure session is cleared: $malformed', () async {
      FlutterSecureStorage.setMockInitialValues({TokenStorage.key: malformed});
      expect(await TokenStorage().read(), null);
      expect(
        await const FlutterSecureStorage().read(key: TokenStorage.key),
        null,
      );
    });
  }
}
