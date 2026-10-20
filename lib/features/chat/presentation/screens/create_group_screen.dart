import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/repositories/chat_repository.dart';
import '../bloc/group_creation_cubit.dart';

typedef GroupPhotoPicker = Future<Uint8List?> Function();

class CreateGroupScreen extends StatelessWidget {
  const CreateGroupScreen({super.key, this.pickPhoto});
  final GroupPhotoPicker? pickPhoto;
  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (c) => GroupCreationCubit(
      c.read<ChatRepository>(),
      c.read<AuthBloc>().state.user!.id,
    ),
    child: _GroupForm(pickPhoto: pickPhoto),
  );
}

class _GroupForm extends StatefulWidget {
  const _GroupForm({this.pickPhoto});
  final GroupPhotoPicker? pickPhoto;
  @override
  State<_GroupForm> createState() => _GroupFormState();
}

class _GroupFormState extends State<_GroupForm> {
  final _form = GlobalKey<FormState>();
  bool _picking = false;
  Future<void> _photo() async {
    if (_picking) return;
    setState(() => _picking = true);
    final cubit = context.read<GroupCreationCubit>();
    try {
      Uint8List? bytes;
      if (widget.pickPhoto != null) {
        bytes = await widget.pickPhoto!();
      } else {
        final file = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
        );
        bytes = await file?.readAsBytes();
      }
      if (mounted && bytes != null) cubit.photo(bytes);
    } catch (_) {
      if (mounted) cubit.photoError();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Create New Group'),
    body: SafeArea(
      child: BlocBuilder<GroupCreationCubit, GroupCreationState>(
        builder: (context, state) => Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Semantics(
                  label: 'Choose group photo',
                  button: true,
                  child: InkWell(
                    onTap: _picking ? null : _photo,
                    customBorder: const CircleBorder(),
                    child: CircleAvatar(
                      radius: 44,
                      backgroundImage: state.photo == null
                          ? null
                          : MemoryImage(state.photo!),
                      child: state.photo == null
                          ? const Icon(Icons.add_a_photo_outlined, size: 30)
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: Text('Photo preview only')),
              const SizedBox(height: 20),
              TextFormField(
                initialValue: state.name,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => validateGroupName(value ?? ''),
                onChanged: (value) =>
                    context.read<GroupCreationCubit>().details(name: value),
                textCapitalization: TextCapitalization.words,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Public Group'),
                value: state.isPublic,
                onChanged: (value) =>
                    context.read<GroupCreationCubit>().details(isPublic: value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('View All Messages'),
                subtitle: const Text(
                  'When enabled, new members can see messages sent before they joined.',
                ),
                value: state.viewAllMessages,
                onChanged: (value) => context
                    .read<GroupCreationCubit>()
                    .details(viewAllMessages: value),
              ),
              if (state.error != null)
                Text(
                  state.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _picking
                    ? null
                    : () {
                        if (!_form.currentState!.validate()) return;
                        final cubit = context.read<GroupCreationCubit>();
                        context.push('/create-group/members', extra: cubit);
                      },
                child: const Text('Next'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
