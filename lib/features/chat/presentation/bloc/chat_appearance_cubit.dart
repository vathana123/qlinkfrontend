import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/repositories/chat_appearance_store.dart';
import '../theme/chat_appearance.dart';

class ChatAppearanceState {
  const ChatAppearanceState({
    this.account,
    this.appearance = const ChatAppearance(),
    this.error,
  });
  final String? account, error;
  final ChatAppearance appearance;
}

class ChatAppearanceCubit extends Cubit<ChatAppearanceState> {
  ChatAppearanceCubit(this.store) : super(const ChatAppearanceState());
  final ChatAppearanceStore store;
  final _sessionValues = <String, ChatAppearance>{};
  Future<void> _pending = Future.value();
  int _revision = 0;
  void setAccount(String? account) {
    if (account == state.account) return;
    _revision++;
    emit(
      ChatAppearanceState(
        account: account,
        appearance: account == null
            ? const ChatAppearance()
            : _sessionValues.putIfAbsent(account, () => store.read(account)),
      ),
    );
  }

  Future<void> update(ChatAppearance value) async {
    final account = state.account;
    if (account == null || isClosed) return;
    final revision = ++_revision;
    _sessionValues[account] = value;
    emit(ChatAppearanceState(account: account, appearance: value));
    // Capture identity and value before queuing; a later login cannot redirect a write.
    final operation = _pending.then((_) => store.save(account, value));
    _pending = operation.catchError((Object _) {});
    try {
      await operation;
    } catch (_) {
      if (!isClosed && state.account == account && revision == _revision) {
        emit(
          ChatAppearanceState(
            account: account,
            appearance: value,
            error: 'Appearance applied, but could not be saved. Please retry.',
          ),
        );
      }
    }
  }

  Future<void> reset() => update(const ChatAppearance());
  @override
  Future<void> close() async {
    await _pending;
    return super.close();
  }
}
