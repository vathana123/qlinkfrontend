import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../chat/data/datasources/chat_api.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../auth/data/models/app_user.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../chat/data/datasources/attachment_picker.dart';

class ProfileState {
  const ProfileState({this.busy = false, this.error, this.saved = false});
  final bool busy;
  final String? error;
  final bool saved;
}

class ProfileCubit extends Cubit<ProfileState> {
  ProfileCubit(this.auth) : super(const ProfileState());
  final AuthBloc auth;
  static const path = '/api/v1/users/me';
  void publish(AppUser user) => auth.add(AuthProfileUpdated(user));
  Future<void> refresh() async {
    if (state.busy) return;
    emit(const ProfileState(busy: true));
    try {
      final user = await auth.repository.currentUser();
      if (isClosed) return;
      publish(user);
      emit(const ProfileState());
    } catch (error) {
      if (!isClosed) emit(ProfileState(error: chatError(error)));
    }
  }

  Future<void> save(
    String name,
    String username, {
    PreparedAttachment? image,
    bool removeAvatar = false,
  }) async {
    if (state.busy) return;
    emit(const ProfileState(busy: true));
    try {
      final dio = auth.repository.dio;
      var response = await dio.patch<dynamic>(
        path,
        data: {
          'displayName': name.trim(),
          if (username.isNotEmpty || auth.state.user?.username != null)
            'username': username.toLowerCase(),
        },
      );
      publish(AppUser.fromJson(ApiEndpoints.data(response.data)));
      // Separate requests: publish each successful change, keeping the form on any failure.
      if (image != null) {
        response = await dio.put<dynamic>(
          '$path/avatar',
          data: FormData.fromMap({
            'file': await MultipartFile.fromFile(
              image.path,
              filename: image.metadata.originalName,
            ),
          }),
        );
        publish(AppUser.fromJson(ApiEndpoints.data(response.data)));
      } else if (removeAvatar) {
        response = await dio.delete<dynamic>('$path/avatar');
        publish(AppUser.fromJson(ApiEndpoints.data(response.data)));
      }
      if (!isClosed) emit(const ProfileState(saved: true));
    } catch (error) {
      if (!isClosed) emit(ProfileState(error: chatError(error)));
    }
  }

  static Future<void> discard(PreparedAttachment? image) async {
    if (image == null) return;
    try {
      await File(image.path).parent.delete(recursive: true);
    } catch (_) {}
  }
}
