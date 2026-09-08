import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// Scans a pairing QR code. Camera permission denial is handled with a text
/// explanation and a fallback to pasting the link the code encodes.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  String? _permissionError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  void _onDetectError(Object error, StackTrace stackTrace) {
    if (error is MobileScannerException &&
        error.errorCode == MobileScannerErrorCode.permissionDenied) {
      setState(() => _permissionError = 'Camera permission was denied.');
    } else {
      setState(() => _permissionError = 'Camera error: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing code')),
      body: _permissionError != null
          ? _PermissionFallback(message: _permissionError!)
          : Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  onDetectError: _onDetectError,
                  errorBuilder: (context, error) =>
                      _PermissionFallback(message: error.toString()),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.colorScheme.scrim.withValues(alpha: 0),
                          theme.colorScheme.scrim.withValues(alpha: 0.85),
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        'Point the camera at the pairing QR code shown by /remote-omp.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onInverseSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _PermissionFallback extends StatelessWidget {
  const _PermissionFallback({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: AppSpacing.md),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.md),
            const Text(
              'Use "Paste a link" on the previous screen instead.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            Semantics(
              button: true,
              label: 'Go back to manual entry',
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
