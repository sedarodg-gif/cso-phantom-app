import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, InternetAddress;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'settings.dart';
import 'speed_page.dart';

const _ch = MethodChannel('cso/share');

/// Lien entre les pages de réglages et l'écran principal.
class SettingsHost {
  final AppSettings st;
  final VoidCallback changed; // enregistre et applique les réglages
  final List<String> Function() logs;
  final VoidCallback clearLogs;
  final VoidCallback exportAll;
  final VoidCallback resetSettings;
  const SettingsHost({
    required this.st,
    required this.changed,
    required this.logs,
    required this.clearLogs,
    required this.exportAll,
    required this.resetSettings,
  });
}

// ---------- briques d'interface ----------

Widget _glow(Alignment c, double r, Color col) => Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(center: c, radius: r, colors: [col, col.withAlpha(0)]),
        ),
      ),
    );

class CsoPage extends StatelessWidget {
  final String title;
  final Widget child;
  const CsoPage({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(
        children: [
          _glow(const Alignment(-0.9, -1.0), 0.95, gGlows[0]),
          _glow(const Alignment(0.95, -0.55), 0.8, gGlows[1]),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 18, 6),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Retour',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(title,
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget sTitle(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(children: [
        Text(t, style: const TextStyle(color: kCyan, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: .5)),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: Colors.white.withAlpha(30))),
      ]),
    );

Widget sTile({
  required String title,
  String? sub,
  IconData? icon,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          decoration: glass(r: 18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: kRed, size: 22),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                      if (sub != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(sub, style: const TextStyle(fontSize: 12, color: kMute, height: 1.35)),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget sSwitch(String title, String sub, bool v, void Function(bool) on, {IconData? icon}) {
  return sTile(
    title: title,
    sub: sub,
    icon: icon,
    onTap: () => on(!v),
    trailing: Switch(value: v, activeColor: kRed, onChanged: on),
  );
}

Widget _chev() => const Icon(Icons.chevron_right, color: kMute);

Widget _value(String t) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 120),
      child: Text(t,
          textAlign: TextAlign.right,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: kRed, fontSize: 13, fontWeight: FontWeight.w600)),
    );

Future<T?> _pick<T>(BuildContext c, String title, Map<T, String> opts, T cur) {
  return showDialog<T>(
    context: c,
    builder: (ctx) => SimpleDialog(
      backgroundColor: const Color(0xFF10092A),
      title: Text(title),
      children: [
        for (final e in opts.entries)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, e.key),
            child: Row(children: [
              Expanded(child: Text(e.value)),
              if (e.key == cur) const Icon(Icons.check, color: kRed),
            ]),
          ),
      ],
    ),
  );
}

Future<String?> _ask(BuildContext c, String title, String init, {bool number = false, String hint = ''}) {
  final ctl = TextEditingController(text: init);
  return showDialog<String>(
    context: c,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF10092A),
      title: Text(title),
      content: TextField(
        controller: ctl,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: number ? TextInputType.number : TextInputType.url,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

void _push(BuildContext c, Widget w) => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => w));

String _secLabel(int s) => s == 0 ? 'Jamais' : '$s s';

// ======================= PAGE PRINCIPALE =======================

class SettingsPage extends StatefulWidget {
  final SettingsHost host;
  const SettingsPage({super.key, required this.host});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get st => widget.host.st;

  void _set(VoidCallback f) {
    setState(f);
    widget.host.changed();
  }

  Future<void> _hardwareId() async {
    String id;
    try {
      id = (await _ch.invokeMethod<String>('deviceId')) ?? '';
    } catch (_) {
      id = '';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10092A),
        title: const Text('Hardware ID'),
        content: SelectableText(id.isEmpty ? 'Indisponible sur cet appareil.' : id,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
        actions: [
          if (id.isNotEmpty)
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: id));
                Navigator.pop(ctx);
              },
              child: const Text('Copier'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
        ],
      ),
    );
  }

  void _reset() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10092A),
        title: const Text('Réinitialiser les réglages ?'),
        content: const Text('Tes serveurs ne sont pas touchés.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Non')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.host.resetSettings();
              setState(() {});
            },
            child: const Text('Réinitialiser'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    return CsoPage(
      title: 'Réglages',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          sTitle('Général'),
          sTile(
            icon: Icons.palette_outlined,
            title: 'Thème et personnalisation',
            sub: "Ambiance de l'application : Violet, Océan, Rose, Émeraude, Or, Rouge ou Noir",
            trailing: _chev(),
            onTap: () => _push(context, ThemePage(host: h)),
          ),
          sTile(
            icon: Icons.bubble_chart_outlined,
            title: 'Bouton de connexion',
            sub: 'Couleur, style, animation et taille de la boule',
            trailing: _chev(),
            onTap: () => _push(context, OrbPage(host: h)),
          ),
          sTile(
            icon: Icons.speed_outlined,
            title: 'Unité de vitesse',
            sub: 'Affichage des débits',
            trailing: _value(st.speedUnit == 'Mb' ? 'Mb/s' : (st.speedUnit == 'KB' ? 'KB/s' : 'MB/s')),
            onTap: () async {
              final v = await _pick<String>(context, 'Unité de vitesse',
                  {'MB': 'MB/s (méga-octets)', 'Mb': 'Mb/s (mégabits)', 'KB': 'KB/s (kilo-octets)'}, st.speedUnit);
              if (v != null) _set(() => st.speedUnit = v);
            },
          ),
          sTitle('Connexion'),
          sSwitch('Mode rapide', 'DNS IPv4 et routage allégé', st.fast, (v) => _set(() => st.fast = v),
              icon: Icons.bolt_outlined),
          sSwitch('Bloquer QUIC (UDP 443)',
              'Force les navigateurs et applis à utiliser TCP. Recommandé : QUIC ne passe pas dans la plupart des tunnels.',
              st.blockQuic, (v) => _set(() => st.blockQuic = v),
              icon: Icons.block_outlined),
          sSwitch('Autoriser le réseau local', 'Imprimantes, partage de fichiers : ne passe pas dans le VPN',
              st.lan, (v) => _set(() => st.lan = v),
              icon: Icons.lan_outlined),
          sTile(
            icon: Icons.shield_outlined,
            title: 'Comportement du VPN',
            sub: 'DNS, reconnexion automatique, kill switch, applications hors VPN',
            trailing: _chev(),
            onTap: () => _push(context, BehaviorPage(host: h)),
          ),
          sTile(
            icon: Icons.monitor_heart_outlined,
            title: 'Vérification de la connexion',
            sub: 'URL de test, intervalle, délai et Auto Ping',
            trailing: _chev(),
            onTap: () => _push(context, CheckPage(host: h)),
          ),
          sTitle('Tunnel'),
          sTile(
            icon: Icons.terminal_outlined,
            title: 'SSH : keep-alive',
            sub: 'Intervalle des messages qui gardent le tunnel SSH ouvert (5 à 120 s)',
            trailing: _value('${st.sshKeepAlive} s'),
            onTap: () async {
              final v = await _ask(context, 'Keep-alive SSH (secondes)', '${st.sshKeepAlive}', number: true);
              final n = int.tryParse(v ?? '');
              if (n != null) _set(() => st.sshKeepAlive = n.clamp(5, 120).toInt());
            },
          ),
          sTile(
            icon: Icons.call_split,
            title: 'SSH : connexions parallèles',
            sub: 'Plusieurs connexions SSH en même temps pour aller plus vite (utilise plusieurs cœurs du téléphone). '
                'Mets 1 si ton compte SSH n\'accepte qu\'une seule connexion.',
            trailing: _value('${st.sshPool}'),
            onTap: () async {
              final v = await _pick<int>(context, 'Connexions SSH', {1: '1', 2: '2 (recommandé)', 3: '3', 4: '4'}, st.sshPool);
              if (v != null) _set(() => st.sshPool = v);
            },
          ),
          sTile(
            icon: Icons.memory,
            title: 'Tampon de transfert',
            sub: 'Mémoire par connexion dans le moteur Xray : plus grand = débit plus élevé.',
            trailing: _value(st.bufferKb == 0 ? 'Auto' : '${st.bufferKb} Ko'),
            onTap: () async {
              final v = await _pick<int>(context, 'Tampon de transfert',
                  {0: 'Auto (réglage d\'origine)', 256: '256 Ko', 512: '512 Ko (recommandé)', 1024: '1024 Ko'}, st.bufferKb);
              if (v != null) _set(() => st.bufferKb = v);
            },
          ),
          sTile(
            icon: Icons.timer_outlined,
            title: 'Minuteur de déconnexion',
            sub: 'Coupe le VPN automatiquement après une durée',
            trailing: _value(st.autoStopMin == 0 ? 'Jamais' : '${st.autoStopMin} min'),
            onTap: () async {
              final v = await _pick<int>(context, 'Minuteur de déconnexion',
                  {0: 'Jamais', 30: '30 minutes', 60: '1 heure', 120: '2 heures', 240: '4 heures', 480: '8 heures'},
                  st.autoStopMin);
              if (v != null) _set(() => st.autoStopMin = v);
            },
          ),
          sTile(
            icon: Icons.data_usage,
            title: 'Limite de données',
            sub: 'Coupe le VPN quand la session a échangé cette quantité de données',
            trailing: _value(st.dataLimitMb == 0 ? 'Illimitée' : '${st.dataLimitMb} Mo'),
            onTap: () async {
              final v = await _pick<int>(context, 'Limite de données',
                  {0: 'Illimitée', 100: '100 Mo', 500: '500 Mo', 1000: '1 Go', 2000: '2 Go', 5000: '5 Go'},
                  st.dataLimitMb);
              if (v != null) _set(() => st.dataLimitMb = v);
            },
          ),
          sTile(
            icon: Icons.lock_clock_outlined,
            title: 'VPN toujours actif / blocage',
            sub: "Ouvre les réglages VPN d'Android : « VPN permanent » et « Bloquer les connexions sans VPN » (kill switch).",
            trailing: _chev(),
            onTap: () async {
              try {
                await _ch.invokeMethod<bool>('openVpnSettings');
              } catch (_) {}
            },
          ),
          sTile(
            icon: Icons.hub_outlined,
            title: 'V2Ray / Xray',
            sub: 'Mux, SNI, Host, allowInsecure et transport se règlent dans chaque serveur (Modifier).',
          ),
          sTitle('Outils'),
          sTile(
            icon: Icons.speed,
            title: 'Test de vitesse',
            sub: 'Mesure le débit réel du tunnel (téléchargement)',
            trailing: _chev(),
            onTap: () => _push(context, const SpeedPage()),
          ),
          sTile(
            icon: Icons.my_location_outlined,
            title: "Chasseur d'IP",
            sub: 'Ton IP publique et résolution de domaines',
            trailing: _chev(),
            onTap: () => _push(context, const IpPage()),
          ),
          sTile(
            icon: Icons.fact_check_outlined,
            title: 'Vérificateur de réponse',
            sub: 'Teste une URL : code, temps et en-têtes',
            trailing: _chev(),
            onTap: () => _push(context, const ResponsePage()),
          ),
          sTile(
            icon: Icons.smartphone_outlined,
            title: 'Hardware ID',
            sub: "Identifiant de cet appareil",
            trailing: _chev(),
            onTap: _hardwareId,
          ),
          sTile(
            icon: Icons.receipt_long_outlined,
            title: 'Journal',
            sub: 'Événements de connexion et erreurs',
            trailing: _chev(),
            onTap: () => _push(context, LogPage(host: h)),
          ),
          sTitle('Données'),
          sTile(
            icon: Icons.ios_share,
            title: 'Exporter toutes les configurations',
            sub: 'Lien, fichier ou partage',
            trailing: _chev(),
            onTap: h.exportAll,
          ),
          sTile(
            icon: Icons.restart_alt,
            title: 'Réinitialiser les réglages',
            sub: 'Revenir aux valeurs par défaut',
            onTap: _reset,
          ),
          sTitle('À propos'),
          sTile(
            icon: Icons.info_outline,
            title: 'CSO PHANTOM $kAppVersion',
            sub: 'Moteurs : Xray-core (VLESS, VMess, Trojan, Shadowsocks) et SSH',
          ),
          const SizedBox(height: 18),
          Center(child: Image.asset('assets/creator.png', width: 260)),
          const Center(
            child: Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Créé par Charles Sedar Ouedraogo', style: TextStyle(color: kMute, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= BOUTON DE CONNEXION =======================

class ThemePage extends StatefulWidget {
  final SettingsHost host;
  const ThemePage({super.key, required this.host});

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  AppSettings get st => widget.host.st;

  void _set(VoidCallback f) {
    setState(f);
    widget.host.changed();
  }

  Widget _swatch(int i) {
    final Color a = i < kOrbPalettes.length ? kOrbPalettes[i].light : const Color(0xFF3A3A3A);
    final Color b = i < kOrbPalettes.length ? kOrbPalettes[i].mid : const Color(0xFF000000);
    final sel = st.theme == i;
    return GestureDetector(
      onTap: () => _set(() {
        st.theme = i;
        if (i < kOrbPalettes.length) st.orbColor = i;
      }),
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(sel ? 30 : 12),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: sel ? kRed : Colors.white.withAlpha(30), width: sel ? 2 : 1),
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [a, b],
                ),
                border: Border.all(color: Colors.white.withAlpha(70)),
              ),
              child: sel ? const Icon(Icons.check, color: Colors.white, size: 22) : null,
            ),
            const SizedBox(height: 8),
            Text(kThemeNames[i],
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    return CsoPage(
      title: 'Thème',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          sTitle("Ambiance de l'application"),
          const Text(
            "Choisis une ambiance : elle change les lueurs du fond et la couleur de la boule en même temps. "
            "Tu peux ensuite régler la boule séparément.",
            style: TextStyle(color: kMute, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (var i = 0; i < kThemeNames.length; i++) _swatch(i)],
          ),
          sTitle('Bouton de connexion'),
          sTile(
            icon: Icons.bubble_chart_outlined,
            title: 'Personnaliser la boule',
            sub: 'Couleur, style (boule d\'eau, verre néon, anneau), animation et taille',
            trailing: _chev(),
            onTap: () => _push(context, OrbPage(host: h)),
          ),
        ],
      ),
    );
  }
}

class OrbPage extends StatefulWidget {
  final SettingsHost host;
  const OrbPage({super.key, required this.host});

  @override
  State<OrbPage> createState() => _OrbPageState();
}

class _OrbPageState extends State<OrbPage> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();

  AppSettings get st => widget.host.st;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _set(VoidCallback f) {
    setState(f);
    widget.host.changed();
  }

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: 'Bouton de connexion',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          Center(
            child: SizedBox(
              width: st.orbSize,
              height: st.orbSize,
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) => CustomPaint(
                  painter: WaterOrbPainter(st.orbAnim ? _c.value : 0.25, true, st.palette, st.orbStyle),
                ),
              ),
            ),
          ),
          sTitle('Couleur'),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (var i = 0; i < kOrbPalettes.length; i++)
                Semantics(
                  button: true,
                  label: kOrbPalettes[i].name,
                  child: GestureDetector(
                    onTap: () => _set(() => st.orbColor = i),
                    child: Column(children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [kOrbPalettes[i].light, kOrbPalettes[i].mid],
                          ),
                          border: Border.all(
                            color: st.orbColor == i ? Colors.white : Colors.white.withAlpha(40),
                            width: st.orbColor == i ? 2.5 : 1,
                          ),
                          boxShadow: st.orbColor == i
                              ? [BoxShadow(color: kOrbPalettes[i].glow.withAlpha(150), blurRadius: 14)]
                              : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(kOrbPalettes[i].name, style: const TextStyle(fontSize: 11, color: kMute)),
                    ]),
                  ),
                ),
            ],
          ),
          sTitle('Style'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < kOrbStyles.length; i++)
                ChoiceChip(
                  label: Text(kOrbStyles[i]),
                  selected: st.orbStyle == i,
                  onSelected: (_) => _set(() => st.orbStyle = i),
                ),
            ],
          ),
          sTitle('Animation et taille'),
          sSwitch('Animation', 'Vagues, bulles et anneau en mouvement. La désactiver économise la batterie.',
              st.orbAnim, (v) => _set(() => st.orbAnim = v)),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            decoration: glass(r: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Taille : ${st.orbSize.round()}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                Slider(
                  value: st.orbSize,
                  min: 190,
                  max: 290,
                  divisions: 10,
                  activeColor: kRed,
                  onChanged: (v) => _set(() => st.orbSize = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= COMPORTEMENT DU VPN =======================

class BehaviorPage extends StatefulWidget {
  final SettingsHost host;
  const BehaviorPage({super.key, required this.host});

  @override
  State<BehaviorPage> createState() => _BehaviorPageState();
}

class _BehaviorPageState extends State<BehaviorPage> {
  AppSettings get st => widget.host.st;

  void _set(VoidCallback f) {
    setState(f);
    widget.host.changed();
  }

  Future<void> _vpnSettings() async {
    try {
      await _ch.invokeMethod<bool>('openVpnSettings');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ouvre Réglages Android > Réseau > VPN')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: 'Comportement du VPN',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          sTitle('DNS'),
          sTile(
            icon: Icons.dns_outlined,
            title: 'Serveur DNS',
            sub: 'Les requêtes passent chiffrées (DoH) dans le tunnel',
            trailing: _value(kDnsNames[st.dns]?.split(' (').first ?? st.dns),
            onTap: () async {
              final v = await _pick<String>(context, 'Serveur DNS', kDnsNames, st.dns);
              if (v != null) _set(() => st.dns = v);
            },
          ),
          if (st.dns == 'custom')
            sTile(
              icon: Icons.edit_outlined,
              title: 'DNS personnalisé',
              sub: st.dnsCustom.isEmpty ? 'Ex. https://dns.exemple.com/dns-query' : st.dnsCustom,
              onTap: () async {
                final v = await _ask(context, 'DNS personnalisé (URL ou IP, séparés par des virgules)', st.dnsCustom);
                if (v != null) _set(() => st.dnsCustom = v);
              },
            ),
          sTitle('Reconnexion'),
          sSwitch('Reconnexion automatique', 'Relance le VPN si la connexion tombe sans que tu l\'aies coupée',
              st.autoReconnect, (v) => _set(() => st.autoReconnect = v),
              icon: Icons.sync),
          sSwitch('Mode compatibilité',
              "Utilise la configuration d'origine du serveur, sans mes optimisations (mode rapide, DNS, blocage QUIC, tampon). À essayer si rien ne passe.",
              st.compat, (v) => _set(() => st.compat = v),
              icon: Icons.shield_outlined),
          sSwitch('Vibration', 'Retour tactile quand tu touches la boule et à la connexion',
              st.haptics, (v) => _set(() => st.haptics = v),
              icon: Icons.vibration),
          sSwitch('Changer de serveur automatiquement',
              "Si la reconnexion échoue, essaie le serveur suivant de ta liste",
              st.autoSwitch, (v) => _set(() => st.autoSwitch = v),
              icon: Icons.swap_horiz),
          sTile(
            icon: Icons.repeat,
            title: 'Nombre de tentatives',
            sub: 'Avant d\'abandonner',
            trailing: _value('${st.reconnectTries}'),
            onTap: () async {
              final v = await _pick<int>(context, 'Tentatives', {1: '1', 3: '3', 5: '5', 10: '10'}, st.reconnectTries);
              if (v != null) _set(() => st.reconnectTries = v);
            },
          ),
          sTitle('Protection'),
          sTile(
            icon: Icons.gpp_maybe_outlined,
            title: 'Kill switch',
            sub: 'Android le gère lui-même : ouvre les réglages VPN, touche l\'engrenage de CSO Phantom, '
                'puis active « VPN permanent » et « Bloquer les connexions sans VPN ».',
            trailing: _chev(),
            onTap: _vpnSettings,
          ),
          sTile(
            icon: Icons.apps_outlined,
            title: 'Applications hors VPN',
            sub: st.excludedApps.isEmpty
                ? 'Toutes les applications passent par le VPN'
                : '${st.excludedApps.length} application(s) ne passent pas par le VPN',
            trailing: _chev(),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AppsPage(host: widget.host)));
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

// ======================= APPLICATIONS HORS VPN =======================

class AppsPage extends StatefulWidget {
  final SettingsHost host;
  const AppsPage({super.key, required this.host});

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  List<Map<String, String>> _apps = [];
  bool _loading = true;
  String _err = '';
  String _q = '';

  AppSettings get st => widget.host.st;

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  Future<void> _loadApps() async {
    try {
      final r = await _ch.invokeMethod<List<dynamic>>('apps');
      final l = <Map<String, String>>[];
      for (final e in r ?? <dynamic>[]) {
        if (e is Map) {
          l.add({'name': (e['name'] ?? '').toString(), 'pkg': (e['pkg'] ?? '').toString()});
        }
      }
      l.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _apps = l;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = "Impossible de lister les applications ($e).";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = _apps
        .where((a) => q.isEmpty || a['name']!.toLowerCase().contains(q) || a['pkg']!.toLowerCase().contains(q))
        .toList();
    return CsoPage(
      title: 'Applications hors VPN',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Rechercher une application',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white.withAlpha(18),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
            child: Text(
              'Les applications cochées utilisent ta connexion normale, sans VPN. '
              'Le changement s\'applique à la prochaine connexion.',
              style: const TextStyle(fontSize: 12, color: kMute, height: 1.4),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_err.isNotEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_err, style: const TextStyle(color: kBad)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final a = shown[i];
                          final pkg = a['pkg']!;
                          final on = st.excludedApps.contains(pkg);
                          return sTile(
                            title: a['name']!,
                            sub: pkg,
                            onTap: () {
                              setState(() {
                                if (on) {
                                  st.excludedApps.remove(pkg);
                                } else {
                                  st.excludedApps.add(pkg);
                                }
                              });
                              widget.host.changed();
                            },
                            trailing: Checkbox(
                              value: on,
                              activeColor: kRed,
                              onChanged: (_) {
                                setState(() {
                                  if (on) {
                                    st.excludedApps.remove(pkg);
                                  } else {
                                    st.excludedApps.add(pkg);
                                  }
                                });
                                widget.host.changed();
                              },
                            ),
                          );
                        },
                      )),
          ),
        ],
      ),
    );
  }
}

// ======================= VÉRIFICATION DE LA CONNEXION =======================

class CheckPage extends StatefulWidget {
  final SettingsHost host;
  const CheckPage({super.key, required this.host});

  @override
  State<CheckPage> createState() => _CheckPageState();
}

class _CheckPageState extends State<CheckPage> {
  AppSettings get st => widget.host.st;

  void _set(VoidCallback f) {
    setState(f);
    widget.host.changed();
  }

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: 'Vérification de la connexion',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          sTile(
            icon: Icons.link,
            title: 'URL de test',
            sub: st.checkUrl,
            onTap: () async {
              final v = await _ask(context, 'URL de test', st.checkUrl, hint: 'https://www.gstatic.com/generate_204');
              if (v != null && v.startsWith('http')) _set(() => st.checkUrl = v);
            },
          ),
          sTile(
            icon: Icons.timer_outlined,
            title: 'Auto Ping : intervalle',
            sub: 'Teste régulièrement la connexion et la garde active',
            trailing: _value(_secLabel(st.checkInterval)),
            onTap: () async {
              final v = await _pick<int>(context, 'Intervalle',
                  {0: 'Jamais', 10: '10 s', 15: '15 s', 30: '30 s', 60: '60 s', 120: '120 s'}, st.checkInterval);
              if (v != null) _set(() => st.checkInterval = v);
            },
          ),
          sTile(
            icon: Icons.hourglass_bottom,
            title: 'Délai maximum',
            sub: 'Au-delà, le test est considéré comme échoué',
            trailing: _value('${st.checkTimeout} s'),
            onTap: () async {
              final v = await _pick<int>(context, 'Délai maximum', {5: '5 s', 8: '8 s', 12: '12 s', 20: '20 s'}, st.checkTimeout);
              if (v != null) _set(() => st.checkTimeout = v);
            },
          ),
          sTile(
            icon: Icons.error_outline,
            title: 'Échecs avant action',
            sub: 'Nombre de tests ratés de suite',
            trailing: _value(st.checkFails == 0 ? 'Jamais' : '${st.checkFails}'),
            onTap: () async {
              final v = await _pick<int>(context, 'Échecs avant action', {0: 'Jamais', 2: '2', 3: '3', 5: '5'}, st.checkFails);
              if (v != null) _set(() => st.checkFails = v);
            },
          ),
          sTile(
            icon: Icons.flash_on_outlined,
            title: 'Action',
            sub: 'Que faire quand la connexion ne répond plus',
            trailing: _value(st.failAction == 'reconnect' ? 'Reconnecter' : (st.failAction == 'stop' ? 'Couper' : 'Rien')),
            onTap: () async {
              final v = await _pick<String>(context, 'Action',
                  {'reconnect': 'Reconnecter', 'stop': 'Déconnecter', 'none': 'Rien faire'}, st.failAction);
              if (v != null) _set(() => st.failAction = v);
            },
          ),
        ],
      ),
    );
  }
}

// ======================= CHASSEUR D'IP =======================

class IpPage extends StatefulWidget {
  const IpPage({super.key});

  @override
  State<IpPage> createState() => _IpPageState();
}

class _IpPageState extends State<IpPage> {
  final _host = TextEditingController();
  Map<String, String>? _info;
  String _err = '';
  bool _loading = false;
  List<String> _resolved = [];
  String _resErr = '';
  bool _resolving = false;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _loadIp() async {
    setState(() {
      _loading = true;
      _err = '';
    });
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse('https://ipwho.is/')).timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      final j = jsonDecode(body);
      if (j is! Map || j['success'] == false) throw 'réponse invalide';
      final conn = j['connection'];
      final info = <String, String>{
        'IP': (j['ip'] ?? '').toString(),
        'Pays': (j['country'] ?? '').toString(),
        'Région': (j['region'] ?? '').toString(),
        'Ville': (j['city'] ?? '').toString(),
        'Opérateur': conn is Map ? (conn['isp'] ?? '').toString() : '',
      };
      info.removeWhere((k, v) => v.isEmpty);
      if (!mounted) return;
      setState(() => _info = info);
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = 'Échec : $e');
    } finally {
      c.close(force: true);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolve() async {
    final h = _host.text.trim().replaceAll(RegExp(r'^https?://'), '').split('/').first;
    if (h.isEmpty) return;
    setState(() {
      _resolving = true;
      _resErr = '';
      _resolved = [];
    });
    try {
      final r = await InternetAddress.lookup(h).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() => _resolved = r.map((a) => a.address).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _resErr = 'Introuvable : $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: "Chasseur d'IP",
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          sTitle('Mon IP publique'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: glass(r: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_info != null)
                  for (final e in _info!.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(e.key, style: const TextStyle(color: kMute)),
                          Flexible(
                            child: SelectableText(e.value,
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    )
                else
                  const Text("Touche « Trouver mon IP » pour la voir.", style: TextStyle(color: kMute)),
                if (_err.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_err, style: const TextStyle(color: kBad)),
                  ),
                const SizedBox(height: 10),
                const Text(
                  'Connecté, tu vois l\'IP de ton serveur : si c\'est celle de ton opérateur, le trafic ne passe pas par le VPN.',
                  style: TextStyle(fontSize: 12, color: kMute, height: 1.4),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _loading ? null : _loadIp,
                    child: Text(_loading ? 'Recherche...' : 'Trouver mon IP'),
                  ),
                ),
              ],
            ),
          ),
          sTitle('Résoudre un domaine'),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: glass(r: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _host,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _resolve(),
                  decoration: InputDecoration(
                    hintText: 'exemple.com',
                    filled: true,
                    fillColor: Colors.white.withAlpha(18),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _resolving ? null : _resolve,
                    child: Text(_resolving ? 'Recherche...' : 'Résoudre'),
                  ),
                ),
                if (_resErr.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_resErr, style: const TextStyle(color: kBad)),
                  ),
                for (final a in _resolved)
                  InkWell(
                    onTap: () => Clipboard.setData(ClipboardData(text: a)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        Expanded(child: Text(a, style: const TextStyle(fontFamily: 'monospace', fontSize: 15))),
                        const Icon(Icons.copy, size: 16, color: kMute),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= VÉRIFICATEUR DE RÉPONSE =======================

class ResponsePage extends StatefulWidget {
  const ResponsePage({super.key});

  @override
  State<ResponsePage> createState() => _ResponsePageState();
}

class _ResponsePageState extends State<ResponsePage> {
  final _url = TextEditingController(text: 'https://');
  final _hostHdr = TextEditingController();
  bool _head = false;
  bool _insecure = true;
  bool _busy = false;
  String _status = '';
  String _err = '';
  String _headers = '';
  String _body = '';

  @override
  void dispose() {
    _url.dispose();
    _hostHdr.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _err = 'URL invalide');
      return;
    }
    setState(() {
      _busy = true;
      _err = '';
      _status = '';
      _headers = '';
      _body = '';
    });
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    if (_insecure) c.badCertificateCallback = (cert, host, port) => true;
    final sw = Stopwatch()..start();
    try {
      final req = await (_head ? c.headUrl(uri) : c.getUrl(uri)).timeout(const Duration(seconds: 12));
      req.followRedirects = false;
      final h = _hostHdr.text.trim();
      if (h.isNotEmpty) req.headers.host = h;
      final res = await req.close().timeout(const Duration(seconds: 12));
      final bytes = await res.fold<List<int>>(<int>[], (a, b) {
        if (a.length < 1500) a.addAll(b.take(1500 - a.length));
        return a;
      }).timeout(const Duration(seconds: 12));
      final hb = StringBuffer();
      res.headers.forEach((name, values) => hb.writeln('$name: ${values.join(', ')}'));
      if (!mounted) return;
      setState(() {
        _status = '${res.statusCode} ${res.reasonPhrase} · ${sw.elapsedMilliseconds} ms';
        _headers = hb.toString().trim();
        _body = _head ? '' : utf8.decode(bytes, allowMalformed: true);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = 'Échec : $e');
    } finally {
      c.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white.withAlpha(18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      );

  @override
  Widget build(BuildContext context) {
    return CsoPage(
      title: 'Vérificateur de réponse',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
        children: [
          TextField(
            controller: _url,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: _dec('https://exemple.com'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _hostHdr,
            autocorrect: false,
            enableSuggestions: false,
            decoration: _dec('En-tête Host (optionnel)'),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Requête HEAD (sans le contenu)'),
            value: _head,
            activeColor: kRed,
            onChanged: (v) => setState(() => _head = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ignorer le certificat TLS'),
            value: _insecure,
            activeColor: kRed,
            onChanged: (v) => setState(() => _insecure = v),
          ),
          FilledButton(onPressed: _busy ? null : _send, child: Text(_busy ? 'Envoi...' : 'Envoyer')),
          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_err, style: const TextStyle(color: kBad)),
            ),
          if (_status.isNotEmpty) ...[
            sTitle('Réponse'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: glass(r: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kGreen)),
                  const SizedBox(height: 10),
                  SelectableText(_headers, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4)),
                  if (_body.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Début du contenu', style: TextStyle(color: kMute, fontSize: 12)),
                    const SizedBox(height: 4),
                    SelectableText(_body, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4)),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ======================= JOURNAL =======================

class LogPage extends StatefulWidget {
  final SettingsHost host;
  const LogPage({super.key, required this.host});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.host.logs().reversed.toList();
    return CsoPage(
      title: 'Journal',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: lines.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: lines.reversed.join('\n')));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Journal copié')));
                        },
                  child: const Text('Copier'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    widget.host.clearLogs();
                    setState(() {});
                  },
                  child: const Text('Effacer'),
                ),
              ),
            ]),
          ),
          Expanded(
            child: lines.isEmpty
                ? const Center(child: Text('Aucun événement', style: TextStyle(color: kMute)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: SelectableText(lines[i],
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
