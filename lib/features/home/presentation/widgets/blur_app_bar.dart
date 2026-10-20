import 'dart:ui';

import 'package:flutter/material.dart';

class BlurAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BlurAppBar({super.key, required this.title, this.actions});
  final String title;
  final List<Widget>? actions;
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: AppBar(
        title: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: -.5,
          ),
        ),
        actions: actions,
        backgroundColor: Theme.of(context).colorScheme.surface
            .withValues(alpha: .78),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    ),
  );
}
