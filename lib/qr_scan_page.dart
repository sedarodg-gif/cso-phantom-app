import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'main.dart';

/// Scanne un QR code avec la caméra et renvoie le texte lu.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final MobileScannerController _c = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text('Scanner un QR code'),
        actions: [
          IconButton(icon: const Icon(Icons.flash_on), onPressed: () => _c.toggleTorch()),
          IconButton(icon: const Icon(Icons.cameraswitch), onPressed: () => _c.switchCamera()),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _c,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Caméra indisponible. Autorise la caméra pour CSO Phantom dans les réglages du téléphone.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kBad),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
              child: const Text('Place le QR code devant la caméra', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
