import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../chat/data/datasources/chat_api.dart';
import '../../../chat/data/models/chat_models.dart';
import '../../../chat/data/repositories/chat_repository.dart';

class PrivacyState {
  const PrivacyState({
    this.online = 'CONTACTS',
    this.lastSeen = 'CONTACTS',
    this.loading = false,
    this.busy = false,
    this.loaded = false,
    this.error,
    this.blockedByMe = false,
    this.canMessage = true,
    this.blocked = const [],
    this.hasMore = false,
  });
  final String online, lastSeen;
  final bool loading, busy, loaded, blockedByMe, canMessage, hasMore;
  final String? error;
  final List<PublicUser> blocked;
}

class PrivacyCubit extends Cubit<PrivacyState> {
  PrivacyCubit(this.repository, this.account, {this.peer})
    : super(const PrivacyState());
  final ChatRepository repository;
  final String account;
  final PublicUser? peer;
  int _page = 0, _generation = 0;
  bool get _current =>
      !isClosed &&
      repository.api.dio.options.extra['authenticatedAccountId'] == account;
  void _update({
    String? online,
    String? lastSeen,
    bool? loading,
    bool? busy,
    bool? loaded,
    String? error,
    bool? blockedByMe,
    bool? canMessage,
    List<PublicUser>? blocked,
    bool? hasMore,
  }) {
    if (!_current) return;
    emit(
      PrivacyState(
        online: online ?? state.online,
        lastSeen: lastSeen ?? state.lastSeen,
        loading: loading ?? state.loading,
        busy: busy ?? state.busy,
        loaded: loaded ?? state.loaded,
        error: error,
        blockedByMe: blockedByMe ?? state.blockedByMe,
        canMessage: canMessage ?? state.canMessage,
        blocked: blocked ?? state.blocked,
        hasMore: hasMore ?? state.hasMore,
      ),
    );
  }

  Future<void> load() async {
    final generation = ++_generation;
    _update(loading: true);
    try {
      final data = peer == null
          ? await repository.privacyRequest('me/privacy', account)
          : await repository.relationship(peer!.id, account);
      if (generation != _generation) return;
      _update(
        loading: false,
        loaded: true,
        online: data['onlineVisibility'] as String?,
        lastSeen: data['lastSeenVisibility'] as String?,
        blockedByMe: data['blockedByMe'] as bool?,
        canMessage: data['canMessage'] as bool?,
      );
    } catch (e) {
      if (generation == _generation) {
        _update(loading: false, error: chatError(e));
      }
    }
  }

  Future<void> save(String online, String lastSeen) async {
    if (state.busy || !state.loaded) return;
    _generation++;
    _update(busy: true);
    try {
      final data = await repository.privacyRequest(
        'me/privacy',
        account,
        method: 'PUT',
        data: {'onlineVisibility': online, 'lastSeenVisibility': lastSeen},
      );
      _update(
        busy: false,
        online: data['onlineVisibility'] as String,
        lastSeen: data['lastSeenVisibility'] as String,
      );
    } catch (e) {
      _update(busy: false, error: chatError(e));
    }
  }

  Future<void> loadBlocked({bool reset = false}) async {
    if (state.loading || state.busy) return;
    if (!reset && state.loaded && !state.hasMore) return;
    final page = reset ? 0 : _page;
    final generation = ++_generation;
    _update(loading: true);
    try {
      final data = await repository.privacyRequest(
        'me/blocks',
        account,
        query: {'page': page, 'size': 20},
      );
      if (generation != _generation) return;
      final items = (data['content'] as List).map(
        (e) => PublicUser.fromJson(Map<String, dynamic>.from(e as Map)),
      );
      final unique = {
        for (final user in reset ? <PublicUser>[] : state.blocked)
          user.id: user,
      };
      for (final user in items) {
        unique[user.id] = user;
      }
      _page = page + 1;
      _update(
        loading: false,
        loaded: true,
        blocked: unique.values.toList(),
        hasMore: data['last'] == false,
      );
    } catch (e) {
      if (generation == _generation) {
        _update(loading: false, error: chatError(e));
      }
    }
  }

  Future<void> block(PublicUser user, bool enabled) async {
    if (state.busy || state.loading) return;
    _generation++;
    _update(busy: true);
    try {
      final data = await repository.setBlocked(user.id, enabled, account);
      _update(
        busy: false,
        blockedByMe: peer?.id == user.id ? data['blockedByMe'] as bool : null,
        canMessage: peer?.id == user.id ? data['canMessage'] as bool : null,
        blocked: !enabled
            ? state.blocked.where((u) => u.id != user.id).toList()
            : null,
      );
      // Offset pages shift after deletion: restart the small management list safely.
      if (peer == null && !enabled && _current) await loadBlocked(reset: true);
    } catch (e) {
      _update(busy: false, error: chatError(e));
    }
  }
}
