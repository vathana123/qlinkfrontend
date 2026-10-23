import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/widgets/user_avatar.dart';

import '../../../../core/network/api_endpoints.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';

import '../../../chat/data/datasources/attachment_picker.dart';

import '../../../chat/data/datasources/chat_api.dart';
import '../../../chat/data/models/chat_models.dart';

import '../bloc/profile_cubit.dart';

class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => ProfileCubit(context.read<AuthBloc>()),
    child: const _Editor(),
  );
}

class _Editor extends StatefulWidget {
  const _Editor();

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final _form = GlobalKey<FormState>();

  late final _name = TextEditingController(
    text: context.read<AuthBloc>().state.user?.displayName,
  );

  late final _username = TextEditingController(
    text: context.read<AuthBloc>().state.user?.username,
  );

  PreparedAttachment? _image;

  bool _remove = false;

  bool _picking = false;

  String? _pickError;

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _pickError = null;
    });

    PreparedAttachment? prepared;

    try {
      final picker = AttachmentPicker();

      final selected = await picker.pick(
        Platform.isAndroid || Platform.isIOS
            ? AttachmentSource.photo
            : AttachmentSource.image,
      );

      if (selected.isEmpty) return;

      if (!mounted) return;

      final policy = ApiEndpoints.data(
        (await context.read<AuthBloc>().repository.dio.get<dynamic>(
          '/api/v1/storage/files/policy',
        )).data,
      );

      prepared = await picker.prepare(
        selected.first,
        AttachmentSource.photo,
        (policy['maxSizeBytes'] as num).toInt(),
        Map<String, dynamic>.from(policy['extensions'] as Map)
          ..removeWhere((_, mime) => !(mime as String).startsWith('image/')),
      );

      if (!mounted) {
        await ProfileCubit.discard(prepared);
        return;
      }

      final old = _image;

      setState(() {
        _image = prepared;
        _remove = false;
      });

      await ProfileCubit.discard(old);
    } catch (error) {
      if (mounted) setState(() => _pickError = chatError(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();

    ProfileCubit.discard(_image);

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => BlocConsumer<ProfileCubit, ProfileState>(
    listener: (context, state) {
      if (state.saved) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Profile saved')));

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) Navigator.of(context).pop();
        });
      }
    },

    builder: (context, state) {
      final user = context.watch<AuthBloc>().state.user;

      final busy = state.busy || _picking;

      return PopScope(
        canPop: !busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Edit profile')),

          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),

                child: Form(
                  key: _form,
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      if (busy) const LinearProgressIndicator(),

                      Center(
                        child: _image != null
                            ? ClipOval(
                                child: Image.file(
                                  File(_image!.path),
                                  width: 100,
                                  height: 100,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    width: 100,
                                    height: 100,
                                    child: Icon(Icons.broken_image_outlined),
                                  ),
                                ),
                              )
                            : UserAvatar(
                                name: user?.displayName ?? '',
                                url: _remove ? null : user?.avatarUrl,
                                radius: 50,
                              ),
                      ),

                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: busy ? null : _pick,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Choose picture'),
                          ),

                          TextButton(
                            onPressed: busy
                                ? null
                                : () async {
                                    final old = _image;

                                    setState(() {
                                      _image = null;
                                      _remove = true;
                                    });

                                    await ProfileCubit.discard(old);
                                  },
                            child: const Text('Remove picture'),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _name,
                        enabled: !busy,
                        maxLength: 255,

                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          border: OutlineInputBorder(),
                        ),

                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Enter a display name'
                            : null,
                      ),

                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _username,
                        enabled: !busy,
                        maxLength: 30,

                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixText: '@',
                          border: OutlineInputBorder(),
                        ),

                        validator: (value) =>
                            (value ?? '').isEmpty && user?.username == null
                            ? null
                            : validateUsername(value ?? ''),
                      ),

                      const Text(
                        'Use 3–30 letters, numbers or underscores. Your sign-in stays the same.',
                      ),

                      if (_pickError != null || state.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),

                          child: Text(
                            _pickError ?? state.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),

                      const SizedBox(height: 24),

                      FilledButton(
                        onPressed: busy
                            ? null
                            : () {
                                if (_form.currentState!.validate()) {
                                  context.read<ProfileCubit>().save(
                                    _name.text,
                                    _username.text,
                                    image: _image,
                                    removeAvatar: _remove,
                                  );
                                }
                              },
                        child: Text(state.busy ? 'Saving…' : 'Save profile'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
