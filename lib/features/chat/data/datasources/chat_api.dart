import 'package:dio/dio.dart';

import '../../../../core/network/api_endpoints.dart';

class ChatApi {
  ChatApi(this.dio);
  final Dio dio;
  Future<String> uploadAttachment(
    String path,
    String name,
    String mime,
    void Function(int, int) progress,
  ) async {
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
    );
    return ApiEndpoints.data(response.data)['id'] as String;
  }

  Future<String> uploadVoice(
    String path,
    void Function(int, int) progress,
  ) async {
    final response = await dio.post<dynamic>(
      '/api/v1/storage/files',
      data: FormData.fromMap({
        'category': 'AUDIO',
        'voice': 'true',
        'file': await MultipartFile.fromFile(path, filename: 'voice.wav'),
      }),
      options: Options(contentType: 'multipart/form-data'),
      onSendProgress: progress,
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
    Map<String, dynamic> body,
  ) async => ApiEndpoints.data(
    (await dio.post<dynamic>('/api/v1/$path', data: body)).data,
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
    final data = error.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
  }
  if (error is StateError) return error.message.toString();
  return 'Unable to connect. Please try again.';
}
