import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server.dart';

const kBg = Color(0xFF07080C);
const kRed = Color(0xFFFF4A4A);
const kMute = Color(0xFF9AA0AD);
const kGreen = Color(0xFF6FCF7F);

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
      ),
      home: const HomePage(),
    );
  }
}

BoxDecoration glass({double r = 26, bool sel = false}) {
  return BoxDecoration(
    borderRadius: BorderRadius.circular(r),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Colors.white.withAlpha(26), Colors.white.withAlpha(8)],
    ),
    border: Border.all(
      color: sel ? kRed.withAlpha(190) : Colors.white.withAlpha(56),
    ),
    boxShadow: [
      BoxShadow(
        color: sel ? kRed.withAlpha(70) : Colors.black.withAlpha(110),
        blurRadius: sel ? 22 : 30,
        offset: const Offset(0, 10),
      ),
    ],
  );
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

class ChartPainter extends CustomPainter {
  final List<double> data;
  const ChartPainter(this.data);

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
    if (data.length < 2) return;
    var mx = 1.0;
    for (final v in data) {
      if (v > mx) mx = v;
    }
    final pts = <Offset>[
      for (var i = 0; i < data.length; i++)
        Offset(
          size.width * i / (data.length - 1),
          size.height * 0.95 - (data[i] / mx) * size.height * 0.85,
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
        ..color = kRed
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant ChartPainter old) => true;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  SharedPreferences? _prefs;
  List<Server> _servers = [];
  String? _selId;
  int _tab = 0;

  // connexion : off | connecting | on
  String _state = 'off';
  int _sec = 0;
  int _totalSecs = 0;
  int _conns = 0;
  double _dl = 0;
  double _ul = 0;
  final List<double> _data = List<double>.filled(12, 0.0, growable: true);
  Timer? _ticker;
  Timer? _timeout;
  bool _inited = false;
  Map<String, bool> _opts = {'kill': false, 'auto': true, 'dns': true, 'lan': false};

  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  late final FlutterVless _vless = FlutterVless(onStatusChanged: _onStatus);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _timeout?.cancel();
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
    _conns = p.getInt('conns') ?? 0;
    _totalSecs = p.getInt('secs') ?? 0;
    final o = p.getString('opts');
    if (o != null) {
      try {
        final m = jsonDecode(o) as Map;
        _opts = m.map((k, v) => MapEntry(k.toString(), v == true));
      } catch (_) {}
    }
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
    p.setString('opts', jsonEncode(_opts));
  }

  Server? get _selected {
    for (final s in _servers) {
      if (s.id == _selId) return s;
    }
    return null;
  }

  void _toast(String m) {
    if (!mounted) return;
    final sm = ScaffoldMessenger.of(context);
    sm.hideCurrentSnackBar();
    sm.showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  // ---------- VPN ----------
  void _onStatus(dynamic st) {
    var s = '';
    try {
      s += st.state.toString().toUpperCase();
    } catch (_) {}
    try {
      s += ' ${st.connectionState.name.toString().toUpperCase()}';
    } catch (_) {}
    try {
      final d = st.downloadSpeed;
      if (d is num) _dl = d / 1048576.0;
    } catch (_) {}
    try {
      final u = st.uploadSpeed;
      if (u is num) _ul = u / 1048576.0;
    } catch (_) {}
    if (!mounted) return;
    if (s.contains('DISCONNECT')) {
      if (_state == 'on') _setOff();
    } else if (s.contains('CONNECTED')) {
      if (_state != 'on') _setOn();
    }
    setState(() {});
  }

  void _setOn() {
    _timeout?.cancel();
    _state = 'on';
    _sec = 0;
    _conns++;
    _save();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _sec++;
        _totalSecs++;
        _data.add(_dl);
        _data.removeAt(0);
      });
      if (_sec % 10 == 0) _save();
    });
  }

  void _setOff() {
    _timeout?.cancel();
    _ticker?.cancel();
    _state = 'off';
    _sec = 0;
    _dl = 0;
    _ul = 0;
    for (var i = 0; i < _data.length; i++) {
      _data[i] = 0;
    }
    _save();
  }

  Future<void> _toggle() async {
    if (_state == 'connecting') return;
    if (_state == 'on') {
      try {
        await _vless.stopVless();
      } catch (_) {}
      setState(_setOff);
      _toast('Déconnecté');
      return;
    }
    final s = _selected;
    if (s == null) {
      _toast("Ajoute d'abord un serveur");
      setState(() => _tab = 1);
      return;
    }
    if (s.type == 'ssh') {
      _toast('SSH : pas encore pris en charge (étape suivante)');
      return;
    }
    setState(() => _state = 'connecting');
    try {
      final parsed = FlutterVless.parse(toLink(s));
      final config = parsed.getFullConfiguration();
      if (!_inited) {
        await _vless.initializeVless(
          providerBundleIdentifier: 'com.csophantom.cso_phantom',
          groupIdentifier: 'group.com.csophantom.cso_phantom',
        );
        _inited = true;
      }
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
          _toast('Délai dépassé : vérifie ton compte');
        }
      });
      await _vless.startVless(remark: parsed.remark, config: config);
    } catch (e) {
      _timeout?.cancel();
      if (mounted) setState(() => _state = 'off');
      _toast('Échec : $e');
    }
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
            hintText: 'vless:// vmess:// trojan:// ss://  (un par ligne)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              var ok = 0, bad = 0;
              for (final t in c.text.split(RegExp(r'\s+'))) {
                if (t.isEmpty) continue;
                final s = parseLink(t);
                if (s != null) {
                  _servers.add(s);
                  _selId ??= s.id;
                  ok++;
                } else {
                  bad++;
                }
              }
              Navigator.pop(ctx);
              setState(() {});
              _save();
              _toast(ok > 0
                  ? '$ok serveur(s) importé(s)${bad > 0 ? ' · $bad ignoré(s)' : ''}'
                  : 'Aucun lien valide');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.35),
            radius: 1.1,
            colors: [Color(0xFF2A0A10), kBg],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _topBar(),
                  Expanded(
                    child: SingleChildScrollView(
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
      ),
    );
  }

  Widget _topBar() {
    return Container(
      height: 64,
      margin: const EdgeInsets.fromLTRB(18, 14, 18, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: glass(r: 40),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CustomPaint(painter: const EmblemPainter(kRed)),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'CSO PHANTOM',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: .5),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _tab = 2),
            icon: const Icon(Icons.verified_user_outlined, color: kMute),
          ),
          IconButton(
            onPressed: () => setState(() => _tab = 4),
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
    return Container(
      width: 370,
      height: 66,
      decoration: glass(r: 40).copyWith(color: const Color(0xCC07080C)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (var i = 0; i < icons.length; i++)
            IconButton(
              onPressed: () => setState(() => _tab = i),
              icon: Icon(icons[i], size: 28, color: _tab == i ? kRed : kMute),
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

  Widget _orb() {
    final on = _state == 'on';
    final busy = _state == 'connecting';
    final label = busy ? '...' : (on ? 'DISCONNECT' : 'CONNECT');
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        width: 230,
        height: 230,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            center: Alignment(-0.3, -0.45),
            radius: 1.0,
            colors: [Color(0xFFFF6A6A), Color(0xFFB81F2B), Color(0xFF5A0B14)],
            stops: [0.0, 0.55, 1.0],
          ),
          boxShadow: [
            BoxShadow(color: kRed.withAlpha(on ? 200 : 140), blurRadius: 64, spreadRadius: 4),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _spin,
              builder: (_, child) => Transform.rotate(
                angle: (on || busy) ? _spin.value * 2 * math.pi : 0,
                child: child,
              ),
              child: SizedBox(
                width: 100,
                height: 100,
                child: CustomPaint(painter: const EmblemPainter(Colors.white)),
              ),
            ),
            const SizedBox(height: 12),
            Text(label,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ],
        ),
      ),
    );
  }

  Widget _statusLine() {
    final s = _selected;
    TextSpan sp(String t, Color c) => TextSpan(text: t, style: TextStyle(color: c));
    List<TextSpan> parts;
    if (_state == 'on') {
      parts = [sp('Connecté', kGreen), sp('  •  ', kMute), sp(s?.name ?? '', kGreen)];
    } else if (_state == 'connecting') {
      parts = [sp('Connexion en cours', const Color(0xFFE8C26A))];
    } else {
      parts = [
        sp('Déconnecté', const Color(0xFFD76A64)),
        sp('  •  ', kMute),
        sp('En ligne normalement', kGreen),
      ];
    }
    return Text.rich(TextSpan(children: parts), style: const TextStyle(fontSize: 15));
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

  Widget _homePage() {
    final s = _selected;
    return Column(
      children: [
        const SizedBox(height: 10),
        _orb(),
        const SizedBox(height: 18),
        Text(_fmt(_sec),
            style: const TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w300,
                letterSpacing: 2,
                color: Color(0xFFD9DBE2))),
        const SizedBox(height: 6),
        _statusLine(),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: () => setState(() => _tab = 1),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: glass(r: 22),
            child: s == null
                ? const Text("Aucun serveur : appuie pour en ajouter",
                    style: TextStyle(color: kMute))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    _tag(kTypeNames[s.type] ?? s.type),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(s.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ]),
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: glass(),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('TRAFFIC RESEAU',
                      style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: .5)),
                  _tag('live'),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 140,
                width: double.infinity,
                child: CustomPaint(painter: ChartPainter(List<double>.from(_data))),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _speed(Icons.arrow_downward, 'DOWNLOAD', _dl),
                  _speed(Icons.arrow_upward, 'UPLOAD', _ul),
                ],
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
        Text('${v.toStringAsFixed(1)} MB/s', style: const TextStyle(color: kRed, fontSize: 13)),
      ]),
    ]);
  }

  Widget _serversPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Serveurs', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            FilledButton(onPressed: () => _openForm(null), child: const Text('+ Ajouter')),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _openImport, child: const Text('Importer un lien')),
        const SizedBox(height: 14),
        if (_servers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Text(
              'Aucun serveur.\nAppuie sur « + Ajouter » ou « Importer un lien ».',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMute, height: 1.5),
            ),
          ),
        for (final s in _servers) _serverCard(s),
      ],
    );
  }

  Widget _serverCard(Server s) {
    final sel = s.id == _selId;
    final extra = [
      '${s.host}:${s.port}',
      if (s.net != 'tcp' && s.type != 'ss' && s.type != 'ssh') s.net,
      if (s.sni.isNotEmpty) 'SNI ${s.sni}',
    ].join(' · ');
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
              Expanded(
                child: Text(s.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (sel) const Icon(Icons.circle, color: kRed, size: 12),
            ]),
          ),
          const SizedBox(height: 6),
          Text(extra, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMute, fontSize: 13)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => _openForm(s), child: const Text('Modifier'))),
            Expanded(child: TextButton(onPressed: () => _copy(toLink(s)), child: const Text('Copier'))),
            Expanded(child: TextButton(onPressed: () => _delete(s), child: const Text('Supprimer'))),
          ]),
        ],
      ),
    );
  }

  Widget _shieldPage() {
    const items = [
      ['kill', 'Kill switch (bloquer sans VPN)'],
      ['auto', 'Reconnexion automatique'],
      ['dns', 'Protection des fuites DNS'],
      ['lan', 'Autoriser le réseau local'],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Protection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: glass(),
          child: Column(children: [
            for (final it in items)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(it[1]),
                value: _opts[it[0]] ?? false,
                activeColor: kRed,
                onChanged: (v) {
                  setState(() => _opts[it[0]] = v);
                  _save();
                },
              ),
          ]),
        ),
        const SizedBox(height: 10),
        const Text(
          "Ces options seront appliquées au tunnel dans une prochaine version.",
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
          ]),
        ),
      ],
    );
  }

  Widget _profilePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Profil', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          decoration: glass(),
          child: Column(children: [
            _kv('Application', 'CSO PHANTOM V2'),
            _kv('Moteur', 'Xray-core'),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                if (_servers.isEmpty) {
                  _toast('Rien à exporter');
                  return;
                }
                _copy(_servers.map(toLink).join('\n'));
              },
              child: const Text('Exporter tout'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                if (_state != 'off') {
                  _toast("Déconnecte-toi d'abord");
                  return;
                }
                setState(() {
                  _servers.clear();
                  _selId = null;
                });
                _save();
                _toast('Effacé');
              },
              child: const Text('Tout effacer'),
            ),
          ),
        ]),
      ],
    );
  }
}

// ======================= FORMULAIRE SERVEUR =======================

class ServerForm extends StatefulWidget {
  final Server? server;
  final void Function(Server) onSave;
  const ServerForm({super.key, required this.server, required this.onSave});

  @override
  State<ServerForm> createState() => _ServerFormState();
}

class _ServerFormState extends State<ServerForm> {
  static const _show = {
    'vless': {'host', 'port', 'uuid', 'net', 'path', 'hosth', 'sec', 'sni'},
    'vmess': {'host', 'port', 'uuid', 'net', 'path', 'hosth', 'sec', 'sni'},
    'trojan': {'host', 'port', 'pass', 'net', 'path', 'hosth', 'sni'},
    'ss': {'host', 'port', 'method', 'pass'},
    'ssh': {'host', 'port', 'user', 'pass', 'sni'},
  };
  static const _defPort = {'vless': 443, 'vmess': 443, 'trojan': 443, 'ss': 8388, 'ssh': 22};

  late String type;
  late String method;
  late String net;
  late String sec;
  final name = TextEditingController();
  final host = TextEditingController();
  final port = TextEditingController();
  final uuid = TextEditingController();
  final user = TextEditingController();
  final pass = TextEditingController();
  final path = TextEditingController();
  final hosth = TextEditingController();
  final sni = TextEditingController();
  String err = '';

  @override
  void initState() {
    super.initState();
    final s = widget.server;
    type = s?.type ?? 'vless';
    method = s?.method ?? 'aes-256-gcm';
    net = s?.net ?? 'tcp';
    sec = s?.sec ?? 'tls';
    name.text = s?.name ?? '';
    host.text = s?.host ?? '';
    port.text = (s?.port ?? 443).toString();
    uuid.text = s?.uuid ?? '';
    user.text = s?.user ?? '';
    pass.text = s?.pass ?? '';
    path.text = s?.path ?? '';
    hosth.text = s?.hosth ?? '';
    sni.text = s?.sni ?? '';
  }

  @override
  void dispose() {
    for (final c in [name, host, port, uuid, user, pass, path, hosth, sni]) {
      c.dispose();
    }
    super.dispose();
  }

  bool v(String f) => _show[type]!.contains(f);

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

  Widget _field(String label, TextEditingController c, {String hint = '', bool num = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: num ? TextInputType.number : TextInputType.text,
        decoration: _dec(label, hint),
      ),
    );
  }

  Widget _drop(String label, String value, Map<String, String> items, void Function(String) on) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: _dec(label),
        dropdownColor: const Color(0xFF10121A),
        items: [
          for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (x) {
          if (x != null) on(x);
        },
      ),
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
    if (type == 'ssh' && user.text.trim().isEmpty) {
      setState(() => err = 'Utilisateur obligatoire');
      return;
    }
    final h = host.text.trim();
    widget.onSave(Server(
      id: widget.server?.id ?? newId(),
      name: name.text.trim().isEmpty ? h : name.text.trim(),
      type: type,
      host: h,
      port: p,
      uuid: v('uuid') ? uuid.text.trim() : '',
      user: v('user') ? user.text.trim() : '',
      pass: v('pass') ? pass.text.trim() : '',
      method: v('method') ? method : 'aes-256-gcm',
      net: v('net') ? net : 'tcp',
      path: v('path') ? path.text.trim() : '',
      hosth: v('hosth') ? hosth.text.trim() : '',
      sec: v('sec') ? sec : (type == 'trojan' ? 'tls' : 'none'),
      sni: v('sni') ? sni.text.trim() : '',
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
                type = x;
              });
            }),
            Row(children: [
              Expanded(flex: 3, child: _field('Serveur / IP', host, hint: 'exemple.com')),
              const SizedBox(width: 10),
              Expanded(flex: 1, child: _field('Port', port, num: true)),
            ]),
            if (v('uuid')) _field('UUID', uuid),
            if (v('user')) _field('Utilisateur', user),
            if (v('pass')) _field('Mot de passe', pass),
            if (v('method'))
              _drop('Chiffrement', method, const {
                'aes-256-gcm': 'aes-256-gcm',
                'aes-128-gcm': 'aes-128-gcm',
                'chacha20-ietf-poly1305': 'chacha20-ietf-poly1305',
                '2022-blake3-aes-256-gcm': '2022-blake3-aes-256-gcm',
              }, (x) => setState(() => method = x)),
            if (v('net'))
              _drop('Transport', net, const {'tcp': 'TCP', 'ws': 'WebSocket', 'grpc': 'gRPC'},
                  (x) => setState(() => net = x)),
            if (v('path')) _field('Chemin (path) / service gRPC', path, hint: '/'),
            if (v('hosth')) _field('Host (en-tête)', hosth, hint: 'cdn.exemple.com'),
            if (v('sec'))
              _drop('Sécurité', sec, const {'tls': 'TLS', 'none': 'Aucune'},
                  (x) => setState(() => sec = x)),
            if (v('sni')) _field('SNI', sni, hint: 'sni.exemple.com'),
            if (err.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(err, style: const TextStyle(color: kRed)),
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
