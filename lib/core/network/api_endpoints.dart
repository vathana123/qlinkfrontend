abstract final class ApiEndpoints {
  static const signIn = '/api/v1/auth/signin';
  static const signUp = '/api/v1/auth/signup';
  static const refresh = '/api/v1/auth/refresh';
  static const signOut = '/api/v1/auth/signout';
  static const me = '/api/v1/auth/me';
  static const nonce = '/api/v1/auth/nonce';
  static const publicPaths = {signIn, signUp, refresh, nonce};
  static Map<String, dynamic> data(dynamic body) {
    if (body is! Map || body['success'] != true || body['data'] is! Map) {
      throw const FormatException('Invalid API response');
    }
    return Map<String, dynamic>.from(body['data'] as Map);
  }
}
