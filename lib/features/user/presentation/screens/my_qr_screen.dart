import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../home/presentation/widgets/blur_app_bar.dart';

class MyQrScreen extends StatelessWidget {
  const MyQrScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthBloc>().state.user;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BlurAppBar(title: 'My QR code'),
      body: Center(
        child: user == null
            ? const SizedBox.shrink()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    user.displayName,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  QrImageView(
                    data: 'qlink://user/${user.id}',
                    size: 260,
                    backgroundColor: colors.brightness == Brightness.dark
                        ? colors.onSurface
                        : colors.surface,
                    eyeStyle: QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: colors.brightness == Brightness.dark
                          ? colors.surface
                          : colors.onSurface,
                    ),
                    dataModuleStyle: QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: colors.brightness == Brightness.dark
                          ? colors.surface
                          : colors.onSurface,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Share this code so someone can find you on qLink.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
