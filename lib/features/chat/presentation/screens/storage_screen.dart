import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/repositories/private_media_cache.dart';
import '../bloc/storage_cubit.dart';
import '../widgets/attachment_bubble.dart';

class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key});
  @override
  Widget build(BuildContext context) => BlocProvider(
    key: ValueKey(context.watch<AuthBloc>().state.user?.id),
    create: (c) => StorageCubit(c.read<ChatRepository>().media)..refresh(),
    child: const _StorageView(),
  );
}

class _StorageView extends StatefulWidget {
  const _StorageView();
  @override
  State<_StorageView> createState() => _StorageViewState();
}

class _StorageViewState extends State<_StorageView> {
  final selected = MediaCategory.values.toSet();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Storage & Data'),
    body: BlocBuilder<StorageCubit, StorageState>(
      builder: (context, state) => RefreshIndicator(
        onRefresh: context.read<StorageCubit>().refresh,
        child: ListView(
          padding: const EdgeInsets.all(20),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Text(
              readableFileSize(state.usage.total),
              style: Theme.of(context).textTheme.headlineLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
            const Text('Downloaded cache on this device'),
            const SizedBox(height: 24),
            for (final category in MediaCategory.values)
              CheckboxListTile(
                value: selected.contains(category),
                title: Text(switch (category) {
                  MediaCategory.photos => 'Photos',
                  MediaCategory.audio => 'Audio',
                  MediaCategory.files => 'Files',
                }),
                subtitle: Text(readableFileSize(state.usage[category])),
                onChanged: state.busy
                    ? null
                    : (value) => setState(() {
                        if (value == true) {
                          selected.add(category);
                        } else {
                          selected.remove(category);
                        }
                      }),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: state.busy || selected.isEmpty
                  ? null
                  : () => context.read<StorageCubit>().clear(Set.of(selected)),
              icon: const Icon(Icons.cleaning_services_outlined),
              label: Text(state.busy ? 'Clearing…' : 'Clear selected cache'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your messages and uploads are kept. Media can be downloaded again. Files currently in use remain cached.',
            ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  state.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
