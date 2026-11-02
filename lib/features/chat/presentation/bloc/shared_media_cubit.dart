import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/datasources/chat_api.dart';
import '../../data/models/chat_models.dart';
import '../../data/realtime/chat_event.dart';
import '../../data/realtime/chat_realtime.dart';
import '../../data/repositories/chat_repository.dart';

class SharedMediaState {
  const SharedMediaState({
    this.category = 'PHOTOS',
    this.items = const [],
    this.cursor,
    this.hasMore = true,
    this.loading = false,
    this.unavailable = false,
    this.error,
  });
  final String category;
  final List<ChatMessage> items;
  final String? cursor, error;
  final bool hasMore, loading, unavailable;
}

class SharedMediaCubit extends Cubit<SharedMediaState> {
  SharedMediaCubit(this.repository, this.room, this.account)
    : super(const SharedMediaState()) {
    _events = repository.events.listen(_received);
    _connections = repository.connections.listen((value) {
      if (value == ChatConnection.connected && !state.unavailable) {
        unawaited(load(refresh: true));
      }
    });
    _cache = repository.media.changes.listen((_) {
      if (repository.media.account != account) _unavailable();
    });
  }
  final ChatRepository repository;
  final String room, account;
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<ChatConnection> _connections;
  late final StreamSubscription<String?> _cache;
  final _hidden = <String>{};
  CancelToken? _cancel;
  int _generation = 0;
  bool _matches(ChatMessage message) =>
      !message.hidden &&
      !message.deleted &&
      message.fileId != null &&
      message.type ==
          switch (state.category) {
            'PHOTOS' => 'IMAGE',
            'VOICE' => 'VOICE',
            _ => 'FILE',
          };
  void _unavailable() {
    _generation++;
    _cancel?.cancel();
    emit(
      SharedMediaState(
        category: state.category,
        hasMore: false,
        unavailable: true,
      ),
    );
  }

  void _received(ChatEvent event) {
    if (event.roomId != room || isClosed) return;
    if (event.type == 'GROUP_REMOVED') {
      _unavailable();
      return;
    }
    if (event.type == 'GROUP_UPDATED') {
      unawaited(load(refresh: true));
      return;
    }
    final message = event.message;
    if (message == null || state.unavailable) return;
    if (message.hidden || message.deleted) _hidden.add(message.id);
    final items = {for (final m in state.items) m.id: m};
    if (_matches(message) && !_hidden.contains(message.id)) {
      items[message.id] = message;
    } else {
      items.remove(message.id);
    }
    final sorted = items.values.toList()
      ..sort((a, b) {
        final time = b.createdAt.compareTo(a.createdAt);
        return time != 0 ? time : b.id.compareTo(a.id);
      });
    emit(
      SharedMediaState(
        category: state.category,
        items: sorted,
        cursor: state.cursor,
        hasMore: state.hasMore,
        loading: state.loading,
      ),
    );
  }

  Future<void> select(String category) async {
    if (category == state.category || state.unavailable) return;
    _generation++;
    _cancel?.cancel();
    emit(SharedMediaState(category: category));
    await load();
  }

  Future<void> load({bool refresh = false}) async {
    if (state.unavailable || (!refresh && (state.loading || !state.hasMore))) {
      return;
    }
    if (repository.media.account != account) {
      _unavailable();
      return;
    }
    _cancel?.cancel();
    final cancel = _cancel = CancelToken();
    final generation = ++_generation;
    final category = state.category;
    final cursor = refresh ? null : state.cursor;
    emit(
      SharedMediaState(
        category: category,
        items: refresh ? [] : state.items,
        cursor: cursor,
        loading: true,
        hasMore: state.hasMore,
      ),
    );
    try {
      final result = await repository.sharedMedia(
        room,
        category,
        cursor: cursor,
        cancelToken: cancel,
      );
      if (isClosed ||
          generation != _generation ||
          repository.media.account != account) {
        return;
      }
      final items = {for (final m in state.items) m.id: m};
      for (final m in result.items) {
        if (_matches(m) && !_hidden.contains(m.id)) items[m.id] = m;
      }
      final sorted = items.values.toList()
        ..sort((a, b) {
          final time = b.createdAt.compareTo(a.createdAt);
          return time != 0 ? time : b.id.compareTo(a.id);
        });
      emit(
        SharedMediaState(
          category: category,
          items: sorted,
          cursor: result.cursor,
          hasMore: result.cursor != null,
        ),
      );
    } catch (e) {
      if (isClosed || generation != _generation) return;
      if (e is DioException &&
          [401, 403, 404].contains(e.response?.statusCode)) {
        repository.media.invalidateRoom(room);
        _unavailable();
        return;
      }
      emit(
        SharedMediaState(
          category: category,
          items: state.items,
          cursor: cursor,
          hasMore: true,
          error: chatError(e),
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    _generation++;
    _cancel?.cancel();
    await _events.cancel();
    await _connections.cancel();
    await _cache.cancel();
    return super.close();
  }
}
