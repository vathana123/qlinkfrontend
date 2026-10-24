import 'dart:io';

import 'package:dio/dio.dart';

import '../../../../core/network/api_endpoints.dart';
import '../../../../core/error/app_exception.dart';

class ChatApi {
  ChatApi(this.dio);
  final Dio dio;
  Future<Map<String, dynamic>> uploadPolicy({CancelToken? cancelToken}) async =>
      ApiEndpoints.data(
        (await dio.get<dynamic>(
          '/api/v1/storage/files/policy',
          cancelToken: cancelToken,
        )).data,
      );
  Future<String> uploadAttachment(
    String path,
    String name,
    String mime,
    void Function(int, int) progress, {
    CancelToken? cancelToken,
  }) async {
    final response = await dio.post<dynamic>(
      '/api/v1/storage/files',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(
          path,
          filename: name,
          contentType: DioMediaType.parse(mime),
        ),
      }),
      onSendProgress: progress,
      cancelToken: cancelToken,
    );
    return ApiEndpoints.data(response.data)['id'] as String;
  }

  Future<String> uploadVoice(
    String path,
    void Function(int, int) progress, {
    CancelToken? cancelToken,
  }) async {
    final response = await dio.post<dynamic>(
      '/api/v1/storage/files',
      data: FormData.fromMap({
        'category': 'AUDIO',
        'voice': 'true',
        'file': await MultipartFile.fromFile(path, filename: 'voice.wav'),
      }),
      options: Options(contentType: 'multipart/form-data'),
      onSendProgress: progress,
      cancelToken: cancelToken,
    );
    return ApiEndpoints.data(response.data)['id'] as String;
  }

  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) async => ApiEndpoints.data(
    (await dio.get<dynamic>('/api/v1/$path', queryParameters: query)).data,
  );
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    CancelToken? cancelToken,
  }) async => ApiEndpoints.data(
    (await dio.post<dynamic>(
      '/api/v1/$path',
      data: body,
      cancelToken: cancelToken,
    )).data,
  );
  Future<Map<String, dynamic>> username(String name) async => ApiEndpoints.data(
    (await dio.patch<dynamic>(
      '/api/v1/users/me/username',
      data: {'username': name},
    )).data,
  );
}

String chatError(Object error) {
  if (error is DioException) {
    if (error.error is AppException) {
      return (error.error! as AppException).message;
    }
    final data = error.response?.data;
    final status = error.response?.statusCode;
    // Only short, user-facing client-error responses; never expose server traces.
    if (status != null &&
        status >= 400 &&
        status < 500 &&
        data is Map &&
        data['message'] is String) {
      final message = (data['message'] as String).trim();
      if (message.isNotEmpty &&
          message.length <= 200 &&
          !RegExp(
            r'Bearer |eyJ|Exception|StackTrace|\bat\s+\w+\.',
            caseSensitive: false,
          ).hasMatch(message)) {
        return message;
      }
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'Connection timeout. Please retry.',
      DioExceptionType.connectionError => 'Network unavailable. Please retry.',
      DioExceptionType.cancel => 'Sending cancelled.',
      _ => 'Request failed. Please retry.',
    };
  }
  if (error is FileSystemException) {
    return 'Local file unavailable. Please select it again.';
  }
  if (error is StateError) return error.message.toString();
  return 'Unable to connect. Please try again.';
}
