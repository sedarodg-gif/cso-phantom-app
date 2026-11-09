import 'dart:async';
import 'dart:io' show HttpClient;

import 'package:flutter/material.dart';

import 'main.dart';
import 'settings_page.dart';

/// Test de vitesse : télécharge un fichier de test et mesure le débit réel
/// (à lancer VPN connecté pour mesurer la vitesse du tunnel).
class SpeedPage extends StatefulWidget {
  const SpeedPage({super.key});

  @override
  State<SpeedPage> createState() => _SpeedPageState();
}

class _SpeedPageState extends State<SpeedPage> {
  bool _run = false;
  double _now = 0; // Mo/s instantané
  double _avg = 0; // Mo/s moyen
  double _peak = 0; // Mo/s maximum
  double _mb = 0; // Mo reçus
  String _msg = 'Connecte le VPN puis lance le test pour mesurer la vitesse du tunnel.';

  Future<void> _start() async {
    if (_run) return;
    setState(() {
      _run = true;
      _now = 0;
      _avg = 0;
      _peak = 0;
      _mb = 0;
      _msg = 'Test en cours (10 secondes maximum)...';
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final sw = Stopwatch()..start();
    var bytes = 0;
    var lastBytes = 0;
    var lastMs = 0;
    try {
      final req = await client
          .getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=50000000'))
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await for (final chunk in res) {
        bytes += chunk.length;
        final ms = sw.elapsedMilliseconds;
        if (ms - lastMs >= 400) {
          final inst = (bytes - lastBytes) / 1048576 / ((ms - lastMs) / 1000);
          lastBytes = bytes;
          lastMs = ms;
          if (mounted) {
            setState(() {
              _now = inst;
              if (inst > _peak) _peak = inst;
              _avg = bytes / 1048576 / (ms / 1000);
              _mb = bytes / 1048576;
            });
          }
        }
        if (ms >= 10000) break;
      }
      final secs = sw.elapsedMilliseconds / 1000;
      if (mounted) {
        setState(() {
          _mb = bytes / 1048576;
          _avg = secs > 0 ? _mb / secs : 0;
          _now = 0;
          _msg = bytes == 0 ? 'Aucune donnée reçue : le tunnel ne laisse rien passer.' : 'Test terminé.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _now = 0;
          _msg = bytes > 0 ? 'Test interrompu.' : "Échec : aucune donnée reçue ($e)";
        });
      }
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _run = false);
    }
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: glass(r: 18),
        child: Column(
          children: [
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12, color: kMute)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: 'Test de vitesse',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 26),
            decoration: glass(r: 24),
            child: Column(
              children: [
                Text(
                  _now.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w500, letterSpacing: -1),
                ),
                const Text('Mo/s', style: TextStyle(color: kMute, fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            _stat('Moyenne', '${_avg.toStringAsFixed(2)} Mo/s'),
            const SizedBox(width: 10),
            _stat('Maximum', '${_peak.toStringAsFixed(2)} Mo/s'),
            const SizedBox(width: 10),
            _stat('Reçu', '${_mb.toStringAsFixed(1)} Mo'),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _run ? null : _start,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(_run ? 'TEST EN COURS...' : 'LANCER LE TEST',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
            ),
          ),
          const SizedBox(height: 14),
          Text(_msg, style: const TextStyle(color: kMute, fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }
}
