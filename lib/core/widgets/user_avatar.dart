import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';

class UserAvatar extends StatefulWidget {
  const UserAvatar({super.key, required this.name, this.url, this.radius = 25});
  final String name;
  final String? url;
  final double radius;
  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

class _UserAvatarState extends State<UserAvatar> {
  Future<Uint8List>? _bytes;
  static final _stored = RegExp(
    r'^/api/v1/storage/files/[0-9a-fA-F-]{36}/download$',
  );
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  void _load() {
    _bytes = null;
    if (_stored.hasMatch(widget.url ?? '')) {
      _bytes = context
          .read<AuthBloc>()
          .repository
          .dio
          .get<List<int>>(
            widget.url!,
            options: Options(responseType: ResponseType.bytes),
          )
          .then((response) => Uint8List.fromList(response.data!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final initials = widget.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s.characters.first)
        .join()
        .toUpperCase();
    final fallback = Center(
      child: initials.isEmpty
          ? const Icon(Icons.person_outline)
          : Text(initials, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
    Widget picture = fallback;
    if (_bytes != null) {
      picture = FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snapshot) => snapshot.hasData
            ? Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      );
    } else if (widget.url != null &&
        Uri.tryParse(widget.url!)?.scheme == 'https') {
      picture = Image.network(
        widget.url!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: colors.secondaryContainer,
      foregroundColor: colors.onSecondaryContainer,
      child: ClipOval(
        child: SizedBox(
          width: widget.radius * 2,
          height: widget.radius * 2,
          child: picture,
        ),
      ),
    );
  }
}
