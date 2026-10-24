import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/datasources/chat_api.dart';
import '../../data/realtime/chat_event.dart';
import '../../data/realtime/chat_realtime.dart';

class GroupInfoState {
  const GroupInfoState({
    this.room,
    this.members = const [],
    this.busy = false,
    this.removed = false,
    this.error,
  });
  final ChatRoom? room;
  final List<Map<String, dynamic>> members;
  final bool busy, removed;
  final String? error;
}

class GroupInfoCubit extends Cubit<GroupInfoState> {
  GroupInfoCubit(this.repository, this.id) : super(const GroupInfoState()) {
    _events = repository.events.listen((event) {
      if (event.roomId != id || !event.isGroupChange) return;
      if (event.type == 'GROUP_REMOVED') {
        _generation++;
        emit(const GroupInfoState(removed: true));
      } else {
        emit(
          GroupInfoState(
            room: event.room,
            members: state.members,
            busy: state.busy,
          ),
        );
        unawaited(load());
      }
    });
    _connections = repository.connections.listen((connection) {
      if (connection == ChatConnection.connected) unawaited(load());
    });
  }
  final ChatRepository repository;
  final String id;
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<ChatConnection> _connections;
  int _generation = 0;
  bool _acting = false;

  Future<void> load() async {
    final generation = ++_generation;
    try {
      final room = await repository.group(id);
      final members = await repository.groupMembers(id);
      if (!isClosed && generation == _generation) {
        emit(GroupInfoState(room: room, members: members, busy: _acting));
      }
    } catch (e) {
      if (!isClosed && generation == _generation) {
        final removed =
            e is DioException && [403, 404].contains(e.response?.statusCode);
        emit(
          GroupInfoState(
            room: removed ? null : state.room,
            members: removed ? [] : state.members,
            busy: _acting,
            removed: removed,
            error: chatError(e),
          ),
        );
      }
    }
  }

  Future<bool> act(
    String method,
    String suffix, [
    Map<String, dynamic>? body,
  ]) async {
    if (_acting || state.removed) return false;
    _acting = true;
    emit(GroupInfoState(room: state.room, members: state.members, busy: true));
    try {
      await repository.groupAction(id, method, suffix, body);
      if (isClosed) return true;
      if (suffix == '/leave' || (method == 'DELETE' && suffix.isEmpty)) {
        _generation++;
        emit(const GroupInfoState(removed: true));
      } else {
        await load();
      }
      return true;
    } catch (e) {
      // Permissions may have changed since the controls were displayed.
      await load();
      if (!isClosed) {
        emit(
          GroupInfoState(
            room: state.room,
            members: state.members,
            removed: state.removed,
            error: chatError(e),
          ),
        );
      }
      return false;
    } finally {
      _acting = false;
      if (!isClosed && state.busy) {
        emit(
          GroupInfoState(
            room: state.room,
            members: state.members,
            removed: state.removed,
            error: state.error,
          ),
        );
      }
    }
  }

  void report(Object error) {
    if (!isClosed) {
      emit(
        GroupInfoState(
          room: state.room,
          members: state.members,
          removed: state.removed,
          error: chatError(error),
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    await _events.cancel();
    await _connections.cancel();
    return super.close();
  }
}
