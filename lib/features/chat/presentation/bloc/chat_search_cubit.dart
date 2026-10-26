import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/datasources/chat_api.dart';
import '../../data/models/chat_models.dart';
import '../../data/models/search_models.dart';
import '../../data/repositories/chat_repository.dart';

class ChatSearchState {
  const ChatSearchState({
    this.query = '',
    this.rooms = const [],
    this.messages = const [],
    this.roomCursor,
    this.messageCursor,
    this.loading = false,
    this.error,
  });
  final String query;
  final List<ChatRoom> rooms;
  final List<MessageMatch> messages;
  final String? roomCursor, messageCursor, error;
  final bool loading;
}

class ChatSearchCubit extends Cubit<ChatSearchState> {
  ChatSearchCubit(this.repository, {this.roomId})
    : super(const ChatSearchState()) {
    _events = repository.events.listen((event) {
      if (roomId != null && event.roomId != roomId) return;
      // Drop potentially stale previews immediately, then recheck access in SQL.
      if (state.query.length >= 2 && event.type != 'MESSAGE_RECEIPT') {
        change(state.query);
      }
    });
  }
  final ChatRepository repository;
  final String? roomId;
  late final StreamSubscription<dynamic> _events;
  Timer? _debounce;
  CancelToken? _cancel;
  int _generation = 0;
  bool _retryAppend = false;

  void change(String raw) {
    _retryAppend = false;
    _debounce?.cancel();
    _cancel?.cancel();
    _generation++;
    final query = raw.trim();
    final valid = query.length >= 2 && query.length <= 100;
    emit(
      ChatSearchState(
        query: query,
        loading: valid,
        error: query.length > 100 ? 'Use at most 100 characters.' : null,
      ),
    );
    if (valid) {
      _debounce = Timer(const Duration(milliseconds: 350), () => _load(false));
    }
  }

  Future<void> retry() => _load(_retryAppend);
  Future<void> more() async {
    if (state.loading ||
        (state.roomCursor == null && state.messageCursor == null)) {
      return;
    }
    await _load(true);
  }

  Future<void> _load(bool append) async {
    if (isClosed || state.query.length < 2 || state.query.length > 100) return;
    _debounce?.cancel();
    _cancel?.cancel();
    final generation = ++_generation;
    final cancel = _cancel = CancelToken();
    final old = state;
    emit(
      ChatSearchState(
        query: old.query,
        rooms: old.rooms,
        messages: old.messages,
        roomCursor: old.roomCursor,
        messageCursor: old.messageCursor,
        loading: true,
      ),
    );
    try {
      // A single generation commits both pages atomically; retries cannot skip a page.
      final roomPage = roomId == null && (!append || old.roomCursor != null)
          ? await repository.searchRooms(
              old.query,
              cursor: append ? old.roomCursor : null,
              cancelToken: cancel,
            )
          : const SearchPage<ChatRoom>([], null);
      if (isClosed || generation != _generation) return;
      final messagePage = !append || old.messageCursor != null
          ? await repository.searchMessages(
              old.query,
              roomId: roomId,
              cursor: append ? old.messageCursor : null,
              cancelToken: cancel,
            )
          : const SearchPage<MessageMatch>([], null);
      if (isClosed || generation != _generation) return;
      final rooms = <String, ChatRoom>{
        if (append)
          for (final r in old.rooms) r.id: r,
        for (final r in roomPage.items) r.id: r,
      };
      final messages = <String, MessageMatch>{
        if (append)
          for (final m in old.messages) m.message.id: m,
        for (final m in messagePage.items) m.message.id: m,
      };
      emit(
        ChatSearchState(
          query: old.query,
          rooms: rooms.values.toList(),
          messages: messages.values.toList(),
          roomCursor: roomPage.cursor,
          messageCursor: messagePage.cursor,
        ),
      );
    } catch (e) {
      if (isClosed || generation != _generation || cancel.isCancelled) return;
      _retryAppend = append;
      emit(
        ChatSearchState(
          query: old.query,
          rooms: old.rooms,
          messages: old.messages,
          roomCursor: old.roomCursor,
          messageCursor: old.messageCursor,
          error: chatError(e),
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    _generation++;
    _debounce?.cancel();
    _cancel?.cancel();
    await _events.cancel();
    return super.close();
  }
}
