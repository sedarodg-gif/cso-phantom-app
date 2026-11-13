import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

extension _Op on Color {
  Color op(double o) => withAlpha((o.clamp(0.0, 1.0) * 255).round());
}

/// Fond animé : un manoir hanté (lune, nuages, fantômes, chauves-souris, brouillard, éclairs).
/// [awake] = VPN connecté : le manoir s'éveille. [animate] = false : image fixe (économise la batterie).
class HauntedBackground extends StatefulWidget {
  final bool awake;
  final bool animate;
  const HauntedBackground({super.key, required this.awake, required this.animate});

  @override
  State<HauntedBackground> createState() => _HauntedBackgroundState();
}

class _Star {
  final double x, y, r, p, s;
  _Star(this.x, this.y, this.r, this.p, this.s);
}

class _Cloud {
  double x;
  final double y, s, v;
  _Cloud(this.x, this.y, this.s, this.v);
}

class _Ghost {
  double x;
  final double y, s, ph, sp, dir, min;
  _Ghost(this.x, this.y, this.s, this.ph, this.sp, this.dir, this.min);
}

class _Bat {
  double x;
  final double y, v, ph, s;
  _Bat(this.x, this.y, this.v, this.ph, this.s);
}

/// État partagé entre le widget et le peintre.
class _Scene {
  double t = 0;
  double awake = 0;
  double flash = 0;
  bool animating = true;
  final List<_Star> stars = <_Star>[];
  final List<_Cloud> clouds = <_Cloud>[];
  final List<_Ghost> ghosts = <_Ghost>[];
  final List<_Bat> bats = <_Bat>[];

  _Scene() {
    final r = math.Random(11);
    double rr(double a, double b) => a + r.nextDouble() * (b - a);
    for (var i = 0; i < 70; i++) {
      stars.add(_Star(r.nextDouble(), r.nextDouble() * 0.55, rr(0.4, 1.4), rr(0, 6.28), rr(0.5, 2)));
    }
    for (var i = 0; i < 5; i++) {
      clouds.add(_Cloud(r.nextDouble(), rr(0.08, 0.42), rr(0.25, 0.5), rr(0.004, 0.012)));
    }
    for (var i = 0; i < 9; i++) {
      ghosts.add(_Ghost(rr(0.05, 0.95), rr(0.25, 0.85), rr(0.5, 1.15), rr(0, 6.28), rr(0.25, 0.6),
          r.nextBool() ? -1.0 : 1.0, i < 4 ? 0.0 : i / 9));
    }
    for (var i = 0; i < 6; i++) {
      bats.add(_Bat(rr(-0.2, 1.2), rr(0.1, 0.5), rr(0.04, 0.09) * (r.nextBool() ? -1 : 1), rr(0, 6.28), rr(0.7, 1.3)));
    }
  }
}

class _HauntedBackgroundState extends State<HauntedBackground> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _Scene _scene = _Scene();
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  late final _HauntedPainter _painter = _HauntedPainter(_scene, _tick);
  Duration _last = Duration.zero;
  Duration _lastPaint = Duration.zero;

  @override
  void initState() {
    super.initState();
    _scene.awake = widget.awake ? 1 : 0;
    _scene.animating = widget.animate;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(HauntedBackground old) {
    super.didUpdateWidget(old);
    _scene.animating = widget.animate;
    if (widget.awake && !old.awake) _scene.flash = 1; // éclair à la connexion
    _tick.value++;
  }

  void _onTick(Duration d) {
    var dt = (d - _last).inMicroseconds / 1e6;
    _last = d;
    if (dt <= 0 || dt > 0.1) dt = 0.016;
    final target = widget.awake ? 1.0 : 0.0;
    final moving = (_scene.awake - target).abs() > 0.004;
    if (moving) {
      _scene.awake += (target - _scene.awake) * math.min(dt * 2.2, 1.0);
    } else {
      _scene.awake = target;
    }
    if (_scene.flash > 0.01) {
      _scene.flash *= math.pow(0.02, dt).toDouble();
    } else {
      _scene.flash = 0;
    }
    if (widget.animate) _scene.t += dt;
    // peint à ~30 images par seconde pour ménager la batterie
    if (!widget.animate && !moving && _scene.flash == 0) return;
    if ((d - _lastPaint).inMilliseconds < 33) return;
    _lastPaint = d;
    _tick.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: CustomPaint(painter: _painter, size: Size.infinite, isComplex: true, willChange: true),
      ),
    );
  }
}

class _HauntedPainter extends CustomPainter {
  final _Scene sc;
  ui.Picture? _manor;
  Size? _manorSize;

  _HauntedPainter(this.sc, Listenable repaint) : super(repaint: repaint);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;

  static const Color _ink = Color(0xFF08030F);

  // ---------- éléments fixes : colline, manoir, grille, arbres ----------
  void _tree(Canvas c, Paint p, double x, double y, double len, double ang, int d, double wd) {
    if (d <= 0 || len < 4) return;
    final x2 = x + math.cos(ang) * len;
    final y2 = y + math.sin(ang) * len;
    p.strokeWidth = wd;
    c.drawLine(Offset(x, y), Offset(x2, y2), p);
    var seed = math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
    seed -= seed.floorToDouble();
    _tree(c, p, x2, y2, len * 0.74, ang - 0.45 - seed * 0.35, d - 1, wd * 0.7);
    _tree(c, p, x2, y2, len * 0.72, ang + 0.4 + seed * 0.3, d - 1, wd * 0.7);
    if (d > 3 && seed > 0.5) _tree(c, p, x2, y2, len * 0.6, ang + 0.05, d - 2, wd * 0.6);
  }

  ui.Picture _buildManor(Size s) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final w = s.width, h = s.height;
    final gy = h * 0.84;
    final fill = Paint()..color = _ink;

    final hill = Path()
      ..moveTo(0, h)
      ..lineTo(0, gy + 10)
      ..quadraticBezierTo(w * 0.5, gy - 34, w, gy + 14)
      ..lineTo(w, h)
      ..close();
    c.drawPath(hill, Paint()..color = const Color(0xFF0C0518));

    void rect(double x1, double x2, double top) =>
        c.drawRect(Rect.fromLTRB(w * x1, top, w * x2, gy + 16), fill);
    void roof(double x1, double x2, double top, double peak) {
      final p = Path()
        ..moveTo(w * x1 - 6, top)
        ..lineTo(w * (x1 + x2) / 2, peak)
        ..lineTo(w * x2 + 6, top)
        ..close();
      c.drawPath(p, fill);
    }

    rect(0.2, 0.8, gy - h * 0.13);
    roof(0.2, 0.8, gy - h * 0.13, gy - h * 0.21);
    rect(0.43, 0.57, gy - h * 0.33);
    roof(0.43, 0.57, gy - h * 0.33, gy - h * 0.43);
    c.drawRect(Rect.fromLTWH(w * 0.5 - 1.5, gy - h * 0.43 - 26, 3, 26), fill);
    rect(0.2, 0.31, gy - h * 0.25);
    roof(0.2, 0.31, gy - h * 0.25, gy - h * 0.33);
    rect(0.69, 0.8, gy - h * 0.2);
    roof(0.69, 0.8, gy - h * 0.2, gy - h * 0.28);
    c.drawRect(Rect.fromLTWH(w * 0.36, gy - h * 0.25, 12, h * 0.06), fill);
    c.drawRect(Rect.fromLTWH(w * 0.62, gy - h * 0.24, 12, h * 0.05), fill);
    roof(0.34, 0.4, gy - h * 0.17, gy - h * 0.215);
    roof(0.6, 0.66, gy - h * 0.17, gy - h * 0.215);

    final line = Paint()
      ..color = _ink
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (double x = 8; x < w; x += 14) {
      c.drawLine(Offset(x, gy + 22), Offset(x, gy + 2), line);
      final sp = Path()
        ..moveTo(x - 3, gy + 5)
        ..lineTo(x, gy - 4)
        ..lineTo(x + 3, gy + 5);
      c.drawPath(sp, line);
    }
    c.drawLine(Offset(0, gy + 8), Offset(w, gy + 8), line);

    final tp = Paint()
      ..color = const Color(0xFF06020C)
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    _tree(c, tp, w * 0.07, h * 0.9, h * 0.13, -1.62, 7, 6);
    _tree(c, tp, w * 0.95, h * 0.9, h * 0.11, -1.5, 7, 5);
    c.drawRect(Rect.fromLTRB(0, gy + 24, w, h), Paint()..color = const Color(0xFF06020C));
    return rec.endRecording();
  }

  // ---------- éléments animés ----------
  void _ghost(Canvas c, double x, double y, double s, double a) {
    if (a <= 0.01) return;
    final w = 34 * s, h = 48 * s;
    c.save();
    c.translate(x, y);
    final body = Path()
      ..moveTo(-w, h * 0.4)
      ..lineTo(-w, -h * 0.25)
      ..cubicTo(-w, -h * 1.1, w, -h * 1.1, w, -h * 0.25)
      ..lineTo(w, h * 0.4);
    for (var i = 0; i < 4; i++) {
      final px = w - (i + 1) * (w * 2 / 4);
      body.quadraticBezierTo(w - (i + 0.5) * (w * 2 / 4), h * 0.75 + math.sin(sc.t * 4 + i + x) * h * 0.1, px, h * 0.4);
    }
    body.close();
    c.drawPath(
      body,
      Paint()
        ..color = const Color(0xFFC4B5FD).op((0.5 * a).clamp(0.0, 1.0))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 9 * s),
    );
    c.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, -h),
          Offset(0, h * 0.55),
          [
            Colors.white.op((0.95 * a).clamp(0.0, 1.0)),
            const Color(0xFFC4B5FD).op((0.15 * a).clamp(0.0, 1.0)),
          ],
        ),
    );
    final eye = Paint()..color = const Color(0xFF1E0A46).op((0.9 * a).clamp(0.0, 1.0));
    c.drawOval(Rect.fromCenter(center: Offset(-w * 0.38, -h * 0.25), width: w * 0.32, height: h * 0.28), eye);
    c.drawOval(Rect.fromCenter(center: Offset(w * 0.38, -h * 0.25), width: w * 0.32, height: h * 0.28), eye);
    c.drawOval(Rect.fromCenter(center: Offset(0, h * 0.05), width: w * 0.26, height: h * 0.24 + math.sin(sc.t * 3 + x) * 3), eye);
    c.restore();
  }

  void _bat(Canvas c, double x, double y, double s, double ph) {
    final f = math.sin(sc.t * 14 + ph) * 0.7;
    c.save();
    c.translate(x, y);
    c.scale(s, s);
    final p = Paint()..color = const Color(0xFF05010A);
    c.drawOval(Rect.fromCenter(center: Offset.zero, width: 8, height: 6.4), p);
    for (final d in <double>[-1, 1]) {
      final wing = Path()
        ..moveTo(d * 3, -1)
        ..quadraticBezierTo(d * 12, -8 - f * 8, d * 20, -2 + f * 6)
        ..quadraticBezierTo(d * 14, -1, d * 11, 3)
        ..quadraticBezierTo(d * 7, 1, d * 3, 3)
        ..close();
      c.drawPath(wing, p);
    }
    c.restore();
  }

  void _soft(Canvas c, double cx, double cy, double rr, double sy, Color col) {
    c.save();
    c.translate(cx, cy);
    c.scale(1, sy);
    c.drawRect(
      Rect.fromCircle(center: Offset.zero, radius: rr),
      Paint()..shader = ui.Gradient.radial(Offset.zero, rr, [col, col.op(0)]),
    );
    c.restore();
  }

  @override
  void paint(Canvas c, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final t = sc.t;
    final aw = sc.awake.clamp(0.0, 1.0);

    // ciel
    c.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          const [Color(0xFF0A0420), Color(0xFF1D0D45), Color(0xFF3A1670), Color(0xFF12082A)],
          const [0.0, 0.5, 0.82, 1.0],
        ),
    );
    final sp = Paint();
    for (final s in sc.stars) {
      final a = 0.35 + 0.65 * (math.sin(t * s.s + s.p) * 0.5 + 0.5);
      sp.color = const Color(0xFFEDE9FE).op(a);
      c.drawCircle(Offset(s.x * w, s.y * h), s.r, sp);
    }

    // lune
    final mx = w * 0.76, my = h * 0.2, mr = math.min(w, h) * 0.075;
    final moonGlow = aw > 0.5 ? const Color(0x80A5F3FC) : const Color(0x73DDD6FE);
    c.drawCircle(
      Offset(mx, my),
      mr * 4.2,
      Paint()..shader = ui.Gradient.radial(Offset(mx, my), mr * 4.2, [moonGlow, const Color(0x008B5CF6)], [0.14, 1.0]),
    );
    c.drawCircle(Offset(mx, my), mr, Paint()..color = aw > 0.5 ? const Color(0xFFE0FBFF) : const Color(0xFFF5F0FF));
    final cr = Paint()..color = const Color(0x47786AAA);
    c.drawCircle(Offset(mx - 0.3 * mr, my - 0.2 * mr), 0.25 * mr, cr);
    c.drawCircle(Offset(mx + 0.25 * mr, my + 0.1 * mr), 0.2 * mr, cr);
    c.drawCircle(Offset(mx - 0.1 * mr, my + 0.35 * mr), 0.15 * mr, cr);

    // nuages
    for (final cl in sc.clouds) {
      if (sc.t > 0) {
        cl.x += cl.v * 0.033 * (sc.t > 0 && _moving ? 1 : 0);
        if (cl.x > 1.4) cl.x = -0.4;
      }
      _soft(c, cl.x * w, cl.y * h, w * cl.s, 0.35, const Color(0x4D5A32A0));
    }

    // éclairs : un cycle de 13 s, l'éclair tombe à un moment variable du cycle
    var flash = sc.flash;
    if (_moving) {
      final idx = (t / 13).floor();
      final ph = t - idx * 13;
      final st = 5.0 + ((idx * 7919) % 50) / 10;
      if (ph >= st) {
        final f = math.exp(-(ph - st) * 4.5);
        if (f > flash) flash = f;
        if (f > 0.25) {
          final rnd = math.Random(idx * 131 + 7);
          var bx = (0.1 + rnd.nextDouble() * 0.8) * w;
          var by = 0.0;
          final bolt = Path()..moveTo(bx, by);
          while (by < h * 0.55) {
            by += 18 + rnd.nextDouble() * 22;
            bx += (rnd.nextDouble() - 0.5) * 44;
            bolt.lineTo(bx, by);
          }
          c.drawPath(
            bolt,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = Colors.white.op(f.clamp(0.0, 1.0))
              ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 5),
          );
        }
      }
    }
    if (flash > 0.02) {
      c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFC8BEFF).op((flash * 0.3).clamp(0.0, 1.0)));
    }

    // fantômes lointains (derrière le manoir)
    for (final g in sc.ghosts) {
      final vis = g.min == 0 ? 1.0 : ((aw - g.min + 0.3) * 2).clamp(0.0, 1.0);
      if (vis <= 0) continue;
      if (_moving) {
        g.x += g.dir * g.sp * 0.012 * 0.033;
        if (g.x > 1.1) g.x = -0.1;
        if (g.x < -0.1) g.x = 1.1;
      }
      final gy = g.y * h + math.sin(t * g.sp * 2 + g.ph) * 14;
      final a = vis * (0.55 + 0.35 * math.sin(t * 0.8 + g.ph) * 0.5 + 0.17) * math.min(1.0, g.s);
      _ghost(c, g.x * w, gy, g.s * (w / 400), a);
    }

    // manoir
    if (_manor == null || _manorSize != size) {
      _manor?.dispose();
      _manor = _buildManor(size);
      _manorSize = size;
    }
    c.drawPicture(_manor!);

    // fenêtres
    final gy0 = h * 0.84;
    final wins = <List<double>>[
      [0.5, gy0 - h * 0.37, 7, 12],
      [0.5, gy0 - h * 0.27, 10, 17],
      [0.255, gy0 - h * 0.2, 9, 15],
      [0.745, gy0 - h * 0.15, 9, 15],
      [0.34, gy0 - h * 0.08, 11, 17],
      [0.43, gy0 - h * 0.08, 11, 17],
      [0.57, gy0 - h * 0.08, 11, 17],
      [0.66, gy0 - h * 0.08, 11, 17],
      [0.5, gy0 - h * 0.1, 13, 22],
      [0.37, gy0 - h * 0.19, 7, 9],
      [0.63, gy0 - h * 0.19, 7, 9],
    ];
    final col = aw > 0.5 ? const Color(0xFF67E8F9) : const Color(0xFFFDC85A);
    for (var i = 0; i < wins.length; i++) {
      final wd = wins[i];
      final ph = i * 1.7;
      final cx = wd[0] * w, wy = wd[1], ww = wd[2], wh = wd[3];
      final fl = 0.65 + 0.35 * math.sin(t * (2.2 + ph * 0.3) + ph);
      final a = ((0.45 + aw * 0.5) * math.max(0.15, fl)).clamp(0.0, 1.0);
      c.drawCircle(
        Offset(cx, wy + wh / 2),
        wh * 2.2,
        Paint()..shader = ui.Gradient.radial(Offset(cx, wy + wh / 2), wh * 2.2, [col.op(a * 0.45), col.op(0)]),
      );
      final win = Path()
        ..moveTo(cx - ww / 2, wy + wh)
        ..lineTo(cx - ww / 2, wy + ww / 2)
        ..arcTo(Rect.fromCircle(center: Offset(cx, wy + ww / 2), radius: ww / 2), math.pi, math.pi, false)
        ..lineTo(cx + ww / 2, wy + wh)
        ..close();
      c.drawPath(win, Paint()..color = col.op(a));
      final bar = Paint()..color = const Color(0xD908030F);
      c.drawRect(Rect.fromLTWH(cx - 0.7, wy, 1.4, wh), bar);
      c.drawRect(Rect.fromLTWH(cx - ww / 2, wy + wh * 0.5, ww, 1.2), bar);
      if (i % 4 == 2 && aw > 0.3) {
        final gp = math.sin(t * 0.7 + ph);
        c.drawOval(
          Rect.fromCenter(center: Offset(cx + gp * 2, wy + wh * 0.55), width: ww * 0.56, height: wh * 0.6),
          Paint()..color = const Color(0xFF08030F).op((0.7 * math.min(1.0, aw)).clamp(0.0, 1.0)),
        );
      }
    }

    // chauves-souris
    for (final b in sc.bats) {
      if (_moving) {
        b.x += b.v * 0.033;
        if (b.x > 1.25) b.x = -0.25;
        if (b.x < -0.25) b.x = 1.25;
      }
      _bat(c, b.x * w, b.y * h + math.sin(t * 1.6 + b.ph) * 18, b.s * (w / 400) * 0.95, b.ph);
    }

    // brouillard
    for (var i = 0; i < 4; i++) {
      final raw = t * (8 + i * 5) * (i.isOdd ? 1 : -1) + i * 160;
      final fx = (raw % (w + 500)) - 250;
      final fy = h * (0.78 + i * 0.045);
      final rr = w * (0.55 + i * 0.1);
      _soft(c, fx, fy, rr, 0.22, const Color(0xFFBEAAFF).op(0.16 + aw * 0.1));
    }

    // grands fantômes au premier plan quand le VPN est connecté
    if (aw > 0.15) {
      final a2 = math.min(1.0, (aw - 0.15) * 1.6);
      _ghost(c, w * 0.15 + math.sin(t * 0.5) * 22, h * 0.62 + math.cos(t * 0.7) * 16, 1.45 * (w / 400), 0.22 * a2);
      _ghost(c, w * 0.86 + math.cos(t * 0.45) * 22, h * 0.5 + math.sin(t * 0.6) * 18, 1.7 * (w / 400), 0.18 * a2);
    }

    // vignette + léger voile pour garder les textes lisibles
    c.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(w / 2, h * 0.5),
          h * 0.8,
          const [Color(0x00000000), Color(0xA6020008)],
          const [0.31, 1.0],
        ),
    );
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0x30000000));
  }

  bool get _moving => sc.animating;
}
