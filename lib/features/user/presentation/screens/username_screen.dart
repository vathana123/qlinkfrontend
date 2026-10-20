import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/data/models/app_user.dart';
import '../../../chat/data/repositories/chat_repository.dart';
import '../../../chat/data/datasources/chat_api.dart';
import '../../../chat/data/models/chat_models.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';

class UsernameScreen extends StatefulWidget {
  const UsernameScreen({super.key});
  @override
  State<UsernameScreen> createState() => _UsernameScreenState();
}

class _UsernameScreenState extends State<UsernameScreen> {
  late final _text = TextEditingController(
    text: context.read<AuthBloc>().state.user?.username ?? '',
  );
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final error = validateUsername(_text.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final user = AppUser.fromJson(
        await context.read<ChatRepository>().api.username(
          _text.text.toLowerCase(),
        ),
      );
      if (!mounted) return;
      context.read<AuthBloc>().add(AuthProfileUpdated(user));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = chatError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Username'),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 30,
            enabled: !_saving,
            decoration: InputDecoration(
              prefixText: '@',
              labelText: 'Username',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          const Text(
            'People can find you by username. Your sign-in stays the same.',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save username'),
          ),
        ],
      ),
    ),
  );
}
