import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/home/presentation/widgets/blur_bottom_bar.dart';

class MainLayout extends StatelessWidget {
  const MainLayout({super.key, required this.shell});
  final StatefulNavigationShell shell;
  @override
  Widget build(BuildContext context) => Scaffold(
    extendBody: true,
    body: shell,
    bottomNavigationBar: BlurBottomBar(
      index: shell.currentIndex,
      onSelected: (index) =>
          shell.goBranch(index, initialLocation: index == shell.currentIndex),
    ),
  );
}
