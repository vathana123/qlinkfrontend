abstract final class AppConfig {
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );

  // Optional native client ID for the existing iOS/macOS flow.
  static const String googleClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
  );

  static String socketUrl([String base = apiBaseUrl]) {
    final uri = Uri.parse(base);
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError('API_BASE_URL must be an HTTP(S) origin');
    }
    return Uri(
      scheme: uri.scheme == 'https' ? 'wss' : 'ws',
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/ws',
    ).toString();
  }

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );
}
