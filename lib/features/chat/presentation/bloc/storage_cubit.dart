import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/repositories/private_media_cache.dart';

class StorageState {
  const StorageState({
    this.usage = const CacheUsage({}),
    this.busy = false,
    this.error,
  });
  final CacheUsage usage;
  final bool busy;
  final String? error;
}

class StorageCubit extends Cubit<StorageState> {
  StorageCubit(this.media)
    : account = media.account,
      super(const StorageState()) {
    _changes = media.storageChanges.listen((_) => unawaited(refresh()));
  }
  final PrivateMediaCache media;
  final String? account;
  late final StreamSubscription<void> _changes;
  int _revision = 0;
  Future<void> refresh() async {
    final revision = ++_revision;
    try {
      final usage = await media.usage();
      if (isClosed || revision != _revision) return;
      emit(
        StorageState(
          usage: media.account == account ? usage : const CacheUsage({}),
          busy: state.busy,
          error: state.error,
        ),
      );
    } catch (_) {
      if (!isClosed && revision == _revision) {
        emit(
          StorageState(
            usage: state.usage,
            busy: state.busy,
            error: 'Unable to measure cached storage. Please retry.',
          ),
        );
      }
    }
  }

  Future<void> clear(Set<MediaCategory> categories) async {
    if (state.busy || media.account != account) return;
    emit(StorageState(usage: state.usage, busy: true));
    String? error;
    try {
      await media.clearCached(categories);
    } catch (_) {
      error = 'Some cached files could not be cleared. Please retry.';
    }
    if (isClosed) return;
    emit(
      StorageState(
        usage: media.account == account ? state.usage : const CacheUsage({}),
        error: error,
      ),
    );
    await refresh();
  }

  @override
  Future<void> close() async {
    _revision++;
    await _changes.cancel();
    return super.close();
  }
}
