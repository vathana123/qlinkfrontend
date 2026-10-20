import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../chat/data/models/chat_models.dart';
import '../../../chat/data/repositories/chat_repository.dart';
import '../../../chat/data/datasources/chat_api.dart';

class UserSearchState {
  const UserSearchState({
    this.items = const [],
    this.loading = false,
    this.hasMore = false,
    this.error,
    this.searched = false,
  });
  final List<PublicUser> items;
  final bool loading, hasMore, searched;
  final String? error;
}

class UserSearchCubit extends Cubit<UserSearchState> {
  UserSearchCubit(this.repository) : super(const UserSearchState());
  final ChatRepository repository;
  Timer? _timer;
  int _generation = 0, _page = 0;
  String _query = '';
  void search(String value) {
    _timer?.cancel();
    _generation++;
    _page = 0;
    _query = value.trim().toLowerCase();
    if (_query.isEmpty) {
      emit(const UserSearchState());
      return;
    }
    if (_query.length < 3 || _query.length > 254) {
      emit(const UserSearchState(error: 'Enter 3–254 characters to search.'));
      return;
    }
    emit(const UserSearchState(loading: true));
    _timer = Timer(const Duration(milliseconds: 350), () => _load(_generation));
  }

  Future<void> retry() async {
    if (!state.loading && _query.length >= 3 && _query.length <= 254) {
      await _load(_generation);
    }
  }

  Future<void> more() async {
    if (!state.loading && state.hasMore) await _load(_generation);
  }

  Future<void> _load(int generation) async {
    final previous = state.items;
    emit(
      UserSearchState(items: previous, loading: true, hasMore: state.hasMore),
    );
    try {
      final result = await repository.search(_query, page: _page);
      if (isClosed || generation != _generation) return;
      _page++;
      emit(
        UserSearchState(
          items: [...previous, ...result.items],
          searched: true,
          hasMore: result.hasMore,
        ),
      );
    } catch (e) {
      if (!isClosed && generation == _generation) {
        emit(UserSearchState(items: previous, error: chatError(e)));
      }
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
