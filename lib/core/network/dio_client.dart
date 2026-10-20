import 'package:dio/dio.dart';

import '../storage/token_storage.dart';
import '../config/app_config.dart';
import 'auth_interceptor.dart';

class DioClient {
  DioClient(TokenStorage storage, {Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              contentType: Headers.jsonContentType,
              headers: {'Accept': Headers.jsonContentType},
            ),
          ) {
    auth = AuthInterceptor(this.dio, storage);
    this.dio.interceptors.add(auth);
  }
  final Dio dio;
  late final AuthInterceptor auth;
}
