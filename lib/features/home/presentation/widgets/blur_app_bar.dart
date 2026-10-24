import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BlurAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BlurAppBar({
    super.key,
    this.title = '',
    this.titleWidget,
    this.actions,
  });

  final String title;
  final Widget? titleWidget;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return AppBar(
      backgroundColor: Colors.transparent,
      forceMaterialTransparency: true,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle:
          (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
              .copyWith(statusBarColor: Colors.transparent),

      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: ColoredBox(
            color: scheme.surface.withValues(alpha: 0.78),
            child: SizedBox.expand(),
          ),
        ),
      ),

      title:
          titleWidget ??
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
      actions: actions,
    );
  }
}
