import 'dart:async';
import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/datasources/chat_api.dart';
import '../../data/realtime/chat_event.dart';
import '../../data/realtime/chat_realtime.dart';

class RoomsState {
  const RoomsState({
    this.items = const [],
    this.loading = false,
    this.hasMore = true,
    this.error,
  });
  final List<ChatRoom> items;
  final bool loading, hasMore;
  final String? error;
}

class RoomsCubit extends Cubit<RoomsState> {
  RoomsCubit(this.repository) : super(const RoomsState()) {
    _events = repository.events.listen(_received);
    _connections = repository.connections.listen((state) {
      if (state == ChatConnection.connected) unawaited(synchronize());
    });
  }
  final ChatRepository repository;
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<ChatConnection> _connections;
  int _page = 0;
  bool _refreshQueued = false;
  int _compare(ChatRoom a, ChatRoom b) {
    final time = (b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0));
    return time != 0 ? time : b.id.compareTo(a.id);
  }

  List<ChatRoom> _merge(Iterable<ChatRoom> incoming) {
    final all = {for (final room in state.items) room.id: room};
    for (var room in incoming) {
      final old = all[room.id];
      if (old?.lastMessage != null &&
          (room.lastMessage == null ||
              old!.lastMessage!.createdAt.isAfter(
                room.lastMessage!.createdAt,
              ) ||
              (old.lastMessage!.createdAt == room.lastMessage!.createdAt &&
                  old.lastMessage!.id.compareTo(room.lastMessage!.id) > 0))) {
        room = room.withMessage(old!.lastMessage!);
      }
      all[room.id] = room;
    }
    return all.values.toList()..sort(_compare);
  }

  void _received(ChatEvent event) {
    final known = state.items.where((r) => r.id == event.roomId).firstOrNull;
    final room = event.room ?? known;
    if (room == null) {
      unawaited(synchronize());
      return;
    }
    final candidate =
        room.lastMessage != null &&
            room.lastMessage!.createdAt.isAfter(event.message.createdAt)
        ? room
        : room.withMessage(event.message);
    emit(
      RoomsState(
        items: _merge([candidate]),
        loading: state.loading,
        hasMore: state.hasMore,
      ),
    );
  }

  Future<void> load({bool refresh = false}) async {
    if (refresh) return synchronize();
    if (state.loading || !state.hasMore) return;
    emit(RoomsState(items: state.items, loading: true, hasMore: state.hasMore));
    try {
      final result = await repository.rooms(page: _page);
      if (isClosed) return;
      _page++;
      emit(RoomsState(items: _merge(result.items), hasMore: result.hasMore));
    } catch (e) {
      if (!isClosed) {
        emit(
          RoomsState(
            items: state.items,
            hasMore: state.hasMore,
            error: chatError(e),
          ),
        );
      }
    } finally {
      _queued();
    }
  }

  Future<void> synchronize() async {
    if (isClosed) return;
    if (state.loading) {
      _refreshQueued = true;
      return;
    }
    emit(RoomsState(items: state.items, loading: true, hasMore: state.hasMore));
    try {
      // Re-fetch the loaded prefix so reconnect does not discard already loaded pages.
      final count = max(1, _page);
      ResultPage<ChatRoom>? result;
      int fetched = 0;
      for (int page = 0; page < count; page++) {
        result = await repository.rooms(page: page);
        if (isClosed) return;
        fetched++;
        emit(
          RoomsState(
            items: _merge(result.items),
            loading: true,
            hasMore: result.hasMore,
          ),
        );
        if (!result.hasMore) break;
      }
      _page = fetched;
      emit(RoomsState(items: state.items, hasMore: result?.hasMore ?? false));
    } catch (e) {
      if (!isClosed) {
        emit(
          RoomsState(
            items: state.items,
            hasMore: state.hasMore,
            error: chatError(e),
          ),
        );
      }
    } finally {
      _queued();
    }
  }

  void _queued() {
    if (_refreshQueued && !isClosed) {
      _refreshQueued = false;
      unawaited(synchronize());
    }
  }

  @override
  Future<void> close() async {
    await _events.cancel();
    await _connections.cancel();
    return super.close();
  }
}
