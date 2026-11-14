import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io' show HttpClient, NetworkInterface;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server.dart';
import 'diag_page.dart';
import 'export_page.dart';
import 'qr_scan_page.dart';
import 'haunted_bg.dart';
import 'payload_editor.dart';
import 'speed_page.dart';
import 'settings.dart';
import 'settings_page.dart';
import 'ssh_engine.dart';

const kBg = Color(0xFF05030C);
const kRed = Color(0xFFA78BFA); // accent violet
const kBad = Color(0xFFFB7185);
const kCyan = Color(0xFF67E8F9);
const kMute = Color(0xFFB4A8E0);
const kGreen = Color(0xFF6FCF7F);
const kAmber = Color(0xFFE8C26A);

/// Version affichée dans l'application.
const kAppVersion = 'V8.5';

const kTypeNames = {
  'vless': 'VLESS',
  'vmess': 'VMess',
  'trojan': 'Trojan',
  'ss': 'SS',
  'ssh': 'SSH',
};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const CsoApp());
}

class CsoApp extends StatelessWidget {
  const CsoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CSO PHANTOM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kRed),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          },
        ),
      ),
      home: const SplashGate(),
    );
  }
}

BoxDecoration glass({double r = 26, bool sel = false}) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(r),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: sel
          ? [const Color(0x478B5CF6), const Color(0x0AFFFFFF)]
          : [const Color(0x1FFFFFFF), const Color(0x0AFFFFFF)],
    ),
    border: Border.all(
      color: sel ? kRed.withAlpha(200) : Colors.white.withAlpha(34),
      width: sel ? 1.5 : 1,
    ),
    boxShadow: [
      BoxShadow(
        color: sel ? const Color(0x558B5CF6) : Colors.black.withAlpha(110),
        blurRadius: sel ? 24 : 28,
        offset: const Offset(0, 10),
      ),
    ],
  );
}

String gSpeedUnit = 'MB';

({String v, String u}) speedParts(double bps) {
  switch (gSpeedUnit) {
    case 'Mb':
      return (v: (bps * 8 / 1000000).toStringAsFixed(2), u: 'Mb/s');
    case 'KB':
      return (v: (bps / 1024).toStringAsFixed(0), u: 'KB/s');
    default:
      // unité automatique : un petit débit s'affiche en KB/s ou en B/s au lieu de 0.00 MB/s
      if (bps >= 1048576) return (v: (bps / 1048576).toStringAsFixed(2), u: 'MB/s');
      if (bps >= 1024) return (v: (bps / 1024).toStringAsFixed(0), u: 'KB/s');
      return (v: bps.toStringAsFixed(0), u: 'B/s');
  }
}

/// Appelé par le chasseur d'IP : lance la connexion VPN si elle ne l'est pas déjà.
VoidCallback? gConnectHook;

String fmtRate(double b) {
  final p = speedParts(b);
  return '${p.v} ${p.u}';
}

String fmtBytes(double b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  var v = b;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

// ======================= RÉGLAGES DU MOTEUR =======================

/// Shadowsocks + plugin v2ray-plugin : WebSocket / TLS.
void _applySsStream(Map o, Server s) {
  if (s.net != 'ws' && s.sec != 'tls') return;
  final host = s.hosth.isNotEmpty ? s.hosth : (s.sni.isNotEmpty ? s.sni : s.host);
  final stream = <String, dynamic>{'network': s.net == 'ws' ? 'ws' : 'tcp'};
  if (s.net == 'ws') {
    stream['wsSettings'] = {
      'path': s.path.isEmpty ? '/' : s.path,
      'headers': {'Host': host},
    };
  }
  if (s.sec == 'tls') {
    stream['security'] = 'tls';
    stream['tlsSettings'] = {
      'serverName': s.sni.isNotEmpty ? s.sni : host,
      'allowInsecure': s.insecure,
    };
  }
  o['streamSettings'] = stream;
}

/// Ajuste la configuration Xray générée : TLS (allowInsecure, SNI), mux, DNS IPv4.
String tuneConfig(String cfg, Server s, AppSettings st) {
  try {
    final m = jsonDecode(cfg);
    if (m is! Map) return cfg;
    final outs = m['outbounds'];
    if (outs is List) {
      for (final o in outs) {
        if (o is! Map) continue;
        final proto = (o['protocol'] ?? '').toString();
        if (proto != 'vmess' && proto != 'vless' && proto != 'trojan' && proto != 'shadowsocks') {
          continue;
        }
        if (proto == 'shadowsocks') _applySsStream(o, s);
        final ss = o['streamSettings'];
        if (ss is Map) {
          final tls = ss['tlsSettings'];
          final hostH = s.hosth.isNotEmpty ? s.hosth.split(',').first.trim() : '';
          if (tls is Map) {
            tls['allowInsecure'] = s.insecure;
            // comme v2rayNG : SNI saisi, sinon l'en-tête Host, sinon on laisse le moteur décider
            final sn = s.sni.isNotEmpty ? s.sni : hostH;
            if (sn.isNotEmpty) tls['serverName'] = sn;
          }
          final ws = ss['wsSettings'];
          if (ws is Map && hostH.isNotEmpty) {
            final hd = ws['headers'] is Map ? Map<String, dynamic>.from(ws['headers'] as Map) : <String, dynamic>{};
            hd['Host'] = hostH;
            ws['headers'] = hd;
          }
        }
        if (s.mux && proto != 'shadowsocks' && (s.extra['flow'] ?? '').isEmpty) {
          o['mux'] = {'enabled': true, 'concurrency': 8};
        }
      }
    }
    if (st.blockQuic) {
      final outs2 = m['outbounds'];
      if (outs2 is List) {
        outs2.add({'tag': 'cso-block', 'protocol': 'blackhole', 'settings': <String, dynamic>{}});
      }
      final quic = {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'cso-block'};
      final rt = m['routing'];
      if (rt is Map) {
        final rl = rt['rules'];
        if (rl is List) {
          rl.insert(0, quic);
        } else {
          rt['rules'] = [quic];
        }
      } else {
        m['routing'] = {
          'domainStrategy': 'AsIs',
          'rules': [quic],
        };
      }
    }
    if (st.fast) {
      final r = m['routing'];
      if (r is Map) r['domainStrategy'] = 'AsIs';
      final d = m['dns'];
      if (d is Map) d['queryStrategy'] = 'UseIPv4';
    }
    final dnsList = st.dnsServers() ?? (s.extra['dnsfix'] == '1' ? kDnsPresets['cloudflare'] : null);
    if (dnsList != null && dnsList.isNotEmpty) {
      final d = m['dns'];
      if (d is Map) {
        d['servers'] = dnsList;
      } else {
        m['dns'] = {'servers': dnsList, 'queryStrategy': 'UseIPv4'};
      }
    }
    _applyPolicy(m, st.bufferKb);
    return jsonEncode(m);
  } catch (_) {
    return cfg;
  }
}

/// Tampon par connexion : plus grand = meilleur débit sur les gros transferts.
void _applyPolicy(Map m, int kb) {
  if (kb <= 0) return;
  final pol = m['policy'] is Map ? Map<String, dynamic>.from(m['policy'] as Map) : <String, dynamic>{};
  final lv = pol['levels'] is Map ? Map<String, dynamic>.from(pol['levels'] as Map) : <String, dynamic>{};
  final l0 = lv['0'] is Map ? Map<String, dynamic>.from(lv['0'] as Map) : <String, dynamic>{};
  l0['bufferSize'] = kb;
  lv['0'] = l0;
  pol['levels'] = lv;
  m['policy'] = pol;
}

/// SSH : on réutilise l'habillage Xray (TUN, DNS...) mais la sortie « proxy »
/// devient le proxy SOCKS5 local qui passe par le tunnel SSH.
String buildSshConfig(String base, List<int> ports, List<String> ips, {List<String>? dns, int bufferKb = 0}) {
  final m = Map<String, dynamic>.from(jsonDecode(base) as Map);
  final outs = List<dynamic>.from((m['outbounds'] as List?) ?? <dynamic>[]);
  final pool = ports.length > 1;
  Map<String, dynamic> socks(String tag, int port) => {
        'tag': tag,
        'protocol': 'socks',
        'settings': {
          'servers': [
            {'address': '127.0.0.1', 'port': port},
          ],
        },
      };
  var idx = outs.indexWhere((o) => o is Map && o['tag'] == 'proxy');
  if (idx < 0) idx = 0;
  if (!pool) {
    final proxy = socks('proxy', ports.first);
    if (outs.isEmpty) {
      outs.add(proxy);
    } else {
      outs[idx] = proxy;
    }
  } else {
    if (outs.isNotEmpty) outs.removeAt(idx);
    for (var i = 0; i < ports.length; i++) {
      outs.add(socks('ssh-p${i + 1}', ports[i]));
    }
  }
  outs.addAll(<Map<String, dynamic>>[
    {'tag': 'ssh-direct', 'protocol': 'freedom', 'settings': <String, dynamic>{}},
    {'tag': 'ssh-dns', 'protocol': 'dns', 'settings': <String, dynamic>{}},
    {'tag': 'ssh-block', 'protocol': 'blackhole', 'settings': <String, dynamic>{}},
  ]);
  m['outbounds'] = outs;

  final routing = m['routing'] is Map
      ? Map<String, dynamic>.from(m['routing'] as Map)
      : <String, dynamic>{};
  final rules = routing['rules'] is List
      ? List<dynamic>.from(routing['rules'] as List)
      : <dynamic>[];
  final pre = <Map<String, dynamic>>[];
  // le serveur SSH lui-même ne doit pas repasser dans le tunnel
  if (ips.isNotEmpty) {
    pre.add({'type': 'field', 'ip': ips, 'outboundTag': 'ssh-direct'});
  }
  // DNS UDP -> résolveur interne (DoH via le tunnel) ; autre UDP bloqué (SSH = TCP seulement)
  pre.add({'type': 'field', 'network': 'udp', 'port': '53', 'outboundTag': 'ssh-dns'});
  pre.add({'type': 'field', 'network': 'udp', 'outboundTag': 'ssh-block'});
  if (pool) {
    // répartit les connexions TCP sur plusieurs tunnels SSH
    final conv = <dynamic>[];
    for (final r in rules) {
      if (r is Map && r['outboundTag'] == 'proxy') {
        final c = Map<String, dynamic>.from(r);
        c.remove('outboundTag');
        c['balancerTag'] = 'cso-bal';
        conv.add(c);
      } else {
        conv.add(r);
      }
    }
    conv.add({'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'cso-bal'});
    routing['balancers'] = [
      {'tag': 'cso-bal', 'selector': ['ssh-p'], 'strategy': {'type': 'random'}},
    ];
    routing['rules'] = [...pre, ...conv];
  } else {
    routing['rules'] = [...pre, ...rules];
  }
  routing['domainStrategy'] = 'AsIs';
  m['routing'] = routing;

  // en SSH seuls les DNS « https:// » (DoH) passent correctement dans le tunnel
  final doh = (dns ?? <String>[]).where((e) => e.startsWith('https://')).toList();
  m['dns'] = {
    'servers': doh.isNotEmpty ? doh : ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
    'queryStrategy': 'UseIPv4',
  };
  _applyPolicy(m, bufferKb);
  return jsonEncode(m);
}

Path _ghostPath() => Path()
  ..moveTo(50, 8)
  ..cubicTo(28, 8, 14, 26, 14, 48)
  ..lineTo(14, 100)
  ..lineTo(26, 90)
  ..lineTo(38, 102)
  ..lineTo(50, 90)
  ..lineTo(62, 102)
  ..lineTo(74, 90)
  ..lineTo(86, 100)
  ..lineTo(86, 48)
  ..cubicTo(86, 26, 72, 8, 50, 8)
  ..close();

void _paintGhost(Canvas canvas, Offset topLeft, double scale, {bool glow = true}) {
  canvas.save();
  canvas.translate(topLeft.dx, topLeft.dy);
  canvas.scale(scale);
  final p = _ghostPath();
  if (glow) {
    canvas.drawPath(
      p,
      Paint()
        ..color = const Color(0xFFDDD6FE).withAlpha(190)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
  }
  canvas.drawPath(
    p,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFFFFF), Color(0xFFEDE9FE), Color(0xFFC4B5FD)],
        stops: [0.0, 0.7, 1.0],
      ).createShader(const Rect.fromLTWH(0, 8, 100, 94)),
  );
  final eye = Paint()..color = const Color(0xFF3B0F8C);
  canvas.drawOval(Rect.fromCenter(center: const Offset(38, 46), width: 13, height: 16), eye);
  canvas.drawOval(Rect.fromCenter(center: const Offset(62, 46), width: 13, height: 16), eye);
  canvas.drawOval(Rect.fromCenter(center: const Offset(50, 68), width: 11, height: 14), eye);
  canvas.save();
  canvas.translate(34, 26);
  canvas.rotate(-0.49);
  canvas.drawOval(
    Rect.fromCenter(center: Offset.zero, width: 20, height: 10),
    Paint()..color = Colors.white.withAlpha(150),
  );
  canvas.restore();
  canvas.restore();
}

/// Petit fantôme (logo).
class GhostPainter extends CustomPainter {
  const GhostPainter();

  @override
  void paint(Canvas canvas, Size size) {
    _paintGhost(canvas, Offset.zero, size.width / 100, glow: false);
  }

  @override
  bool shouldRepaint(covariant GhostPainter old) => false;
}

Path _wavePath(Rect r, double y0, double amp, double wl, double phase, {required bool fill}) {
  final p = Path();
  final first = y0 + amp * math.sin(phase);
  if (fill) {
    p.moveTo(r.left, r.bottom);
    p.lineTo(r.left, first);
  } else {
    p.moveTo(r.left, first);
  }
  for (var x = r.left; x <= r.right; x += 4) {
    p.lineTo(x, y0 + amp * math.sin((x - r.left) / wl * 2 * math.pi + phase));
  }
  if (fill) {
    p.lineTo(r.right, r.bottom);
    p.close();
  }
  return p;
}

/// Boule d'eau en verre : le fantôme flotte dedans, à moitié immergé.
class WaterOrbPainter extends CustomPainter {
  final double t; // 0..1, boucle
  final bool on;
  final OrbPalette pal;
  final int style; // 0 eau, 1 verre néon, 2 anneau
  const WaterOrbPainter(this.t, this.on, this.pal, this.style);

  @override
  void paint(Canvas canvas, Size size) {
    const tau = math.pi * 2;
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final r = s * 0.414;
    final box = Rect.fromCircle(center: c, radius: r);

    // halo
    canvas.drawCircle(
      c,
      s * 0.5,
      Paint()
        ..shader = RadialGradient(
          colors: [
            pal.glow.withAlpha(on ? 150 : 90),
            pal.glow.withAlpha(on ? 44 : 22),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: s * 0.5)),
    );

    // anneau orbital
    final ringR = s * 0.5 - 3;
    final dot = Paint()..color = pal.light.withAlpha(on ? 110 : 60);
    for (var i = 0; i < 72; i++) {
      final a = i * tau / 72 + t * tau;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * ringR, 1.1, dot);
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(t * tau);
    final arcRect = Rect.fromCircle(center: Offset.zero, radius: ringR - 7);
    canvas.drawArc(
      arcRect,
      0,
      1.8,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          endAngle: 1.8,
          colors: [pal.glow.withAlpha(on ? 255 : 120), pal.light.withAlpha(on ? 255 : 120)],
        ).createShader(arcRect),
    );
    canvas.restore();

    // lueur de la sphère
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = pal.glow.withAlpha(on ? 120 : 70)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(box));

    // verre
    canvas.drawRect(
      box,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.32, -0.46),
          radius: 0.95,
          colors: style == 2
              ? [pal.deep, pal.deep, Color.lerp(pal.deep, Colors.black, 0.45)!]
              : [pal.light, pal.mid, pal.deep],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(box),
    );

    // eau profonde
    final water = style == 0;
    final deep = Rect.fromLTRB(box.left, c.dy - r * 0.16, box.right, box.bottom);
    if (water) {
      canvas.drawRect(
        deep,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [pal.glow.withAlpha(0), pal.glow.withAlpha(66), pal.mid.withAlpha(102)],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(deep),
      );
    }

    // bulles
    for (var i = 0; i < (water ? 4 : 0); i++) {
      final ph = (t * 3 + i * 0.27) % 1.0;
      final x = c.dx + (i - 1.5) * r * 0.5 + math.sin(ph * tau + i) * 3;
      final y = c.dy + r * 0.9 - ph * r * 1.25;
      final a = (math.sin(ph * math.pi) * 210).round();
      final br = 2.0 + i * 1.1;
      canvas.drawCircle(Offset(x, y), br, Paint()..color = Colors.white.withAlpha((a * 0.25).round()));
      canvas.drawCircle(
        Offset(x, y),
        br,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withAlpha(a),
      );
    }

    // fantôme
    final gs = r * 0.0089;
    final bob = math.sin(t * tau * 2) * 5;
    final gTop = water ? c.dy - r * 0.755 + bob : c.dy - 56 * gs + bob * 0.4;
    _paintGhost(canvas, Offset(c.dx - 50 * gs, gTop), gs);

    // vagues (le fantôme est à moitié immergé)
    final wl = r * 1.04;
    if (water) {
      canvas.drawPath(
        _wavePath(box, c.dy - r * 0.06, r * 0.04, wl, -t * tau, fill: true),
        Paint()..color = pal.glow.withAlpha(77),
      );
      canvas.drawPath(
        _wavePath(box, c.dy + r * 0.04, r * 0.05, wl, t * tau * 2, fill: true),
        Paint()..color = pal.mid.withAlpha(128),
      );
      canvas.drawPath(
        _wavePath(box, c.dy + r * 0.04, r * 0.05, wl, t * tau * 2, fill: false),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withAlpha(140),
      );
    }

    // lumière caustique
    final cau = Rect.fromCenter(center: Offset(c.dx, c.dy + r * 0.98), width: r * 1.5, height: r * 0.8);
    if (water) {
      canvas.drawOval(
        cau,
        Paint()
          ..shader = RadialGradient(
            colors: [pal.glow.withAlpha(140), pal.glow.withAlpha(0)],
          ).createShader(cau),
      );
    }

    // bord de la sphère
    canvas.drawRect(
      box,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.transparent, Colors.transparent, pal.glow.withAlpha(style == 2 ? 20 : 70)],
          stops: const [0.0, 0.72, 1.0],
        ).createShader(box),
    );

    // reflets
    if (style != 2) {
    canvas.save();
    canvas.translate(c.dx - r * 0.42, c.dy - r * 0.68);
    canvas.rotate(-0.45);
    final hl = Rect.fromCenter(center: Offset.zero, width: r * 0.98, height: r * 0.52);
    canvas.drawOval(
      hl,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withAlpha(185), Colors.white.withAlpha(10)],
        ).createShader(hl),
    );
    canvas.restore();
    canvas.drawCircle(
      Offset(c.dx + r * 0.55, c.dy - r * 0.52),
      r * 0.06,
      Paint()..color = Colors.white.withAlpha(180),
    );
    }
    canvas.restore();

    // contour de verre
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = style == 2 ? 3 : 1.5
        ..color = style == 2 ? pal.glow : Colors.white.withAlpha(100),
    );
  }

  @override
  bool shouldRepaint(covariant WaterOrbPainter old) =>
      old.t != t || old.on != on || old.pal != pal || old.style != style;
}

/// Emblème original à 3 pales.
class EmblemPainter extends CustomPainter {
  final Color color;
  const EmblemPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100);
    canvas.drawCircle(
      const Offset(50, 50),
      44,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
    final blade = Path()
      ..moveTo(50, 50)
      ..cubicTo(50, 28, 66, 16, 84, 22)
      ..cubicTo(74, 26, 68, 36, 70, 50)
      ..close();
    final fill = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      canvas.save();
      canvas.translate(50, 50);
      canvas.rotate(i * 2 * math.pi / 3);
      canvas.translate(-50, -50);
      canvas.drawPath(blade, fill);
      canvas.restore();
    }
    canvas.drawCircle(const Offset(50, 50), 9, Paint()..color = const Color(0xFF2B0508));
    canvas.drawCircle(const Offset(50, 50), 5, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EmblemPainter old) => old.color != color;
}

/// Courbe du trafic réel : téléchargement (rouge) et envoi (rouge clair).
class ChartPainter extends CustomPainter {
  final List<double> dl;
  final List<double> ul;
  const ChartPainter(this.dl, this.ul);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white.withAlpha(20)
      ..strokeWidth = 1;
    for (var i = 1; i < 6; i++) {
      final y = size.height * i / 6;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    var mx = 256 * 1024.0; // échelle minimale : 0,25 MB/s
    for (final v in dl) {
      if (v > mx) mx = v;
    }
    for (final v in ul) {
      if (v > mx) mx = v;
    }
    _line(canvas, size, ul, mx, kCyan, 1.8);
    _line(canvas, size, dl, mx, kRed, 2.6);
  }

  void _line(Canvas canvas, Size size, List<double> d, double mx, Color col, double w) {
    if (d.length < 2) return;
    final pts = <Offset>[
      for (var i = 0; i < d.length; i++)
        Offset(
          size.width * i / (d.length - 1),
          size.height * 0.96 - (d[i] / mx) * size.height * 0.88,
        ),
    ];
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < pts.length; i++) {
      final cx = (pts[i - 1].dx + pts[i].dx) / 2;
      path.cubicTo(cx, pts[i - 1].dy, cx, pts[i].dy, pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant ChartPainter old) => true;
}

/// Écran de démarrage : l'image s'affiche ~2,5 s puis s'estompe pendant que l'appli se charge dessous.
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _gone = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const HomePage(),
        if (!_removed)
          IgnorePointer(
            ignoring: _gone,
            child: AnimatedOpacity(
              opacity: _gone ? 0 : 1,
              duration: const Duration(milliseconds: 600),
              onEnd: () {
                if (mounted) setState(() => _removed = true);
              },
              child: SizedBox.expand(
                child: Image.asset('assets/splash.jpg', fit: BoxFit.cover),
              ),
            ),
          ),
      ],
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  static const _shareCh = MethodChannel('cso/share');

  SharedPreferences? _prefs;
  List<Server> _servers = [];
  String? _selId;
  int _tab = 0;

  // connexion : off | connecting | on
  String _state = 'off';
  int _sec = 0;
  int _startMs = 0; // heure de début de la session VPN (ms), pour que le chrono survive à la fermeture de l'appli
  int _totalSecs = 0;
  int _conns = 0;

  // SSH
  final List<SshEngine> _sshEngines = <SshEngine>[];
  final Map<int, List<double>> _poolStat = <int, List<double>>{};
  bool _sshMode = false;

  // trafic
  double _dlBps = 0; // vitesse annoncée par le plugin (octets/s)
  double _ulBps = 0;
  bool _warned80 = false;
  double _dlTotal = 0; // total de la session (octets)
  double _ulTotal = 0;
  double? _prevDl;
  double? _prevUl;
  double _dlShown = 0;
  double _ulShown = 0;
  double _totDl = 0; // cumul enregistré
  double _totUl = 0;
  Map<String, double> _daily = <String, double>{}; // octets échangés par jour (aaaa-mm-jj)
  String _hwid = ''; // identifiant de cet appareil
  final List<double> _dlData = List<double>.filled(30, 0.0, growable: true);
  final List<double> _ulData = List<double>.filled(30, 0.0, growable: true);

  // test d'accès Internet : null = en cours, -1 = échec, >0 = ms
  int? _ping;
  bool _checking = false;
  final Map<String, int> _pings = {};
  String _q = ''; // recherche de serveur
  int _sortMode = 0; // 0 ordre normal, 1 nom, 2 ping

  Timer? _ticker;
  Timer? _timeout;
  bool _inited = false;
  AppSettings _st = AppSettings();
  final List<String> _logs = [];
  bool _userStop = false;
  bool _reconnecting = false;
  int _retries = 0;
  int _switches = 0; // changements de serveur automatiques déjà faits
  bool _testingAll = false;
  int _fails = 0;

  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
  late final FlutterVless _vless = FlutterVless(onStatusChanged: _onStatus);

  @override
  void initState() {
    super.initState();
    gConnectHook = () {
      if (mounted && _state == 'off') _toggle();
    };
    // à l'ouverture : on reprend un VPN encore actif au lieu de le couper
    _load().then((_) => _startupSync());
  }

  /// Vrai si une interface VPN (tun) est présente sur le téléphone.
  Future<bool> _tunPresent() async {
    try {
      final l = await NetworkInterface.list();
      return l.any((i) => i.name.toLowerCase().startsWith('tun'));
    } catch (_) {
      return false;
    }
  }

  /// Appli rouverte après avoir été fermée : si le VPN tourne encore et laisse passer
  /// Internet, on reprend la session sans la couper ; sinon on nettoie.
  Future<void> _startupSync() async {
    var was = false;
    var startMs = 0;
    try {
      final p = await SharedPreferences.getInstance();
      was = p.getBool('vpnOn') ?? false;
      startMs = p.getInt('vpnStart') ?? 0;
    } catch (_) {}
    if (!mounted) return;
    if (was && _selected != null && await _tunPresent()) {
      await _ensureInit();
      final d = await _httpCheck();
      if (!mounted) return;
      if (d > 0) {
        setState(() => _setOn(resume: startMs > 0 ? startMs : DateTime.now().millisecondsSinceEpoch));
        _log('VPN toujours actif : session reprise (le chrono continue)');
        return;
      }
    }
    await _killVpn();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('vpnOn', false);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _timeout?.cancel();
    for (final e in _sshEngines) {
      e.stop();
    }
    _spin.dispose();
    super.dispose();
  }

  // ---------- stockage ----------
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    final raw = p.getString('servers');
    if (raw != null) {
      try {
        final l = jsonDecode(raw) as List;
        _servers = l.map((e) => Server.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      } catch (_) {}
    }
    _selId = p.getString('sel');
    try {
      _hwid = (await _shareCh.invokeMethod<String>('deviceId')) ?? '';
    } catch (_) {}
    _conns = p.getInt('conns') ?? 0;
    _totalSecs = p.getInt('secs') ?? 0;
    _totDl = p.getDouble('totdl') ?? 0;
    _totUl = p.getDouble('totul') ?? 0;
    try {
      final dj = p.getString('daily');
      if (dj != null) {
        final m = jsonDecode(dj) as Map;
        _daily = m.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
      }
    } catch (_) {
      _daily = <String, double>{};
    }
    final sj = p.getString('settings');
    if (sj != null) {
      try {
        _st = AppSettings.fromJson(Map<String, dynamic>.from(jsonDecode(sj) as Map));
      } catch (_) {}
    } else {
      final o = p.getString('opts');
      if (o != null) {
        try {
          final m = jsonDecode(o) as Map;
          _st.fast = m['fast'] != false;
          _st.autoReconnect = m['auto'] != false;
          _st.lan = m['lan'] == true;
        } catch (_) {}
      }
    }
    gSpeedUnit = _st.speedUnit;
    gGlows = themeGlows(_st.theme);
    _applyAnim();
    if (_selId != null && !_servers.any((s) => s.id == _selId)) _selId = null;
    if (mounted) setState(() {});
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setString('servers', jsonEncode(_servers.map((s) => s.toJson()).toList()));
    if (_selId != null) {
      p.setString('sel', _selId!);
    } else {
      p.remove('sel');
    }
    p.setInt('conns', _conns);
    p.setInt('secs', _totalSecs);
    p.setDouble('totdl', _totDl);
    p.setDouble('totul', _totUl);
    p.setString('daily', jsonEncode(_daily));
    p.setString('settings', jsonEncode(_st.toJson()));
  }

  Server? get _selected {
    for (final s in _servers) {
      if (s.id == _selId) return s;
    }
    return null;
  }

  void _applyAnim() {
    if (_st.orbAnim) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  void _log(String m) {
    final t = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    _logs.add('[${p(t.hour)}:${p(t.minute)}:${p(t.second)}] $m');
    final lim = _st.logLimit < 50 ? 50 : _st.logLimit;
    if (_logs.length > lim) _logs.removeRange(0, _logs.length - lim);
  }

  void _settingsChanged() {
    gSpeedUnit = _st.speedUnit;
    gGlows = themeGlows(_st.theme);
    _applyAnim();
    _save();
    if (mounted) setState(() {});
  }

  void _resetSettings() {
    _st.resetDefaults();
    _settingsChanged();
  }

  void _openLog() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LogPage(
          host: SettingsHost(
            st: _st,
            changed: _settingsChanged,
            logs: () => _logs,
            clearLogs: () => _logs.clear(),
            exportAll: () => _openShare(_servers),
            resetSettings: _resetSettings,
          ),
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          host: SettingsHost(
            st: _st,
            changed: _settingsChanged,
            logs: () => _logs,
            clearLogs: () => _logs.clear(),
            exportAll: () => _openShare(_servers),
            resetSettings: _resetSettings,
          ),
        ),
      ),
    );
  }

  List<String> _lanSubnets() =>
      _st.lan ? <String>['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'] : <String>[];

  void _toast(String m) {
    _log(m);
    if (!mounted) return;
    final sm = ScaffoldMessenger.of(context);
    sm.hideCurrentSnackBar();
    sm.showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ));
  }

  // ---------- VPN ----------
  /// Coupe le service VPN natif (notification « Connected »), quoi qu'il arrive.
  Future<void> _killVpn() async {
    try {
      await _ensureInit();
      await _vless.stopVless();
    } catch (_) {}
  }

  Future<void> _ensureInit() async {
    if (_inited) return;
    await _vless.initializeVless(
      providerBundleIdentifier: 'com.csophantom.cso_phantom',
      groupIdentifier: 'group.com.csophantom.cso_phantom',
    );
    _inited = true;
  }

  ({String remark, String config}) _build(Server s) {
    final parsed = FlutterVless.parse(toLink(s, core: true));
    return (
      remark: parsed.remark,
      config: (_st.compat || s.extra['raw'] == '1')
          ? parsed.getFullConfiguration()
          : tuneConfig(parsed.getFullConfiguration(), s, _st),
    );
  }

  Map<String, dynamic> _sshCfg(Server s) => {
        'host': s.host,
        'port': s.port,
        'user': s.user,
        'pass': s.pass,
        'tls': s.sec == 'tls',
        'insecure': s.insecure,
        'sni': s.sni,
        'hosth': s.hosth,
        'payload': s.payload,
        'proxy': s.proxy,
        'keepAlive': _st.sshKeepAlive,
      };

  void _onStatus(dynamic st) {
    var s = '';
    try {
      s += st.state.toString().toUpperCase();
    } catch (_) {}
    try {
      s += ' ${st.connectionState.name.toString().toUpperCase()}';
    } catch (_) {}
    if (!_sshMode) {
      try {
        final d = st.downloadSpeed;
        if (d is num) _dlBps = d.toDouble();
      } catch (_) {}
      try {
        final u = st.uploadSpeed;
        if (u is num) _ulBps = u.toDouble();
      } catch (_) {}
      try {
        final d = st.download;
        if (d is num) _dlTotal = d.toDouble();
      } catch (_) {}
      try {
        final u = st.upload;
        if (u is num) _ulTotal = u.toDouble();
      } catch (_) {}
    }
    if (!mounted) return;
    if (s.contains('DISCONNECT')) {
      if (_state == 'on') {
        final byUser = _userStop;
        _log('VPN déconnecté');
        _setOff();
        if (!byUser) _maybeAutoRetry('VPN coupé');
      }
    } else if (s.contains('CONNECTED')) {
      if (_state != 'on') _setOn();
    }
    setState(() {});
  }

  void _onSshEvent(int i, Map<String, dynamic> m) {
    if (!mounted) return;
    final t = m['t'];
    if (t == 'stat') {
      _poolStat[i] = [(m['up'] as num).toDouble(), (m['down'] as num).toDouble()];
      var u = 0.0, d = 0.0;
      for (final v in _poolStat.values) {
        u += v[0];
        d += v[1];
      }
      _ulTotal = u;
      _dlTotal = d;
    } else if (t == 'log') {
      _log('SSH : ${m['msg'] ?? ''}');
    } else if (t == 'closed' || t == 'error') {
      // une connexion supplémentaire qui tombe n'arrête pas le VPN
      if (i > 0 && _sshEngines.length > 1) {
        _log('SSH #${i + 1} fermée');
        return;
      }
      if (_state != 'off') {
        final msg = (m['msg'] ?? '').toString();
        _toast(msg.isEmpty ? 'Connexion SSH perdue' : 'Connexion SSH perdue : $msg');
        _disconnectAll().then((_) => _maybeAutoRetry('SSH coupé'));
      }
    }
  }

  void _stopSsh() {
    for (final e in _sshEngines) {
      e.stop();
    }
    _sshEngines.clear();
    _poolStat.clear();
    _sshMode = false;
  }

  Future<void> _disconnectAll() async {
    try {
      await _vless.stopVless();
    } catch (_) {}
    if (!mounted) return;
    setState(_setOff);
  }

  void _maybeAutoRetry(String why) {
    if (!_st.autoReconnect || _userStop) return;
    if (_retries >= _st.reconnectTries) {
      if (_st.autoSwitch && _servers.length > 1 && _switches < _servers.length - 1) {
        final i = _servers.indexWhere((e) => e.id == _selId);
        final next = _servers[(i + 1) % _servers.length];
        _switches++;
        _retries = 0;
        _selId = next.id;
        _save();
        _log('Changement automatique de serveur : ${next.name}');
        _toast('Serveur suivant : ${next.name}');
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted && _state == 'off' && !_userStop) _toggle(auto: true);
        });
        return;
      }
      _log('Reconnexion abandonnée après $_retries tentative(s)');
      return;
    }
    _retries++;
    _log('$why : reconnexion ($_retries/${_st.reconnectTries})');
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted && _state == 'off' && !_userStop) _toggle(auto: true);
    });
  }

  Future<void> _reconnect(String why) async {
    if (_reconnecting) return;
    _reconnecting = true;
    _log('Reconnexion : $why');
    try {
      _userStop = true;
      try {
        await _vless.stopVless();
      } catch (_) {}
      if (!mounted) return;
      setState(_setOff);
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      _userStop = false;
      await _toggle(auto: true);
    } finally {
      _reconnecting = false;
    }
  }

  void _setOn({int resume = 0}) {
    _timeout?.cancel();
    _userStop = false;
    _fails = 0;
    _switches = 0;
    if (_st.haptics) HapticFeedback.lightImpact();
    _log('VPN connecté');
    _state = 'on';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _startMs = resume > 0 ? resume : nowMs;
    SharedPreferences.getInstance().then((p) {
      p.setBool('vpnOn', true);
      if (resume == 0) p.setInt('vpnStart', nowMs);
    });
    _sec = resume > 0 ? ((nowMs - resume) ~/ 1000) : 0;
    if (resume == 0) _conns++;
    _prevDl = null;
    _prevUl = null;
    _ping = null;
    _save();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    Future<void>.delayed(const Duration(seconds: 2), _checkNet);
    final cm = resume > 0 ? '' : (_selected?.connMsg ?? '');
    if (cm.isNotEmpty) {
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted && _state == 'on') _showInfo('Message', cm);
      });
    }
  }

  void _showInfo(String title, String text) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10121A),
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void _addDaily(double bytes) {
    if (bytes <= 0) return;
    final k = _dayKey(DateTime.now());
    _daily[k] = (_daily[k] ?? 0) + bytes;
    if (_daily.length > 40) {
      final keys = _daily.keys.toList()..sort();
      for (final old in keys.take(_daily.length - 31)) {
        _daily.remove(old);
      }
    }
  }

  void _tick() {
    if (!mounted) return;
    var dl = _dlBps;
    var ul = _ulBps;
    final pd = _prevDl;
    final pu = _prevUl;
    if (pd != null && _dlTotal >= pd) {
      final d = _dlTotal - pd;
      if (d > dl) dl = d;
      _totDl += d;
      _addDaily(d);
    }
    if (pu != null && _ulTotal >= pu) {
      final u = _ulTotal - pu;
      if (u > ul) ul = u;
      _totUl += u;
      _addDaily(u);
    }
    _prevDl = _dlTotal;
    _prevUl = _ulTotal;
    setState(() {
      // chrono basé sur l'heure réelle : il continue même si l'appli a été fermée
      _sec = _startMs > 0 ? ((DateTime.now().millisecondsSinceEpoch - _startMs) ~/ 1000) : _sec + 1;
      _totalSecs++;
      _dlShown = dl;
      _ulShown = ul;
      _dlData.add(dl);
      _dlData.removeAt(0);
      _ulData.add(ul);
      _ulData.removeAt(0);
    });
    if (_state == 'on' && !_userStop) {
      final lim = _st.autoStopMin;
      final cap = _st.dataLimitMb;
      if (lim > 0 && _sec >= lim * 60) {
        _toast('Minuteur atteint : VPN coupé');
        _toggle();
        return;
      }
      if (cap > 0 && !_warned80 && (_dlTotal + _ulTotal) >= cap * 1048576.0 * 0.8) {
        _warned80 = true;
        HapticFeedback.heavyImpact();
        _toast('Attention : 80 pour cent de ta limite de données utilisée');
      }
      if (cap > 0 && (_dlTotal + _ulTotal) >= cap * 1048576.0) {
        _toast('Limite de données atteinte : VPN coupé');
        _toggle();
        return;
      }
    }
    if (_sec % 10 == 0) _save();
    if (_sec >= 60 && _retries > 0) _retries = 0;
    final iv = _st.checkInterval;
    if (iv > 0 && _sec > 0 && _sec % iv == 0) _autoCheck();
  }

  void _setOff() {
    _timeout?.cancel();
    _ticker?.cancel();
    _stopSsh();
    _state = 'off';
    SharedPreferences.getInstance().then((p) => p.setBool('vpnOn', false));
    _startMs = 0;
    _sec = 0;
    _dlBps = 0;
    _ulBps = 0;
    _dlTotal = 0;
    _ulTotal = 0;
    _warned80 = false;
    _dlShown = 0;
    _ulShown = 0;
    _prevDl = null;
    _prevUl = null;
    _ping = null;
    for (var i = 0; i < _dlData.length; i++) {
      _dlData[i] = 0;
      _ulData[i] = 0;
    }
    _save();
  }

  /// Requête HTTP réelle (passe par le tunnel) : durée en ms, ou -1 si échec.
  Future<int> _httpCheck([String? url, int? secs]) async {
    final t = secs ?? _st.checkTimeout;
    final to = Duration(seconds: t < 3 ? 3 : t);
    final client = HttpClient()..connectionTimeout = to;
    final sw = Stopwatch()..start();
    try {
      final req = await client.getUrl(Uri.parse(url ?? _st.checkUrl)).timeout(to);
      req.headers.set('Cache-Control', 'no-cache');
      final res = await req.close().timeout(to);
      await res.drain<void>().timeout(to);
      final ok = res.statusCode >= 200 && res.statusCode < 400;
      return ok ? (sw.elapsedMilliseconds < 1 ? 1 : sw.elapsedMilliseconds) : -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  /// Vérifie que le tunnel donne vraiment accès à Internet.
  String _diag = ''; // dernier diagnostic réseau (affiché sous la pastille)
  int _heal = 0; // étapes d'auto-réparation déjà tentées pour cette connexion

  Future<void> _checkNet({bool quiet = false}) async {
    if (_state != 'on' || _checking) return;
    _checking = true;
    if (!quiet && mounted) setState(() => _ping = null);
    var d = await _httpCheck();
    if (d <= 0 && _state == 'on') {
      // le tunnel vient peut-être juste de s'ouvrir : un second essai avant de conclure
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_state == 'on') d = await _httpCheck();
    }
    if (d <= 0 && !_sshMode) {
      try {
        final dynamic r = await _vless.getConnectedServerDelay();
        d = r is num ? r.toInt() : -1;
      } catch (_) {
        d = -1;
      }
    }
    var healed = false;
    if (d <= 0 && !_sshMode && _state == 'on') {
      // diagnostic : le tunnel répond-il par adresse IP (sans DNS) ?
      final ip = await _httpCheck('https://1.1.1.1/cdn-cgi/trace', 6);
      final srv = _selected;
      if (ip > 0) {
        _diag = 'Tunnel ouvert, mais les noms de domaine ne se résolvent pas (DNS).';
        _log('Diagnostic : le tunnel répond par IP (${ip}ms) mais pas par nom de domaine : problème DNS');
        d = ip;
        if (srv != null && srv.extra['dnsfix'] != '1' && _heal < 1) {
          _heal = 1;
          srv.extra['dnsfix'] = '1';
          _save();
          _log('Réparation : DNS Cloudflare imposé, reconnexion');
          healed = true;
        }
      } else {
        _diag = 'Tunnel ouvert, mais aucune donnée ne revient : compte expiré/limité, mauvais SNI/Host ou serveur hors service.';
        _log('Diagnostic : aucune réponse du tunnel, même par IP');
        if (srv != null && srv.extra['raw'] != '1' && _heal < 2) {
          _heal = 2;
          srv.extra['raw'] = '1';
          _save();
          _log('Réparation : configuration brute (sans mes réglages), reconnexion');
          healed = true;
        } else if (srv != null && srv.extra['raw'] == '1') {
          srv.extra.remove('raw');
          _save();
          _log('Même la configuration brute échoue : le compte ou le serveur ne répond pas');
        }
      }
    }
    _checking = false;
    if (!mounted || _state != 'on') return;
    if (d > 0 && _diag.isNotEmpty && !healed) _diag = '';
    setState(() => _ping = d > 0 ? d : -1);
    _log(d > 0 ? 'HTTP Ping 200 OK (${d}ms)' : 'Test de connexion : échec');
    if (healed) _reconnect('réparation automatique');
  }

  /// Auto Ping : test régulier, avec action après plusieurs échecs de suite.
  Future<void> _autoCheck() async {
    if (_state != 'on' || _checking) return;
    await _checkNet(quiet: true);
    if (_state != 'on') return;
    final bad = (_ping ?? -1) <= 0;
    if (!bad) {
      _fails = 0;
      return;
    }
    _fails++;
    final lim = _st.checkFails;
    if (lim > 0 && _fails >= lim) {
      _fails = 0;
      if (_st.failAction == 'reconnect') {
        _reconnect('connexion sans réponse');
      } else if (_st.failAction == 'stop') {
        _toast('Connexion sans réponse : VPN coupé');
        await _toggle();
      }
    }
  }

  Future<void> _toggle({bool auto = false}) async {
    if (!auto && _st.haptics) HapticFeedback.mediumImpact();
    if (_state == 'connecting') return;
    if (_state == 'on') {
      _userStop = true;
      try {
        await _vless.stopVless();
      } catch (_) {}
      setState(_setOff);
      _toast('Déconnecté');
      return;
    }
    _userStop = false;
    if (!auto) {
      _retries = 0;
      _heal = 0;
      _switches = 0;
      // les réparations automatiques ne restent pas d'une connexion à l'autre
      final cur = _selected;
      if (cur != null) {
        cur.extra.remove('raw');
        cur.extra.remove('dnsfix');
      }
    }
    _log('Connexion...');
    final s = _selected;
    if (s == null) {
      _toast("Ajoute d'abord un serveur");
      setState(() => _tab = 1);
      return;
    }
    if (s.expired) {
      _toast('Cette configuration a expiré');
      return;
    }
    if (s.hwidList.isNotEmpty) {
      String id = '';
      try {
        id = ((await _shareCh.invokeMethod<String>('deviceId')) ?? '').toLowerCase();
      } catch (_) {}
      if (id.isEmpty || !s.hwidList.contains(id)) {
        _toast("Cette configuration n'est pas autorisée sur cet appareil");
        return;
      }
    }
    await _killVpn(); // repart d'un service propre
    await Future<void>.delayed(const Duration(milliseconds: 500)); // laisse Android fermer l'ancien tunnel
    if (s.type == 'ssh') {
      await _connectSsh(s);
      return;
    }
    setState(() {
      _state = 'connecting';
      _ping = null;
      _sshMode = false;
    });
    try {
      final b = _build(s);
      await _ensureInit();
      final ok = await _vless.requestPermission();
      if (!ok) {
        setState(() => _state = 'off');
        _toast('Permission VPN refusée');
        return;
      }
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 25), () {
        if (_state == 'connecting' && mounted) {
          setState(() => _state = 'off');
          _killVpn();
          _toast('Délai dépassé : vérifie ton compte');
        }
      });
      await _vless.startVless(
        remark: b.remark,
        config: b.config,
        bypassSubnets: _lanSubnets(),
        blockedApps: List<String>.from(_st.excludedApps),
        notificationDisconnectButtonName: 'DISCONNECT',
      );
    } catch (e) {
      _timeout?.cancel();
      if (mounted) setState(() => _state = 'off');
      _killVpn();
      _toast('Échec : $e');
    }
  }

  Future<void> _connectSsh(Server s) async {
    setState(() {
      _state = 'connecting';
      _ping = null;
      _sshMode = true;
    });
    try {
      final n = _st.sshPool.clamp(1, 4).toInt();
      final scfg = _sshCfg(s);
      final engines = <SshEngine>[
        for (var i = 0; i < n; i++) SshEngine((Map<String, dynamic> m) => _onSshEvent(i, m)),
      ];
      _sshEngines
        ..clear()
        ..addAll(engines);
      _poolStat.clear();
      await engines[0].start(scfg);
      var okList = <SshEngine>[engines[0]];
      if (n > 1) {
        final res = await Future.wait<bool>([
          for (var i = 1; i < n; i++)
            engines[i].start(scfg).then<bool>((_) => true).catchError((Object _) => false),
        ]);
        for (var i = 1; i < n; i++) {
          if (res[i - 1]) {
            okList.add(engines[i]);
          } else {
            engines[i].stop();
          }
        }
        _log('SSH : ${okList.length}/$n connexions actives');
      }
      final ips = <String>{for (final e in okList) ...e.ips}.toList();
      final ports = [for (final e in okList) e.port];
      final scaffold = FlutterVless.parse(
        'vless://00000000-0000-0000-0000-000000000000@127.0.0.1:1?type=tcp&security=none#ssh',
      );
      final cfg = buildSshConfig(scaffold.getFullConfiguration(), ports, ips, dns: _st.dnsServers(), bufferKb: _st.bufferKb);
      await _ensureInit();
      final ok = await _vless.requestPermission();
      if (!ok) {
        _stopSsh();
        if (mounted) setState(() => _state = 'off');
        _toast('Permission VPN refusée');
        return;
      }
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 25), () {
        if (_state == 'connecting' && mounted) {
          _stopSsh();
          setState(() => _state = 'off');
          _killVpn();
          _toast('Délai dépassé pendant le démarrage du VPN');
        }
      });
      await _vless.startVless(
        remark: s.name,
        config: cfg,
        bypassSubnets: _lanSubnets(),
        blockedApps: List<String>.from(_st.excludedApps),
        notificationDisconnectButtonName: 'DISCONNECT',
      );
    } catch (e) {
      _timeout?.cancel();
      _stopSsh();
      if (mounted) setState(() => _state = 'off');
      _killVpn();
      _toast('SSH : $e');
    }
  }

  Future<void> _testServer(Server s) async {
    if (s.type == 'ssh') {
      if (_state != 'off') {
        _toast('Déconnecte-toi pour tester un serveur SSH');
        return;
      }
      _toast('Test SSH en cours...');
      final sw = Stopwatch()..start();
      final eng = SshEngine((Map<String, dynamic> _) {});
      var ms = -1;
      String err = '';
      try {
        await eng.start(_sshCfg(s));
        ms = sw.elapsedMilliseconds;
      } catch (e) {
        err = e.toString();
      }
      eng.stop();
      if (!mounted) return;
      setState(() => _pings[s.id] = ms > 0 ? ms : -1);
      _toast(ms > 0 ? 'SSH OK : connecté en $ms ms' : 'SSH échec : $err');
      return;
    }
    _toast('Test en cours...');
    var d = -1;
    try {
      await _ensureInit();
      final b = _build(s);
      final dynamic r = (_state == 'on' && s.id == _selId)
          ? await _vless.getConnectedServerDelay()
          : await _vless.getServerDelay(config: b.config);
      d = r is num ? r.toInt() : -1;
    } catch (_) {
      d = -1;
    }
    if (!mounted) return;
    setState(() => _pings[s.id] = d > 0 ? d : -1);
    _toast(d > 0
        ? 'Ping : $d ms'
        : 'Test échoué : serveur injoignable ou réglages incorrects');
  }

  /// Mesure la latence d'un serveur sans message (-1 = échec).
  Future<int> _measure(Server s) async {
    if (s.type == 'ssh') {
      if (_state != 'off') return -1;
      final sw = Stopwatch()..start();
      final eng = SshEngine((Map<String, dynamic> _) {});
      var ms = -1;
      try {
        await eng.start(_sshCfg(s));
        ms = sw.elapsedMilliseconds;
      } catch (_) {
        ms = -1;
      }
      eng.stop();
      return ms > 0 ? ms : -1;
    }
    try {
      await _ensureInit();
      final b = _build(s);
      final dynamic r = (_state == 'on' && s.id == _selId)
          ? await _vless.getConnectedServerDelay()
          : await _vless.getServerDelay(config: b.config);
      final d = r is num ? r.toInt() : -1;
      return d > 0 ? d : -1;
    } catch (_) {
      return -1;
    }
  }

  /// Teste tous les serveurs un par un, les classe du plus rapide au plus lent
  /// et, si [pick] est vrai, choisit le meilleur.
  Future<void> _testAll({bool pick = false}) async {
    if (_testingAll) return;
    if (_servers.isEmpty) {
      _toast('Aucun serveur à tester');
      return;
    }
    if (pick && _state != 'off') {
      _toast('Déconnecte-toi pour choisir le meilleur serveur');
      return;
    }
    setState(() => _testingAll = true);
    _toast('Test de ${_servers.length} serveur(s)...');
    for (final s in List<Server>.from(_servers)) {
      if (!mounted) return;
      final ms = s.expired ? -1 : await _measure(s);
      if (!mounted) return;
      setState(() => _pings[s.id] = ms);
    }
    if (!mounted) return;
    int rank(Server e) {
      final p = _pings[e.id] ?? -1;
      return p > 0 ? p : 1 << 30;
    }

    setState(() {
      _servers.sort((a, b) => rank(a).compareTo(rank(b)));
      _testingAll = false;
    });
    _save();
    final best = _servers.first;
    if (rank(best) >= (1 << 30)) {
      _toast('Aucun serveur ne répond');
      return;
    }
    if (pick && _state == 'off') {
      setState(() => _selId = best.id);
      _save();
      _toast('Meilleur serveur : ${best.name} (${rank(best)} ms)');
    } else {
      _toast('Le plus rapide : ${best.name} (${rank(best)} ms)');
    }
  }

  void _openDiag() {
    final s = _selected;
    final hidden = s == null || s.locked || s.lockSsh;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DiagPage(
          host: hidden ? '' : s!.host,
          port: hidden ? 0 : s!.port,
          vpnOn: _state == 'on',
          checkUrl: _st.checkUrl,
        ),
      ),
    );
  }

  // ---------- serveurs ----------
  void _openForm(Server? s) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF10121A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => ServerForm(
        server: s,
        groups: _groupNames(),
        onSave: (n) {
          setState(() {
            final i = _servers.indexWhere((x) => x.id == n.id);
            if (i >= 0) {
              _servers[i] = n;
            } else {
              _servers.add(n);
              _selId ??= n.id;
            }
          });
          _save();
          _toast('Enregistré');
        },
      ),
    );
  }

  void _doImport(String text) {
    var ok = 0, bad = 0, warn = 0;
    final notes = <String>{};
    for (final t in text.split(RegExp(r'\s+'))) {
      if (!t.contains('://')) continue;
      final bundle = parseBundle(t);
      if (bundle != null) {
        for (final s in bundle) {
          _servers.add(s);
          _selId ??= s.id;
          ok++;
          if (s.msg.isNotEmpty) notes.add(s.msg);
        }
        continue;
      }
      if (t.toLowerCase().startsWith('ssh://')) {
        bad++;
        continue;
      }
      final s = parseLink(t);
      if (s != null) {
        _servers.add(s);
        _selId ??= s.id;
        ok++;
        if (s.extra.containsKey('unsupported')) warn++;
      } else {
        bad++;
      }
    }
    setState(() {});
    _save();
    if (ok == 0) {
      _toast('Aucun lien valide');
      return;
    }
    var msg = '$ok serveur(s) importé(s)';
    if (bad > 0) msg += ' · $bad ignoré(s)';
    if (warn > 0) msg += " · plugin obfs non pris en charge (testez le serveur)";
    _toast(msg);
    if (notes.isNotEmpty) _showInfo('Message', notes.join('\n\n'));
  }

  void _openImport() {
    final c = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10121A),
        title: const Text('Importer des liens'),
        content: TextField(
          controller: c,
          maxLines: 6,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            hintText: 'csophantom:// vless:// vmess:// trojan:// ss://  (un par ligne)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final d = await Clipboard.getData('text/plain');
              final t = d?.text;
              if (t != null) c.text = t;
            },
            child: const Text('Coller'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _doImport(c.text);
            },
            child: const Text('Importer'),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(String txt) async {
    await Clipboard.setData(ClipboardData(text: txt));
    _toast('Copié');
  }

  Future<void> _share(String text) async {
    try {
      await _shareCh.invokeMethod<bool>('share', {'text': text});
    } catch (_) {
      await _copy(text);
    }
  }

  Future<void> _saveBin(String txt) async {
    final stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      final ok = await _shareCh.invokeMethod<bool>('saveFile', {
        'name': 'cso-phantom-$stamp.cso',
        'text': base64.encode(encodeBin(txt)),
        'bin': true,
      });
      _toast(ok == true ? 'Fichier enregistré' : 'Enregistrement annulé');
    } catch (e) {
      _toast("Impossible d'enregistrer le fichier : $e");
    }
  }

  Future<void> _scanQr() async {
    final t = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScanPage()),
    );
    if (t == null || t.trim().isEmpty) return;
    _doImport(t);
  }

  Future<void> _importFile() async {
    try {
      final t = await _shareCh.invokeMethod<String>('openFile');
      if (t == null || t.trim().isEmpty) return;
      if (t.startsWith('b64:')) {
        final d = decodeBin(base64.decode(t.substring(4)));
        if (d == null) {
          _toast('Fichier .bin illisible ou abîmé');
          return;
        }
        _doImport(d);
        return;
      }
      _doImport(t);
    } catch (e) {
      _toast('Impossible de lire le fichier : $e');
    }
  }

  void _openShare(List<Server> list) {
    if (list.isEmpty) {
      _toast('Rien à partager');
      return;
    }
    if (list.any((s) => s.locked || s.lockSsh)) {
      _toast('Une configuration verrouillée ne peut pas être repartagée');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ExportPage(
        list: list,
        onCopy: (t) => _copy(t),
        onShare: (t) => _share(t),
        onSaveFile: (t) => _saveBin(t),
      ),
    ));
  }

  void _delete(Server s) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10121A),
        title: Text('Supprimer « ${s.name} » ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Non')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _servers.removeWhere((x) => x.id == s.id);
                if (_selId == s.id) _selId = _servers.isNotEmpty ? _servers.first.id : null;
              });
              _save();
            },
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
  }

  // ---------- interface ----------
  String _fmt(int s) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(s ~/ 3600)}:${p((s ~/ 60) % 60)}:${p(s % 60)}';
  }

  Widget _glowBg(Alignment c, double radius, Color col) => Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: c,
              radius: radius,
              colors: [col, col.withAlpha(0)],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(
        children: [
          HauntedBackground(
            awake: _state == 'on',
            animate: _st.bgAnim && !MediaQuery.of(context).disableAnimations,
          ),
          SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    _topBar(),
                    Expanded(
                      child: _tab == 0
                          // l'accueil tient sur l'écran sans défilement : l'orbe prend la place restante
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(18, 6, 18, 96),
                              child: _page(),
                            )
                          : SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(18, 10, 18, 110),
                              child: _page(),
                            ),
                    ),
                  ],
                ),
                Positioned(left: 0, right: 0, bottom: 14, child: Center(child: _nav())),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Container(
      height: 64,
      margin: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: glass(r: 32),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.white.withAlpha(40)),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x59A78BFA), Color(0x1F38BDF8)],
              ),
              boxShadow: const [BoxShadow(color: Color(0x668B5CF6), blurRadius: 16)],
            ),
            child: const SizedBox(width: 20, height: 24, child: CustomPaint(painter: GhostPainter())),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'CSO '),
                    TextSpan(
                      text: 'Phantom',
                      style: TextStyle(
                        foreground: Paint()
                          ..shader = const LinearGradient(
                            colors: [Color(0xFFC4B5FD), kCyan],
                          ).createShader(const Rect.fromLTWH(0, 0, 120, 24)),
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -.2),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Journal',
            onPressed: _openLog,
            icon: const Icon(Icons.receipt_long_outlined, color: kMute),
          ),
          IconButton(
            tooltip: 'Réglages',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined, color: kMute),
          ),
        ],
      ),
    );
  }

  Widget _nav() {
    const icons = [
      Icons.home_outlined,
      Icons.language,
      Icons.shield_outlined,
      Icons.bar_chart,
      Icons.person_outline,
    ];
    const labels = ['Accueil', 'Serveurs', 'Protection', 'Stats', 'Profil'];
    return Container(
      width: 370,
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(33),
        color: const Color(0xD910092A),
        border: Border.all(color: Colors.white.withAlpha(36)),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(140), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i < icons.length; i++)
            Semantics(
              button: true,
              label: labels[i],
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _tab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  height: 48,
                  padding: EdgeInsets.symmetric(horizontal: _tab == i ? 16 : 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: _tab == i
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
                          )
                        : null,
                    boxShadow: _tab == i
                        ? const [BoxShadow(color: Color(0xA66D28D9), blurRadius: 18, offset: Offset(0, 6))]
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icons[i], size: 24, color: _tab == i ? Colors.white : kMute),
                      if (_tab == i) ...[
                        const SizedBox(width: 6),
                        Text(labels[i],
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _page() {
    switch (_tab) {
      case 1:
        return _serversPage();
      case 2:
        return _shieldPage();
      case 3:
        return _statsPage();
      case 4:
        return _profilePage();
      default:
        return _homePage();
    }
  }

  Widget _orb(double size) {
    final on = _state == 'on';
    return Semantics(
      button: true,
      label: on ? 'Déconnecter' : 'Se connecter',
      child: GestureDetector(
        onTap: _toggle,
        child: SizedBox(
          width: size,
          height: size,
          child: AnimatedBuilder(
            animation: _spin,
            builder: (_, __) => CustomPaint(
              painter: WaterOrbPainter(_st.orbAnim ? _spin.value : 0.25, on, _st.palette, _st.orbStyle),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    final on = _state == 'on';
    final busy = _state == 'connecting';
    final c = on ? const Color(0xFF34D399) : (busy ? kAmber : kBad);
    final text = on ? 'Connexion protégée' : (busy ? 'Connexion en cours' : 'Non connecté');
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        color: c.withAlpha(26),
        border: Border.all(color: c.withAlpha(105)),
        boxShadow: [BoxShadow(color: c.withAlpha(40), blurRadius: 20)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              boxShadow: [BoxShadow(color: c, blurRadius: 8)],
            ),
          ),
          const SizedBox(width: 10),
          Text(text, style: TextStyle(fontSize: 13.5, color: Colors.white.withAlpha(235))),
        ],
      ),
    );
  }

  Widget _chip(IconData ic, String text, Color c) => Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(19),
          color: c.withAlpha(28),
          border: Border.all(color: c.withAlpha(105)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 16, color: c),
          const SizedBox(width: 7),
          Text(text, style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.w500)),
        ]),
      );

  Widget _statusLine() {
    final s = _selected;
    if (_state != 'on') {
      return Text(
        _state == 'connecting' ? 'Ouverture du tunnel...' : 'En ligne normalement',
        style: const TextStyle(color: kMute, fontSize: 13),
      );
    }
    final p = _ping;
    Widget net;
    var hint = '';
    if (p == null) {
      net = _chip(Icons.sync, "Test d'Internet...", kAmber);
    } else if (p > 0) {
      net = _chip(Icons.check_circle_outline, 'Internet OK', kGreen);
    } else {
      net = _chip(Icons.error_outline, 'Connecté sans Internet', kBad);
      hint = _diag.isNotEmpty
          ? _diag
          : s != null && s.type == 'ssh'
          ? 'Vérifie le payload / SNI / proxy du serveur SSH (touche ici pour retester)'
          : 'Vérifie SNI / Host / TLS dans le serveur (touche ici pour retester)';
    }
    return GestureDetector(
      onTap: _checkNet,
      child: Column(
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              net,
              if (p != null && p > 0) _chip(Icons.bolt, '$p ms', kCyan),
              if (s != null) _chip(Icons.public, kTypeNames[s.type] ?? s.type, kRed),
            ],
          ),
          if (hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(hint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: kMute, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _tag(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: kRed.withAlpha(46),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kRed.withAlpha(90)),
        ),
        child: Text(t.toUpperCase(), style: const TextStyle(color: kRed, fontSize: 11)),
      );

  Widget _rateCard(IconData ic, String label, double bps, Color c) {
    final sp = speedParts(bps);
    final v = sp.v;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: glass(r: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(ic, size: 16, color: c),
            const SizedBox(width: 7),
            Text(label, style: const TextStyle(fontSize: 12, color: kMute)),
          ]),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: v,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              TextSpan(text: ' ${sp.u}', style: const TextStyle(fontSize: 12, color: kMute)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _homePage() {
    final s = _selected;
    final label = _state == 'connecting'
        ? 'CONNEXION EN COURS'
        : (_state == 'on' ? 'TOUCHE POUR DÉCONNECTER' : 'TOUCHE POUR TE CONNECTER');
    return Column(
      children: [
        const SizedBox(height: 4),
        _statusPill(),
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, b) {
              final side = [b.maxHeight - 8, b.maxWidth, _st.orbSize].reduce((x, y) => x < y ? x : y);
              return Center(child: _orb(side < 60 ? 60.0 : side));
            },
          ),
        ),
        Text(label,
            style: const TextStyle(
                fontSize: 11, letterSpacing: 3, color: kMute, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0xFFC4B5FD)],
          ).createShader(r),
          child: Text(
            _fmt(_sec),
            style: const TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w500,
              letterSpacing: -1,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 6),
        _statusLine(),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _rateCard(Icons.arrow_downward, 'Téléchargement', _dlShown, kCyan)),
          const SizedBox(width: 10),
          Expanded(child: _rateCard(Icons.arrow_upward, 'Envoi', _ulShown, kRed)),
        ]),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => setState(() => _tab = 1),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: glass(r: 22),
            child: s == null
                ? const Text("Aucun serveur : appuie pour en ajouter",
                    textAlign: TextAlign.center, style: TextStyle(color: kMute))
                : Row(children: [
                    _tag(kTypeNames[s.type] ?? s.type),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    const Icon(Icons.chevron_right, color: kMute),
                  ]),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: glass(),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('TRAFIC RÉSEAU',
                      style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1, fontSize: 13)),
                  _tag('live'),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 64,
                width: double.infinity,
                child: CustomPaint(
                  painter: ChartPainter(List<double>.from(_dlData), List<double>.from(_ulData)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _speed(IconData ic, String label, double v) {
    return Row(children: [
      Icon(ic, color: kRed, size: 22),
      const SizedBox(width: 8),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 13, letterSpacing: .5)),
        Text(fmtRate(v), style: const TextStyle(color: kRed, fontSize: 13)),
      ]),
    ]);
  }

  List<Server> _view() {
    final q = _q.trim().toLowerCase();
    final l = _servers.where((x) {
      if (q.isEmpty) return true;
      return x.name.toLowerCase().contains(q) ||
          x.host.toLowerCase().contains(q) ||
          x.type.toLowerCase().contains(q) ||
          x.group.toLowerCase().contains(q);
    }).toList();
    if (_sortMode == 1) {
      l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (_sortMode == 2) {
      int rank(Server e) {
        final p = _pings[e.id] ?? -1;
        return p > 0 ? p : 1 << 30;
      }

      l.sort((a, b) => rank(a).compareTo(rank(b)));
    }
    return l;
  }

  void _duplicate(Server s) {
    final c = Server.fromJson(Map<String, dynamic>.from(s.toJson()));
    c.id = newId();
    c.name = '${s.name} (copie)';
    setState(() {
      final i = _servers.indexWhere((x) => x.id == s.id);
      _servers.insert(i < 0 ? _servers.length : i + 1, c);
    });
    _save();
    _toast('Serveur dupliqué');
  }

  List<String> _groupNames() {
    final g = <String>{for (final s in _servers) if (s.group.isNotEmpty) s.group}.toList();
    g.sort();
    return g;
  }

  List<Widget> _groupedCards() {
    final view = _view();
    final names = _groupNames();
    if (names.isEmpty) return [for (final s in view) _serverCard(s)];
    final out = <Widget>[];
    void section(String title, List<Server> list) {
      if (list.isEmpty) return;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Row(children: [
          const Icon(Icons.folder_outlined, size: 18, color: kRed),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('${list.length}', style: const TextStyle(color: kMute, fontSize: 12)),
        ]),
      ));
      for (final s in list) {
        out.add(_serverCard(s));
      }
    }

    for (final g in names) {
      section(g, view.where((s) => s.group == g).toList());
    }
    section('Sans dossier', view.where((s) => s.group.isEmpty).toList());
    return out;
  }

  Widget _serversPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Serveurs', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            FilledButton(onPressed: () => _openForm(null), child: const Text('+ Config manuelle')),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _openActions('Importer / Exporter', [
            _PAct(Icons.link, 'Importer un lien', _openImport),
            _PAct(Icons.qr_code_scanner, 'Scanner un QR code', _scanQr),
            _PAct(Icons.file_open_outlined, 'Importer un fichier', _importFile),
            _PAct(Icons.ios_share, 'Exporter (lien ou fichier)', () => _openShare(_servers)),
          ]),
          icon: const Icon(Icons.swap_vert),
          label: const Text('Importer / Exporter'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Chercher un serveur...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: Colors.white.withAlpha(14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<int>(
            tooltip: 'Trier',
            icon: Icon(Icons.sort, color: _sortMode == 0 ? kMute : kRed),
            onSelected: (v) => setState(() => _sortMode = v),
            itemBuilder: (_) => const [
              PopupMenuItem<int>(value: 0, child: Text('Ordre normal')),
              PopupMenuItem<int>(value: 1, child: Text('Par nom')),
              PopupMenuItem<int>(value: 2, child: Text('Par ping (plus rapide)')),
            ],
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _testingAll ? null : () => _testAll(),
              child: Text(_testingAll ? 'Test en cours...' : 'Tout tester'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _testingAll ? null : () => _testAll(pick: true),
              child: const Text('Meilleur serveur'),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        if (_servers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Text(
              'Aucun serveur.\nAppuie sur « + Config manuelle » ou importe un lien / un fichier.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMute, height: 1.5),
            ),
          ),
        ..._groupedCards(),
      ],
    );
  }

  Widget _act(IconData ic, String label, VoidCallback on) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: on,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(children: [
            Icon(ic, size: 20, color: kRed),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12, color: kRed)),
          ]),
        ),
      ),
    );
  }

  String? _expLabel(Server s) {
    if (s.expires <= 0) return null;
    if (s.expired) return 'Expiré';
    final d = ((s.expires - DateTime.now().millisecondsSinceEpoch) / 86400000).ceil();
    return 'Expire dans $d j';
  }

  Widget _serverCard(Server s) {
    final sel = s.id == _selId;
    final parts = <String>[];
    if (s.locked) {
      parts.add('Configuration verrouillée');
    } else {
      parts.add('${s.host}:${s.port}');
      if (s.type == 'ssh') {
        if (s.sec == 'tls') parts.add('SSL');
        if (s.payload.isNotEmpty) parts.add('payload');
        if (s.proxy.isNotEmpty) parts.add('proxy');
      } else if (s.net != 'tcp') {
        parts.add(s.net);
      }
      if (s.sni.isNotEmpty) parts.add('SNI ${s.sni}');
    }
    final extra = parts.join(' · ');
    final ping = _pings[s.id];
    final exp = _expLabel(s);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: glass(r: 20, sel: sel),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              if (_state != 'off') {
                _toast('Déconnecte-toi avant de changer de serveur');
                return;
              }
              setState(() => _selId = s.id);
              _save();
            },
            child: Row(children: [
              _tag(kTypeNames[s.type] ?? s.type),
              const SizedBox(width: 10),
              if (s.locked)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.lock_outline, size: 15, color: kMute),
                ),
              Expanded(
                child: Text(s.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (ping != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    ping > 0 ? '$ping ms' : 'échec',
                    style: TextStyle(color: ping > 0 ? kGreen : kAmber, fontSize: 12),
                  ),
                ),
              if (sel) const Icon(Icons.circle, color: kRed, size: 12),
            ]),
          ),
          const SizedBox(height: 6),
          Text(extra,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kMute, fontSize: 13)),
          if (exp != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(exp,
                  style: TextStyle(color: s.expired ? kBad : kAmber, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          Row(children: [
            _act(Icons.speed, 'Tester', () => _testServer(s)),
            if (!s.locked) _act(Icons.edit_outlined, 'Modifier', () => _openForm(s)),
            if (!s.locked && !s.lockSsh) _act(Icons.copy_all_outlined, 'Dupliquer', () => _duplicate(s)),
            if (!s.locked && !s.lockSsh) _act(Icons.ios_share, 'Partager', () => _openShare([s])),
            _act(Icons.delete_outline, 'Supprimer', () => _delete(s)),
          ]),
        ],
      ),
    );
  }

  Widget _quick(String title, String sub, bool v, void Function(bool) on) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        decoration: glass(r: 22),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: kMute)),
          value: v,
          activeColor: kRed,
          onChanged: (x) {
            on(x);
            _settingsChanged();
          },
        ),
      );

  Widget _shieldPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Protection', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        _quick('Mode rapide', 'DNS IPv4 et routage allégé', _st.fast, (x) => _st.fast = x),
        _quick('Reconnexion automatique', 'Relance le VPN si la connexion tombe', _st.autoReconnect,
            (x) => _st.autoReconnect = x),
        _quick('Bloquer QUIC', 'Force les navigateurs à utiliser TCP', _st.blockQuic, (x) => _st.blockQuic = x),
        _quick('Autoriser le réseau local', 'Imprimantes et partages restent accessibles', _st.lan,
            (x) => _st.lan = x),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: _openSettings,
          icon: const Icon(Icons.tune),
          label: const Text('Tous les réglages'),
        ),
        const SizedBox(height: 10),
        const Text(
          'Les changements s\'appliquent à la prochaine connexion.',
          textAlign: TextAlign.center,
          style: TextStyle(color: kMute, fontSize: 12),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k),
          Text(v, style: const TextStyle(color: kRed, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _statsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Statistiques', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: glass(),
          child: Column(children: [
            _kv('Serveurs enregistrés', '${_servers.length}'),
            _kv('Connexions', '$_conns'),
            _kv('Temps total connecté', _fmt(_totalSecs)),
            _kv('Total téléchargé', fmtBytes(_totDl)),
            _kv('Total envoyé', fmtBytes(_totUl)),
          ]),
        ),
        const SizedBox(height: 14),
        _usageChart(),
      ],
    );
  }

  /// Données échangées sur les 7 derniers jours.
  Widget _usageChart() {
    const wd = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
    final now = DateTime.now();
    final vals = <double>[];
    final labels = <String>[];
    for (var i = 6; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      vals.add(_daily[_dayKey(d)] ?? 0);
      labels.add(wd[d.weekday - 1]);
    }
    var mx = 0.0;
    var total = 0.0;
    for (final v in vals) {
      if (v > mx) mx = v;
      total += v;
    }
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: glass(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Utilisation (7 jours)', style: TextStyle(fontWeight: FontWeight.w700)),
              Text(fmtBytes(total), style: const TextStyle(color: kCyan, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 130,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(vals[i] > 0 ? fmtBytes(vals[i]) : '',
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: const TextStyle(fontSize: 9, color: kMute)),
                        const SizedBox(height: 4),
                        Container(
                          height: mx > 0 ? 6 + 70 * (vals[i] / mx) : 6,
                          margin: const EdgeInsets.symmetric(horizontal: 5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFFA78BFA), Color(0xFF4C1FB0)],
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(labels[i], style: TextStyle(fontSize: 11, color: i == 6 ? kRed : kMute)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pasteImport() async {
    final d = await Clipboard.getData('text/plain');
    final t = d?.text ?? '';
    if (t.trim().isEmpty) {
      _toast('Presse-papiers vide');
      return;
    }
    _doImport(t);
  }

  Widget _profGroup(IconData ic, String label, String sub, VoidCallback on) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: on,
        child: Container(
          height: 118,
          padding: const EdgeInsets.all(14),
          decoration: glass(r: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(ic, color: kRed, size: 28),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: kMute)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openActions(String title, List<_PAct> items) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF10121A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 8),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final a in items)
              ListTile(
                leading: Icon(a.icon, color: kRed),
                title: Text(a.label),
                onTap: () {
                  Navigator.pop(ctx);
                  a.on();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _confirmClear() {
    if (_state != 'off') {
      _toast("Déconnecte-toi d'abord");
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10121A),
        title: const Text('Tout effacer ?'),
        content: const Text('Tous tes serveurs seront supprimés. Exporte-les avant si tu veux les garder.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _servers.clear();
                _selId = null;
              });
              _save();
              _toast('Effacé');
            },
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
  }

  Widget _profAction(IconData ic, String label, VoidCallback on) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: on,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: glass(r: 18),
          child: Column(children: [
            Icon(ic, color: kRed, size: 24),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _profileStat(String label, String value, IconData ic) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: glass(r: 18),
        child: Column(children: [
          Icon(ic, color: kCyan, size: 20),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: kMute)),
        ]),
      ),
    );
  }

  Widget _profilePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: glass(r: 26),
          child: Row(children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF8B7BF0), Color(0xFF4C1FB0)],
                ),
              ),
              child: const SizedBox(width: 30, height: 36, child: CustomPaint(painter: GhostPainter())),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CSO PHANTOM', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1)),
                  const SizedBox(height: 4),
                  Text('Version $kAppVersion', style: const TextStyle(color: kRed, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text('Xray-core + SSH', style: TextStyle(color: kMute, fontSize: 12)),
                ],
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          _profileStat('Connexions', '$_conns', Icons.power_settings_new),
          const SizedBox(width: 10),
          _profileStat('Temps total', _fmt(_totalSecs), Icons.schedule),
          const SizedBox(width: 10),
          _profileStat('Serveurs', '${_servers.length}', Icons.dns_outlined),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _profileStat('Téléchargé', fmtBytes(_totDl), Icons.south),
          const SizedBox(width: 10),
          _profileStat('Envoyé', fmtBytes(_totUl), Icons.north),
        ]),
        const SizedBox(height: 12),
        const SizedBox(height: 12),
        Row(children: [
          _profGroup(Icons.dns_outlined, 'Serveurs et outils', 'Tester, diagnostic, vitesse, VPN Android', () {
            _openActions('Serveurs et outils', [
              _PAct(Icons.bolt, 'Meilleur serveur', () => _testAll(pick: true)),
              _PAct(Icons.speed, 'Tout tester', () => _testAll()),
              _PAct(Icons.health_and_safety_outlined, 'Diagnostic du réseau', _openDiag),
              _PAct(Icons.network_check, 'Test de vitesse', () {
                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SpeedPage()));
              }),
              _PAct(Icons.vpn_lock, 'Réglages VPN d\'Android (kill switch)', () {
                _shareCh.invokeMethod<bool>('openVpnSettings').catchError((Object _) => false);
              }),
              _PAct(Icons.delete_outline, 'Tout effacer', _confirmClear),
            ]);
          }),
        ]),
        const SizedBox(height: 22),
        Center(child: Image.asset('assets/creator.png', width: 260)),
        const Center(
          child: Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Créé par Charles Sedar Ouedraogo', style: TextStyle(color: kMute, fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

// ======================= FORMULAIRE SERVEUR =======================

class ServerForm extends StatefulWidget {
  final Server? server;
  final void Function(Server) onSave;
  final List<String> groups;
  const ServerForm({super.key, required this.server, required this.onSave, this.groups = const <String>[]});

  @override
  State<ServerForm> createState() => _ServerFormState();
}

class _ServerFormState extends State<ServerForm> {
  static const _show = {
    'vless': {'host', 'port', 'uuid', 'net', 'path', 'hosth', 'sec', 'sni', 'insec', 'mux'},
    'vmess': {'host', 'port', 'uuid', 'net', 'path', 'hosth', 'sec', 'sni', 'insec', 'mux'},
    'trojan': {'host', 'port', 'pass', 'net', 'path', 'hosth', 'sni', 'insec', 'mux'},
    'ss': {'host', 'port', 'method', 'pass', 'net', 'path', 'hosth', 'sec', 'sni', 'insec'},
    'ssh': {'host', 'port', 'user', 'pass', 'sshmode', 'sshtls', 'sni', 'insec', 'hosth', 'payload', 'proxy'},
  };
  static const _defPort = {'vless': 443, 'vmess': 443, 'trojan': 443, 'ss': 8388, 'ssh': 22};

  static const _modes = {
    'direct': 'SSH-Direct',
    'proxy': 'SSH-Proxy',
    'payload': 'SSH-Payload',
    'proxy_payload': 'SSH-Proxy-Payload',
    'tls': 'SSH-TLS',
    'tls_proxy': 'SSH-TLS-Proxy',
    'tls_payload': 'SSH-TLS-Payload',
    'tls_proxy_payload': 'SSH-TLS-Proxy-Payload',
    'dnstt': 'SSH-DNSTT (non pris en charge)',
  };
  static const _plHttp = 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]';
  static const _plConnect = '[netData][crlf]Host: [host_port][crlf][crlf]';

  late String type;
  late String method;
  late String net;
  late String sec;
  late bool insecure;
  late bool mux;
  late bool sshTls;
  late String mode;
  final name = TextEditingController();
  final host = TextEditingController();
  final port = TextEditingController();
  final uuid = TextEditingController();
  final user = TextEditingController();
  final pass = TextEditingController();
  final path = TextEditingController();
  final hosth = TextEditingController();
  final sni = TextEditingController();
  final payload = TextEditingController();
  final group = TextEditingController();
  final proxy = TextEditingController();
  String err = '';

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    type = s?.type ?? 'vless';
    method = s?.method ?? 'aes-256-gcm';
    net = s?.net ?? 'tcp';
    sec = s?.sec ?? 'tls';
    insecure = s?.insecure ?? true;
    mux = s?.mux ?? false;
    sshTls = (s?.type == 'ssh') && s?.sec == 'tls';
    name.text = s?.name ?? '';
    host.text = s?.host ?? '';
    port.text = (s?.port ?? 443).toString();
    uuid.text = s?.uuid ?? '';
    user.text = s?.user ?? '';
    pass.text = s?.pass ?? '';
    path.text = s?.path ?? '';
    hosth.text = s?.hosth ?? '';
    sni.text = s?.sni ?? '';
    payload.text = s?.payload ?? '';
    group.text = s?.group ?? '';
    proxy.text = s?.proxy ?? '';
    mode = _detectMode();
  }

  String _detectMode() {
    final parts = <String>[
      if (sshTls) 'tls',
      if (proxy.text.trim().isNotEmpty) 'proxy',
      if (payload.text.trim().isNotEmpty) 'payload',
    ];
    return parts.isEmpty ? 'direct' : parts.join('_');
  }

  void _applyMode(String m) {
    final hasProxy = m.contains('proxy');
    final hasPayload = m.contains('payload');
    mode = m;
    sshTls = m.startsWith('tls');
    if (!hasProxy) proxy.text = '';
    if (!hasPayload) {
      payload.text = '';
    } else if (payload.text.trim().isEmpty) {
      payload.text = hasProxy ? _plConnect : _plHttp;
    }
  }

  @override
  void dispose() {
    for (final c in [name, host, port, uuid, user, pass, path, hosth, sni, payload, proxy, group]) {
      c.dispose();
    }
    super.dispose();
  }

  bool v(String f) => _show[type]!.contains(f);

  /// Champ réellement affiché (tient compte du mode SSH et de la sécurité).
  bool vis(String f) {
    if (!v(f)) return false;
    if (type == 'ssh') {
      if (f == 'sni' || f == 'insec') return sshTls;
      if (f == 'proxy') return mode.contains('proxy');
      if (f == 'payload') return mode.contains('payload');
      if (f == 'hosth') return sshTls || mode.contains('payload');
      if (f == 'sshtls') return false;
    }
    if (f == 'insec') return type == 'trojan' || sec != 'none';
    return true;
  }

  InputDecoration _dec(String label, [String hint = '']) => InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: Colors.white.withAlpha(18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withAlpha(56)),
        ),
      );

  Future<void> _editPayload() async {
    final h = host.text.trim();
    final hh = hosth.text.trim().isEmpty ? h : hosth.text.trim().split(',').first.trim();
    final r = await showPayloadEditor(
      context,
      initial: payload.text,
      host: h,
      hostHeader: hh,
      port: int.tryParse(port.text.trim()) ?? 22,
    );
    if (r != null && mounted) setState(() => payload.text = r);
  }

  Widget _field(String label, TextEditingController c,
      {String hint = '', bool num = false, int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        autocorrect: false,
        enableSuggestions: false,
        minLines: lines,
        maxLines: lines,
        keyboardType: num ? TextInputType.number : TextInputType.text,
        decoration: _dec(label, hint),
      ),
    );
  }

  Widget _drop(String label, String value, Map<String, String> items, void Function(String) on) {
    final its = Map<String, String>.from(items);
    if (!its.containsKey(value)) its[value] = value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        decoration: _dec(label),
        dropdownColor: const Color(0xFF10121A),
        items: [
          for (final e in its.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (x) {
          if (x != null) on(x);
        },
      ),
    );
  }

  Widget _switch(String title, String sub, bool value, void Function(bool) on) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12, color: kMute)),
      value: value,
      activeColor: kRed,
      onChanged: on,
    );
  }

  void _save() {
    final p = int.tryParse(port.text.trim());
    if (host.text.trim().isEmpty) {
      setState(() => err = 'Serveur / IP obligatoire');
      return;
    }
    if (p == null || p <= 0 || p > 65535) {
      setState(() => err = 'Port invalide');
      return;
    }
    if (v('uuid') && uuid.text.trim().isEmpty) {
      setState(() => err = 'UUID obligatoire');
      return;
    }
    if (type == 'trojan' && pass.text.trim().isEmpty) {
      setState(() => err = 'Mot de passe obligatoire');
      return;
    }
    final keepSsh = widget.server?.lockSsh == true && type == 'ssh';
    if (type == 'ssh' && !keepSsh && user.text.trim().isEmpty) {
      setState(() => err = 'Utilisateur obligatoire');
      return;
    }
    if (type == 'ssh' && mode.contains('proxy') && !proxy.text.contains(':')) {
      setState(() => err = 'Proxy : indique hôte:port (ex. 10.0.0.1:8080)');
      return;
    }
    final h = host.text.trim();
    final old = widget.server;
    final isSsh = type == 'ssh';
    widget.onSave(Server(
      id: old?.id ?? newId(),
      name: name.text.trim().isEmpty ? h : name.text.trim(),
      type: type,
      host: h,
      port: p,
      uuid: v('uuid') ? uuid.text.trim() : '',
      user: keepSsh ? old!.user : (v('user') ? user.text.trim() : ''),
      pass: keepSsh ? old!.pass : (v('pass') ? pass.text.trim() : ''),
      method: v('method') ? method : 'aes-256-gcm',
      net: v('net') ? net : 'tcp',
      path: v('path') ? path.text.trim() : '',
      hosth: vis('hosth') ? hosth.text.trim() : '',
      sec: isSsh ? (sshTls ? 'tls' : 'none') : (v('sec') ? sec : (type == 'trojan' ? 'tls' : 'none')),
      sni: vis('sni') ? sni.text.trim() : '',
      insecure: insecure,
      mux: v('mux') ? mux : false,
      payload: isSsh && vis('payload') ? payload.text.trim() : '',
      proxy: isSsh && vis('proxy') ? proxy.text.trim() : '',
      locked: false,
      msg: old?.msg ?? '',
      connMsg: old?.connMsg ?? '',
      hwids: old?.hwids ?? '',
      lockSsh: old?.lockSsh ?? false,
      group: group.text.trim(),
      expires: old?.expires ?? 0,
      extra: (old != null && old.type == type)
          ? Map<String, String>.from(old.extra)
          : <String, String>{},
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.server == null ? 'Nouveau serveur' : 'Modifier le serveur',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            _field('Nom', name, hint: 'Mon serveur'),
            _field('Dossier (optionnel)', group, hint: 'ex. Orange, Moov, Perso'),
            if (widget.groups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final g in widget.groups)
                      ActionChip(
                        label: Text(g, style: const TextStyle(fontSize: 12)),
                        onPressed: () => setState(() => group.text = g),
                      ),
                  ],
                ),
              ),
            _drop('Protocole', type, const {
              'vless': 'VLESS',
              'vmess': 'VMess',
              'trojan': 'Trojan',
              'ss': 'Shadowsocks',
              'ssh': 'SSH',
            }, (x) {
              setState(() {
                final old = int.tryParse(port.text.trim());
                if (old == null || old == _defPort[type]) port.text = '${_defPort[x]}';
                if (x == 'ss') {
                  sec = 'none';
                  net = 'tcp';
                } else if (type == 'ss' && x != 'ssh') {
                  sec = 'tls';
                }
                type = x;
                if (x == 'ssh') mode = _detectMode();
              });
            }),
            Row(children: [
              Expanded(flex: 3, child: _field('Serveur / IP', host, hint: 'exemple.com')),
              const SizedBox(width: 10),
              Expanded(flex: 1, child: _field('Port', port, num: true)),
            ]),
            if (v('uuid')) _field('UUID', uuid),
            if (v('user') && widget.server?.lockSsh != true) _field('Utilisateur', user),
            if (v('pass') && widget.server?.lockSsh != true) _field('Mot de passe', pass),
            if (widget.server?.lockSsh == true && type == 'ssh')
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text('Compte SSH verrouillé : identifiants masqués.', style: TextStyle(color: kMute)),
              ),
            if (v('method'))
              _drop('Chiffrement', method, const {
                'aes-256-gcm': 'aes-256-gcm',
                'aes-128-gcm': 'aes-128-gcm',
                'chacha20-ietf-poly1305': 'chacha20-ietf-poly1305',
                '2022-blake3-aes-256-gcm': '2022-blake3-aes-256-gcm',
              }, (x) => setState(() => method = x)),
            if (v('sshmode'))
              _drop('Mode SSH', mode, _modes, (x) => setState(() {
                    if (x == 'dnstt') {
                      err = "SSH-DNSTT (tunnel par DNS) n'est pas encore pris en charge : il demande un client DNSTT dédié.";
                    } else {
                      err = '';
                      _applyMode(x);
                    }
                  })),
            if (v('net'))
              _drop('Transport', net, const {
                'tcp': 'TCP',
                'ws': 'WebSocket',
                'grpc': 'gRPC',
                'httpupgrade': 'HTTPUpgrade',
                'xhttp': 'XHTTP',
                'h2': 'HTTP/2',
                'kcp': 'mKCP',
              }, (x) => setState(() => net = x)),
            if (v('path')) _field('Chemin (path) / service gRPC', path, hint: '/'),
            if (vis('hosth'))
              _field(type == 'ssh' ? 'Host ([host] du payload)' : 'Host (en-tête)', hosth,
                  hint: 'cdn.exemple.com'),
            if (v('sec'))
              _drop('Sécurité', sec, const {'tls': 'TLS', 'none': 'Aucune', 'reality': 'Reality'},
                  (x) => setState(() => sec = x)),
            if (vis('sshtls'))
              _switch('SSL/TLS', 'Enveloppe la connexion SSH dans TLS (avec SNI)', sshTls,
                  (x) => setState(() {
                        sshTls = x;
                        mode = _detectMode();
                      })),
            if (vis('sni')) _field('SNI', sni, hint: 'sni.exemple.com'),
            if (vis('payload'))
              _field('Payload', payload,
                  hint: 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]', lines: 3),
            if (vis('payload'))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: OutlinedButton.icon(
                  onPressed: _editPayload,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Éditeur de payload (modèles et aperçu)'),
                ),
              ),
            if (vis('payload'))
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Balises : [crlf] [cr] [lf] [host] [port] [host_port] [protocol] [ua] [netData] '
                  '[split] [instant_split] [delay_split]',
                  style: TextStyle(fontSize: 12, color: kMute),
                ),
              ),
            if (vis('proxy'))
              _field('Proxy (hôte:port)', proxy, hint: 'ex. 10.0.0.1:8080'),
            if (v('mux'))
              _switch('Mux', "Accélère l'ouverture des pages sur certains serveurs. Désactive-le si la connexion échoue.",
                  mux, (x) => setState(() => mux = x)),
            if (vis('insec'))
              _switch(
                  'Autoriser non sécurisé',
                  'Ignore la vérification du certificat TLS (allowInsecure). '
                      'Souvent nécessaire avec un SNI ou un Host personnalisé.',
                  insecure,
                  (x) => setState(() => insecure = x)),
            if (err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(err, style: const TextStyle(color: kBad)),
              ),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
              ),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(onPressed: _save, child: const Text('Enregistrer'))),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Une action proposée dans une fenêtre de regroupement du Profil.
class _PAct {
  final IconData icon;
  final String label;
  final VoidCallback on;
  _PAct(this.icon, this.label, this.on);
}
