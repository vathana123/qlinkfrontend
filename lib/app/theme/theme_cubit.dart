import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeCubit extends Cubit<ThemeMode> {
  ThemeCubit(this._preferences) : super(_read(_preferences));
  final SharedPreferences _preferences;
  static const preferenceKey = 'qlink.theme';
  static ThemeMode _read(SharedPreferences preferences) =>
      switch (preferences.getString(preferenceKey)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
  Future<void> setTheme(ThemeMode mode) async {
    // Emit immediately; enqueue writes in selection order.
    emit(mode);
    _pending = _pending.catchError((Object _) {}).then((_) async {
      if (!await _preferences.setString(preferenceKey, mode.name)) {
        throw StateError('Theme could not be saved');
      }
    });
    await _pending;
  }

  Future<void> _pending = Future.value();
}
