import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/datasources/chat_api.dart';

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});
  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed && !_busy) {
      _startCamera();
    } else if (state != AppLifecycleState.resumed) {
      _controller.stop();
    }
  }

  Future<void> _startCamera() async {
    try {
      await _controller.start();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Camera unavailable. Check camera permission in device settings.',
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _detect(BarcodeCapture capture) async {
    if (_busy) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = parseUserQr(raw);
      if (id == null) {
        throw const FormatException('Scan a valid qLink user QR code.');
      }
      final repository = context.read<ChatRepository>();
      final user = await repository.resolve(id);
      final conversation = await repository.conversation(user);
      await _controller.stop();
      if (mounted) {
        context.pushReplacement('/conversation', extra: conversation);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : chatError(e),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const BlurAppBar(title: 'Scan qLink QR'),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _controller,
            onDetect: _detect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.no_photography_outlined, size: 48),
                    const SizedBox(height: 16),
                    const Text(
                      'Camera unavailable. Allow camera access in device settings, then try again.',
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: _startCamera,
                      child: const Text('Try camera again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  _error ??
                      (_busy
                          ? 'Opening conversation…'
                          : 'Point your camera at a qLink user QR code.'),
                ),
                if (_error != null)
                  TextButton(
                    onPressed: () => setState(() {
                      _busy = false;
                      _error = null;
                    }),
                    child: const Text('Scan again'),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
