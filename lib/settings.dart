import 'package:flutter/material.dart';

/// Palette de la boule de connexion.
class OrbPalette {
  final String name;
  final Color light;
  final Color mid;
  final Color deep;
  final Color glow;
  const OrbPalette(this.name, this.light, this.mid, this.deep, this.glow);
}

const kOrbPalettes = <OrbPalette>[
  OrbPalette('Violet', Color(0xFF8B7BF0), Color(0xFF4C1FB0), Color(0xFF1A0A45), Color(0xFFA78BFA)),
  OrbPalette('Océan', Color(0xFF7DD3FC), Color(0xFF0E5FB8), Color(0xFF061C4A), Color(0xFF38BDF8)),
  OrbPalette('Rose', Color(0xFFF9A8D4), Color(0xFFBE185D), Color(0xFF4A0A2A), Color(0xFFF472B6)),
  OrbPalette('Émeraude', Color(0xFF6EE7B7), Color(0xFF047857), Color(0xFF03281F), Color(0xFF34D399)),
  OrbPalette('Or', Color(0xFFFDE68A), Color(0xFFB45309), Color(0xFF3B1A04), Color(0xFFFBBF24)),
  OrbPalette('Rouge', Color(0xFFFCA5A5), Color(0xFFB91C1C), Color(0xFF3F0A0A), Color(0xFFF87171)),
];

/// Ambiances de l'application (lueurs d'arrière-plan). 0..5 = comme les couleurs de la boule, 6 = noir pur.
const kThemeNames = <String>['Violet', 'Océan', 'Rose', 'Émeraude', 'Or', 'Rouge', 'Noir (AMOLED)'];

List<Color> themeGlows(int t) {
  if (t <= 0) {
    return const [Color(0x6B6366F1), Color(0x5FA855F7), Color(0x2438BDF8)];
  }
  if (t < kOrbPalettes.length) {
    final p = kOrbPalettes[t];
    return [p.mid.withAlpha(0x6B), p.glow.withAlpha(0x5F), p.light.withAlpha(0x24)];
  }
  return const [Color(0x00000000), Color(0x00000000), Color(0x00000000)];
}

/// Lueurs actuellement affichées (mises à jour quand le thème change).
List<Color> gGlows = themeGlows(0);

const kOrbStyles = <String>['Boule d\'eau', 'Verre néon', 'Anneau'];

/// Serveurs DNS proposés (DoH : passent dans le tunnel).
const kDnsPresets = <String, List<String>>{
  'cloudflare': ['https://1.1.1.1/dns-query', 'https://1.0.0.1/dns-query'],
  'google': ['https://8.8.8.8/dns-query', 'https://8.8.4.4/dns-query'],
  'quad9': ['https://9.9.9.9/dns-query', 'https://149.112.112.112/dns-query'],
  'adguard': ['https://94.140.14.14/dns-query', 'https://94.140.15.15/dns-query'],
};

const kDnsNames = <String, String>{
  'auto': 'Automatique (celui du serveur)',
  'cloudflare': 'Cloudflare (1.1.1.1)',
  'google': 'Google (8.8.8.8)',
  'quad9': 'Quad9 (9.9.9.9)',
  'adguard': 'AdGuard (bloque les pubs)',
  'custom': 'Personnalisé',
};

/// Tous les réglages de l'application (enregistrés sur le téléphone).
class AppSettings {
  // bouton de connexion
  int theme = 0; // ambiance de l'application
  int orbColor = 0;
  int orbStyle = 0;
  bool orbAnim = true;
  double orbSize = 256;

  // affichage
  String speedUnit = 'MB'; // MB | Mb | KB

  // connexion
  bool fast = true;
  bool blockQuic = true;
  bool lan = false;
  bool autoReconnect = true;
  int reconnectTries = 3;
  String dns = 'auto';
  String dnsCustom = '';
  List<String> excludedApps = <String>[];

  // vérification de la connexion / auto ping
  String checkUrl = 'https://www.gstatic.com/generate_204';
  int checkInterval = 15; // secondes, 0 = jamais
  int checkTimeout = 8;
  int checkFails = 3; // échecs de suite avant d'agir, 0 = jamais
  String failAction = 'reconnect'; // reconnect | stop | none

  // SSH
  int sshKeepAlive = 15;
  int sshPool = 2; // connexions SSH en parallèle (1 à 4)

  // performance Xray : tampon par connexion en Ko (0 = réglage d'origine)
  int bufferKb = 512;

  // limites de session
  int autoStopMin = 0; // coupe le VPN après X minutes (0 = jamais)
  int dataLimitMb = 0; // coupe le VPN après X Mo échangés (0 = illimité)

  // journal
  int logLimit = 500;

  AppSettings();

  void resetDefaults() {
    final d = AppSettings();
    theme = d.theme;
    orbColor = d.orbColor;
    orbStyle = d.orbStyle;
    orbAnim = d.orbAnim;
    orbSize = d.orbSize;
    speedUnit = d.speedUnit;
    fast = d.fast;
    blockQuic = d.blockQuic;
    lan = d.lan;
    autoReconnect = d.autoReconnect;
    reconnectTries = d.reconnectTries;
    dns = d.dns;
    dnsCustom = d.dnsCustom;
    excludedApps = <String>[];
    checkUrl = d.checkUrl;
    checkInterval = d.checkInterval;
    checkTimeout = d.checkTimeout;
    checkFails = d.checkFails;
    failAction = d.failAction;
    sshKeepAlive = d.sshKeepAlive;
    sshPool = d.sshPool;
    bufferKb = d.bufferKb;
    autoStopMin = d.autoStopMin;
    dataLimitMb = d.dataLimitMb;
    logLimit = d.logLimit;
  }

  OrbPalette get palette => kOrbPalettes[orbColor.clamp(0, kOrbPalettes.length - 1).toInt()];

  Map<String, dynamic> toJson() => {
        'theme': theme,
        'orbColor': orbColor,
        'orbStyle': orbStyle,
        'orbAnim': orbAnim,
        'orbSize': orbSize,
        'speedUnit': speedUnit,
        'fast': fast,
        'blockQuic': blockQuic,
        'lan': lan,
        'autoReconnect': autoReconnect,
        'reconnectTries': reconnectTries,
        'dns': dns,
        'dnsCustom': dnsCustom,
        'excludedApps': excludedApps,
        'checkUrl': checkUrl,
        'checkInterval': checkInterval,
        'checkTimeout': checkTimeout,
        'checkFails': checkFails,
        'failAction': failAction,
        'sshKeepAlive': sshKeepAlive,
        'sshPool': sshPool,
        'bufferKb': bufferKb,
        'autoStopMin': autoStopMin,
        'dataLimitMb': dataLimitMb,
        'logLimit': logLimit,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final s = AppSettings();
    int i(String k, int d) => (j[k] is num) ? (j[k] as num).toInt() : d;
    bool b(String k, bool d) => (j[k] is bool) ? j[k] as bool : d;
    String str(String k, String d) => (j[k] is String && (j[k] as String).isNotEmpty) ? j[k] as String : d;
    s.theme = i('theme', 0).clamp(0, kThemeNames.length - 1).toInt();
    s.orbColor = i('orbColor', 0).clamp(0, kOrbPalettes.length - 1).toInt();
    s.orbStyle = i('orbStyle', 0).clamp(0, kOrbStyles.length - 1).toInt();
    s.orbAnim = b('orbAnim', true);
    s.orbSize = (j['orbSize'] is num ? (j['orbSize'] as num).toDouble() : 256.0).clamp(190.0, 290.0).toDouble();
    s.speedUnit = str('speedUnit', 'MB');
    s.fast = b('fast', true);
    s.blockQuic = b('blockQuic', true);
    s.lan = b('lan', false);
    s.autoReconnect = b('autoReconnect', true);
    s.reconnectTries = i('reconnectTries', 3);
    s.dns = str('dns', 'auto');
    s.dnsCustom = (j['dnsCustom'] ?? '').toString();
    final apps = j['excludedApps'];
    if (apps is List) s.excludedApps = apps.map((e) => e.toString()).toList();
    s.checkUrl = str('checkUrl', 'https://www.gstatic.com/generate_204');
    s.checkInterval = i('checkInterval', 15);
    s.checkTimeout = i('checkTimeout', 8);
    s.checkFails = i('checkFails', 3);
    s.failAction = str('failAction', 'reconnect');
    s.sshKeepAlive = i('sshKeepAlive', 15);
    s.sshPool = i('sshPool', 2).clamp(1, 4).toInt();
    s.bufferKb = i('bufferKb', 512);
    s.autoStopMin = i('autoStopMin', 0);
    s.dataLimitMb = i('dataLimitMb', 0);
    s.logLimit = i('logLimit', 500);
    return s;
  }

  /// Serveurs DNS à imposer, ou null pour garder ceux du serveur.
  List<String>? dnsServers() {
    if (dns == 'auto') return null;
    final p = kDnsPresets[dns];
    if (p != null) return p;
    final c = dnsCustom.trim();
    if (c.isEmpty) return null;
    return c.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
  }
}
