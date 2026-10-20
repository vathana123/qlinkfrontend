import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.name, this.url, this.radius = 25});
  final String name;
  final String? url;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s.characters.first)
        .join()
        .toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: colors.secondaryContainer,
      foregroundColor: colors.onSecondaryContainer,
      child: ClipOval(
        child: SizedBox(
          width: radius * 2,
          height: radius * 2,
          child: url != null && Uri.tryParse(url!)?.scheme == 'https'
              ? Image.network(
                  url!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Center(child: Text(initials)),
                )
              : Center(
                  child: Text(
                    initials,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
        ),
      ),
    );
  }
}
