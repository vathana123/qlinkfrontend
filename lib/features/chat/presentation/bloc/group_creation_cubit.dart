import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/datasources/chat_api.dart';

String? validateGroupName(String value) {
  final name = value.trim();
  if (name.isEmpty) return 'Enter a group name.';
  if (name.length > 100) return 'Use at most 100 characters.';
  return null;
}

class GroupCreationState {
  const GroupCreationState({
    this.name = '',
    this.isPublic = false,
    this.viewAllMessages = false,
    this.photo,
    this.contacts = const [],
    this.selected = const {},
    this.query = '',
    this.loading = false,
    this.creating = false,
    this.hasMore = true,
    this.error,
    this.created,
  });
  final String name, query;
  final bool isPublic, viewAllMessages, loading, creating, hasMore;
  final Uint8List? photo;
  final List<PublicUser> contacts;
  final Set<String> selected;
  final String? error;
  final ChatRoom? created;
  List<PublicUser> get filtered => contacts
      .where(
        (u) =>
            u.displayName.toLowerCase().contains(query.toLowerCase()) ||
            (u.username ?? '').toLowerCase().contains(query.toLowerCase()),
      )
      .toList();
}

class GroupCreationCubit extends Cubit<GroupCreationState> {
  GroupCreationCubit(this.repository, this.viewer)
    : super(const GroupCreationState());
  final ChatRepository repository;
  final String viewer;
  int _page = 0;
  void _update({
    String? name,
    bool? isPublic,
    bool? viewAllMessages,
    Uint8List? photo,
    List<PublicUser>? contacts,
    Set<String>? selected,
    String? query,
    bool? loading,
    bool? creating,
    bool? hasMore,
    String? error,
    ChatRoom? created,
  }) {
    if (isClosed) return;
    emit(
      GroupCreationState(
        name: name ?? state.name,
        isPublic: isPublic ?? state.isPublic,
        viewAllMessages: viewAllMessages ?? state.viewAllMessages,
        photo: photo ?? state.photo,
        contacts: contacts ?? state.contacts,
        selected: selected ?? state.selected,
        query: query ?? state.query,
        loading: loading ?? state.loading,
        creating: creating ?? state.creating,
        hasMore: hasMore ?? state.hasMore,
        error: error,
        created: created ?? state.created,
      ),
    );
  }

  void details({String? name, bool? isPublic, bool? viewAllMessages}) {
    if (state.creating) return;
    _update(name: name, isPublic: isPublic, viewAllMessages: viewAllMessages);
  }

  void photo(Uint8List bytes) => _update(photo: bytes);
  void photoError() =>
      _update(error: 'Unable to open that photo. Please try again.');
  void search(String query) => _update(query: query);
  void toggle(String id) {
    if (state.creating ||
        id == viewer ||
        !state.contacts.any((u) => u.id == id)) {
      return;
    }
    final selected = {...state.selected};
    if (!selected.add(id)) selected.remove(id);
    _update(selected: selected);
  }

  Future<void> loadContacts() async {
    if (state.loading || !state.hasMore) return;
    _update(loading: true);
    try {
      final page = await repository.contacts(page: _page);
      if (isClosed || state.created != null) return;
      _page++;
      final contacts = {for (final u in state.contacts) u.id: u};
      for (final u in page.items) {
        if (u.id != viewer) contacts[u.id] = u;
      }
      _update(
        contacts: contacts.values.toList(),
        loading: false,
        hasMore: page.hasMore,
      );
    } catch (e) {
      _update(loading: false, error: chatError(e));
    }
  }

  Future<void> create() async {
    if (state.creating || state.created != null || state.selected.isEmpty) {
      return;
    }
    final validation = validateGroupName(state.name);
    if (validation != null) {
      _update(error: validation);
      return;
    }
    _update(creating: true);
    try {
      final room = await repository.createGroup(
        name: state.name,
        isPublic: state.isPublic,
        viewAllMessages: state.viewAllMessages,
        memberIds: state.selected,
      );
      if (!isClosed) emit(GroupCreationState(created: room, hasMore: false));
    } catch (e) {
      _update(creating: false, error: chatError(e));
    }
  }
}
