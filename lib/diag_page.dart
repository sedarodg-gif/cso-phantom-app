import 'dart:async';
import 'dart:io' show HttpClient, InternetAddress, Socket;

import 'package:flutter/material.dart';

import 'main.dart';
import 'settings_page.dart';

/// Résultat d'une étape du diagnostic.
class _Step {
  final String title;
  int state = 0; // 0 en attente, 1 en cours, 2 réussi, 3 échec, 4 ignoré
  String detail = '';
  _Step(this.title);
}

/// Diagnostic réseau : dit précisément où ça bloque (téléphone, DNS, serveur, tunnel).
class DiagPage extends StatefulWidget {
  final String host;
  final int port;
  final bool vpnOn;
  final String checkUrl;
  const DiagPage({
    super.key,
    required this.host,
    required this.port,
    required this.vpnOn,
    required this.checkUrl,
  });

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  late final List<_Step> _steps = <_Step>[
    _Step('Accès Internet (par nom de domaine)'),
    _Step('Accès Internet (par adresse IP, sans DNS)'),
    _Step('Résolution DNS'),
    _Step('Serveur VPN joignable'),
    _Step('Vitesse de téléchargement'),
  ];
  bool _running = false;
  String _verdict = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<int> _http(String url, int secs) async {
    final client = HttpClient()..connectionTimeout = Duration(seconds: secs);
    final sw = Stopwatch()..start();
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(Duration(seconds: secs));
      final res = await req.close().timeout(Duration(seconds: secs));
      await res.drain<void>().timeout(Duration(seconds: secs));
      if (res.statusCode >= 200 && res.statusCode < 400) {
        return sw.elapsedMilliseconds < 1 ? 1 : sw.elapsedMilliseconds;
      }
      return -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  void _set(_Step s, int state, [String detail = '']) {
    if (!mounted) return;
    setState(() {
      s.state = state;
      s.detail = detail;
    });
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _verdict = '';
      for (final s in _steps) {
        s.state = 0;
        s.detail = '';
      }
    });

    // 1. par nom de domaine
    _set(_steps[0], 1);
    final a = await _http(widget.checkUrl, 7);
    _set(_steps[0], a > 0 ? 2 : 3, a > 0 ? '$a ms' : 'aucune réponse');

    // 2. par IP
    _set(_steps[1], 1);
    final b = await _http('https://1.1.1.1/cdn-cgi/trace', 7);
    _set(_steps[1], b > 0 ? 2 : 3, b > 0 ? '$b ms' : 'aucune réponse');

    // 3. DNS
    _set(_steps[2], 1);
    var dnsOk = false;
    try {
      final sw = Stopwatch()..start();
      final r = await InternetAddress.lookup('www.google.com').timeout(const Duration(seconds: 7));
      dnsOk = r.isNotEmpty;
      _set(_steps[2], dnsOk ? 2 : 3, dnsOk ? '${sw.elapsedMilliseconds} ms' : 'aucune adresse');
    } catch (_) {
      _set(_steps[2], 3, 'échec de la résolution');
    }

    // 4. serveur (seulement hors VPN : sinon le test passerait par le tunnel)
    var srvOk = false;
    var srvTested = false;
    if (widget.host.isEmpty || widget.port <= 0) {
      _set(_steps[3], 4, 'aucun serveur (ou configuration verrouillée)');
    } else if (widget.vpnOn) {
      _set(_steps[3], 4, 'ignoré : le VPN est actif (déconnecte-toi pour tester)');
    } else {
      _set(_steps[3], 1);
      srvTested = true;
      try {
        final sw = Stopwatch()..start();
        final sock = await Socket.connect(widget.host, widget.port, timeout: const Duration(seconds: 7));
        sock.destroy();
        srvOk = true;
        _set(_steps[3], 2, '${sw.elapsedMilliseconds} ms');
      } catch (_) {
        _set(_steps[3], 3, 'injoignable');
      }
    }

    // 5. vitesse (3 secondes)
    _set(_steps[4], 1);
    var mbps = -1.0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final req = await client
          .getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=20000000'))
          .timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final sw = Stopwatch()..start();
      var bytes = 0;
      await for (final c in res) {
        bytes += c.length;
        if (sw.elapsedMilliseconds >= 3000) break;
      }
      final secs = sw.elapsedMilliseconds / 1000;
      if (bytes > 0 && secs > 0) mbps = bytes / 1048576 / secs;
    } catch (_) {
      mbps = -1;
    } finally {
      client.close(force: true);
    }
    _set(_steps[4], mbps > 0 ? 2 : 3, mbps > 0 ? '${mbps.toStringAsFixed(2)} Mo/s' : 'aucune donnée reçue');

    // verdict
    String v;
    if (a > 0 && mbps > 0) {
      v = mbps < 0.15
          ? "Internet fonctionne mais le débit est très faible : essaie un autre serveur."
          : 'Tout fonctionne : ${widget.vpnOn ? "le tunnel laisse passer les données" : "ton réseau est en ordre"}.';
    } else if (a <= 0 && b > 0) {
      v = 'Le réseau répond par adresse IP mais pas par nom de domaine : problème de DNS. '
          'Dans Paramètres, choisis un DNS (Cloudflare ou Google).';
    } else if (a <= 0 && b <= 0 && widget.vpnOn) {
      v = 'Le tunnel est ouvert mais aucune donnée ne passe. Causes fréquentes : compte expiré ou limité à certains sites, '
          'mauvais SNI / Host / payload, serveur saturé. Essaie un autre serveur.';
    } else if (a <= 0 && b <= 0 && srvTested && !srvOk) {
      v = 'Ni Internet ni le serveur VPN ne répondent. Vérifie ta connexion mobile ou Wi-Fi, puis le serveur.';
    } else if (a <= 0 && b <= 0) {
      v = "Pas d'accès Internet sur le téléphone : vérifie ta connexion mobile ou Wi-Fi.";
    } else {
      v = 'Résultat mitigé : relance le diagnostic dans un instant.';
    }
    if (mounted) {
      setState(() {
        _verdict = v;
        _running = false;
      });
    }
  }

  Widget _row(_Step s) {
    final IconData ic;
    final Color c;
    switch (s.state) {
      case 2:
        ic = Icons.check_circle;
        c = kGreen;
        break;
      case 3:
        ic = Icons.cancel;
        c = kBad;
        break;
      case 4:
        ic = Icons.remove_circle_outline;
        c = kMute;
        break;
      default:
        ic = Icons.radio_button_unchecked;
        c = kMute;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: glass(r: 16),
      child: Row(children: [
        s.state == 1
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
            : Icon(ic, color: c, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.title, style: const TextStyle(fontSize: 14)),
              if (s.detail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(s.detail, style: TextStyle(fontSize: 12, color: c)),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: 'Diagnostic',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          Text(
            widget.vpnOn
                ? 'VPN connecté : le test mesure ce que le tunnel laisse passer.'
                : 'VPN déconnecté : le test mesure ton réseau et le serveur choisi.',
            style: const TextStyle(color: kMute, fontSize: 13),
          ),
          const SizedBox(height: 12),
          for (final s in _steps) _row(s),
          if (_verdict.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: glass(r: 18),
              child: Text(_verdict, style: const TextStyle(fontSize: 14, height: 1.45)),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? 'DIAGNOSTIC EN COURS...' : 'RELANCER'),
            ),
          ),
        ],
      ),
    );
  }
}
