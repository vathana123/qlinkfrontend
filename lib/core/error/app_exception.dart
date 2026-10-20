import 'package:dio/dio.dart';

class AppException implements Exception {
  const AppException(this.message, {this.canceled = false});
  final String message;
  final bool canceled;
  static AppException from(Object error) {
    if (error is AppException) return error;
    if (error is DioException) {
      final body = error.response?.data;
      final details = body is Map ? body['data'] : null;
      final code = details is Map ? details['code'] : null;
      return AppException(switch (code) {
        'NOT_REGISTERED' => 'No account found. Create an account first.',
        'ALREADY_REGISTERED' ||
        'CONFLICT' => 'This account already exists. Sign in instead.',
        'INVALID_PROVIDER_TOKEN' =>
          'Your provider could not be verified. Please try again.',
        'INVALID_NONCE' => 'This sign-in attempt expired. Please try again.',
        _ => switch (error.response?.statusCode) {
          401 => 'Your session expired. Please sign in again.',
          403 => 'This account cannot access qLink.',
          429 => 'Too many attempts. Please wait and try again.',
          _ => 'Unable to connect to qLink. Please try again.',
        },
      });
    }
    // Raw platform/network errors can contain credentials.
    return const AppException('Something went wrong. Please try again.');
  }
}
