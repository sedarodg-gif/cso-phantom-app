import 'dart:convert';

String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

String _pad(String s) {
  var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  while (t.length % 4 != 0) {
    t += '=';
  }
  return t;
}

String _b64d(String s) => utf8.decode(base64.decode(_pad(s)));
String _b64e(String s) => base64.encode(utf8.encode(s));

bool _truthy(Object? v) {
  final s = (v ?? '').toString().trim().toLowerCase();
  return s == '1' || s == 'true';
}

/// Valeur « allowInsecure » d'un lien : vide = réglage par défaut (activé).
bool _insecureOf(Object? v) {
  final s = (v ?? '').toString().trim().toLowerCase();
  if (s.isEmpty) return true;
  return s == '1' || s == 'true';
}

class Server {
  String id;
  String name;
  String type; // vless | vmess | trojan | ss | ssh
  String host;
  int port;
  String uuid;
  String user;
  String pass;
  String method;
  String net; // tcp | ws | grpc | ...
  String path;
  String hosth;
  String sec; // tls | none | reality
  String sni;
  bool insecure; // ignorer la vérification du certificat TLS
  bool mux; // multiplexage (VMess / VLESS / Trojan)
  String payload; // SSH : payload envoyé avant la connexion
  String proxy; // SSH : proxy intermédiaire « hote:port »
  bool locked; // config partagée : détails masqués dans l'appli
  int expires; // date d'expiration (ms depuis 1970), 0 = illimité
  String msg; // message affiché à l'import
  String connMsg; // message affiché à la connexion
  String hwids; // identifiants d'appareils autorisés (vide = tous)
  bool lockSsh; // masque l'utilisateur et le mot de passe SSH
  Map<String, String> extra; // autres paramètres du lien (aid, type, flow, fp...)

  Server({
    required this.id,
    this.name = '',
    this.type = 'vless',
    this.host = '',
    this.port = 443,
    this.uuid = '',
    this.user = '',
    this.pass = '',
    this.method = 'aes-256-gcm',
    this.net = 'tcp',
    this.path = '',
    this.hosth = '',
    this.sec = 'tls',
    this.sni = '',
    this.insecure = true,
    this.mux = false,
    this.payload = '',
    this.proxy = '',
    this.locked = false,
    this.expires = 0,
    this.msg = '',
    this.connMsg = '',
    this.hwids = '',
    this.lockSsh = false,
    Map<String, String>? extra,
  }) : extra = extra ?? <String, String>{};

  /// Identifiants d'appareils autorisés (minuscules).
  List<String> get hwidList => hwids
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  bool get expired =>
      expires > 0 && DateTime.now().millisecondsSinceEpoch > expires;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'host': host,
        'port': port,
        'uuid': uuid,
        'user': user,
        'pass': pass,
        'method': method,
        'net': net,
        'path': path,
        'hosth': hosth,
        'sec': sec,
        'sni': sni,
        'insecure': insecure,
        'mux': mux,
        'payload': payload,
        'proxy': proxy,
        'locked': locked,
        'expires': expires,
        'msg': msg,
        'connMsg': connMsg,
        'hwids': hwids,
        'lockSsh': lockSsh,
        'extra': extra,
      };

  factory Server.fromJson(Map<String, dynamic> j) => Server(
        id: (j['id'] ?? newId()).toString(),
        name: (j['name'] ?? '').toString(),
        type: (j['type'] ?? 'vless').toString(),
        host: (j['host'] ?? '').toString(),
        port: int.tryParse((j['port'] ?? '443').toString()) ?? 443,
        uuid: (j['uuid'] ?? '').toString(),
        user: (j['user'] ?? '').toString(),
        pass: (j['pass'] ?? '').toString(),
        method: (j['method'] ?? 'aes-256-gcm').toString(),
        net: (j['net'] ?? 'tcp').toString(),
        path: (j['path'] ?? '').toString(),
        hosth: (j['hosth'] ?? '').toString(),
        sec: (j['sec'] ?? 'tls').toString(),
        sni: (j['sni'] ?? '').toString(),
        insecure: j['insecure'] == null ? true : j['insecure'] == true,
        mux: j['mux'] == true,
        payload: (j['payload'] ?? '').toString(),
        proxy: (j['proxy'] ?? '').toString(),
        locked: j['locked'] == true,
        expires: int.tryParse((j['expires'] ?? '0').toString()) ?? 0,
        msg: (j['msg'] ?? '').toString(),
        connMsg: (j['connMsg'] ?? '').toString(),
        hwids: (j['hwids'] ?? '').toString(),
        lockSsh: j['lockSsh'] == true,
        extra: j['extra'] is Map
            ? (j['extra'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()))
            : null,
      );
}

/// Lit un lien vless:// vmess:// trojan:// ss:// ssh:// et renvoie un Server (ou null).
Server? parseLink(String raw) {
  final l = raw.trim();
  if (l.isEmpty) return null;
  try {
    if (l.startsWith('vmess://')) {
      final j = jsonDecode(_b64d(l.substring(8))) as Map<String, dynamic>;
      const mapped = {
        'v', 'ps', 'add', 'port', 'id', 'net', 'path', 'host', 'tls', 'sni',
        'allowInsecure', 'insecure', 'skip-cert-verify',
      };
      final extra = <String, String>{};
      j.forEach((k, v) {
        if (!mapped.contains(k) && v != null && v.toString().isNotEmpty) {
          extra[k] = v.toString();
        }
      });
      final insKeys = ['allowInsecure', 'insecure', 'skip-cert-verify']
          .where((k) => j.containsKey(k))
          .toList();
      final tls = (j['tls'] ?? '').toString();
      return Server(
        id: newId(),
        type: 'vmess',
        name: (j['ps'] ?? j['add']).toString(),
        host: j['add'].toString(),
        port: int.parse(j['port'].toString()),
        uuid: j['id'].toString(),
        net: (j['net'] ?? 'tcp').toString(),
        path: (j['path'] ?? '').toString(),
        hosth: (j['host'] ?? '').toString(),
        sec: (tls.isNotEmpty && tls != 'none') ? 'tls' : 'none',
        sni: (j['sni'] ?? '').toString(),
        insecure: insKeys.isEmpty ? true : _insecureOf(j[insKeys.first]),
        extra: extra,
      );
    }

    if (l.startsWith('ss://')) {
      var body = l.substring(5);
      var name = '';
      final h = body.indexOf('#');
      if (h >= 0) {
        name = Uri.decodeComponent(body.substring(h + 1));
        body = body.substring(0, h);
      }
      var query = '';
      final q = body.indexOf('?');
      if (q >= 0) {
        query = body.substring(q + 1);
        body = body.substring(0, q);
      }
      if (body.endsWith('/')) body = body.substring(0, body.length - 1);
      String method;
      String pass;
      String host;
      int port;
      if (body.contains('@')) {
        final at = body.lastIndexOf('@');
        final u = body.substring(0, at);
        final hp = body.substring(at + 1);
        String cred;
        try {
          cred = _b64d(u);
        } catch (_) {
          cred = Uri.decodeComponent(u);
        }
        final c = cred.indexOf(':');
        method = cred.substring(0, c);
        pass = cred.substring(c + 1);
        final cp = hp.lastIndexOf(':');
        host = hp.substring(0, cp);
        port = int.parse(hp.substring(cp + 1));
      } else {
        final d = _b64d(body);
        final mm = RegExp(r'^(.+?):(.+)@(.+):(\d+)$').firstMatch(d);
        if (mm == null) return null;
        method = mm.group(1)!;
        pass = mm.group(2)!;
        host = mm.group(3)!;
        port = int.parse(mm.group(4)!);
      }
      // plugin v2ray-plugin / xray-plugin  ->  WebSocket (+ TLS)
      var net = 'tcp';
      var sec = 'none';
      var hosth = '';
      var path = '';
      var sni = '';
      final extra = <String, String>{};
      if (query.isNotEmpty) {
        final qp = Uri.splitQueryString(query);
        final plugin = qp['plugin'] ?? '';
        if (plugin.isNotEmpty) {
          final parts = plugin.split(';');
          final pname = parts.first.trim();
          final opts = <String, String>{};
          for (final p in parts.skip(1)) {
            final i = p.indexOf('=');
            if (i > 0) {
              opts[p.substring(0, i).trim()] = p.substring(i + 1).trim();
            } else if (p.trim().isNotEmpty) {
              opts[p.trim()] = '';
            }
          }
          if (pname.contains('v2ray-plugin') || pname.contains('xray-plugin')) {
            final mode = opts['mode'] ?? 'websocket';
            if (mode == 'websocket') {
              net = 'ws';
              path = opts['path'] ?? '/';
              hosth = opts['host'] ?? '';
            }
            if (opts.containsKey('tls')) {
              sec = 'tls';
              sni = opts['host'] ?? '';
            }
          } else {
            extra['unsupported'] = pname;
          }
        }
      }
      return Server(
        id: newId(),
        type: 'ss',
        name: name.isEmpty ? host : name,
        host: host,
        port: port,
        method: method,
        pass: pass,
        net: net,
        sec: sec,
        hosth: hosth,
        path: path,
        sni: sni,
        extra: extra,
      );
    }

    if (l.startsWith('ssh://')) {
      final u = Uri.parse(l);
      final q = u.queryParameters;
      final ui = u.userInfo;
      final ci = ui.indexOf(':');
      final user = Uri.decodeComponent(ci >= 0 ? ui.substring(0, ci) : ui);
      final pass = ci >= 0 ? Uri.decodeComponent(ui.substring(ci + 1)) : '';
      var pl = '';
      final pq = q['payload'] ?? '';
      if (pq.isNotEmpty) {
        try {
          pl = _b64d(pq);
        } catch (_) {}
      }
      return Server(
        id: newId(),
        type: 'ssh',
        name: u.fragment.isNotEmpty ? Uri.decodeComponent(u.fragment) : u.host,
        host: u.host,
        port: u.hasPort ? u.port : 22,
        user: user,
        pass: pass,
        sec: _truthy(q['tls']) ? 'tls' : 'none',
        sni: q['sni'] ?? '',
        hosth: q['host'] ?? '',
        payload: pl,
        proxy: q['proxy'] ?? '',
        insecure: q['insecure'] == null ? true : _insecureOf(q['insecure']),
      );
    }

    final pm = RegExp(r'^(vless|trojan)://').firstMatch(l);
    if (pm != null) {
      final type = pm.group(1)!;
      final u = Uri.parse(l);
      final q = u.queryParameters;
      const mapped = {
        'type', 'path', 'serviceName', 'host', 'sni', 'peer', 'security',
        'allowInsecure', 'insecure',
      };
      final extra = <String, String>{
        for (final e in q.entries)
          if (!mapped.contains(e.key) && e.value.isNotEmpty) e.key: e.value,
      };
      final insKey = q.containsKey('allowInsecure')
          ? 'allowInsecure'
          : (q.containsKey('insecure') ? 'insecure' : '');
      final s = Server(
        id: newId(),
        type: type,
        name: u.fragment.isNotEmpty ? Uri.decodeComponent(u.fragment) : u.host,
        host: u.host,
        port: u.hasPort ? u.port : 443,
        net: q['type'] ?? 'tcp',
        path: q['path'] ?? q['serviceName'] ?? '',
        hosth: q['host'] ?? '',
        sni: q['sni'] ?? q['peer'] ?? '',
        sec: q['security'] ?? (type == 'trojan' ? 'tls' : 'none'),
        insecure: insKey.isEmpty ? true : _insecureOf(q[insKey]),
        extra: extra,
      );
      final cred = Uri.decodeComponent(u.userInfo);
      if (type == 'vless') {
        s.uuid = cred;
      } else {
        s.pass = cred;
      }
      return s;
    }
  } catch (_) {}
  return null;
}

/// Construit le lien de partage d'un serveur.
/// [core] = true : version destinée au moteur (sans plugin ss).
String toLink(Server s, {bool core = false}) {
  final nm = Uri.encodeComponent(s.name);
  if (s.type == 'vmess') {
    final m = <String, dynamic>{
      'v': '2',
      'ps': s.name,
      'add': s.host,
      'port': s.port.toString(),
      'id': s.uuid,
      'aid': '0',
      'scy': 'auto',
      'net': s.net,
      'type': 'none',
      'host': s.hosth,
      'path': s.path,
      'tls': s.sec == 'tls' ? 'tls' : '',
      'sni': s.sni,
    };
    s.extra.forEach((k, v) => m[k] = v);
    m['allowInsecure'] = s.insecure ? '1' : '0';
    return 'vmess://${_b64e(jsonEncode(m))}';
  }
  if (s.type == 'ss') {
    var plugin = '';
    if (!core && s.net == 'ws') {
      final host = s.hosth.isNotEmpty ? s.hosth : s.sni;
      final tlsPart = s.sec == 'tls' ? ';tls' : '';
      final pth = s.path.isEmpty ? '/' : s.path;
      final pl = 'v2ray-plugin$tlsPart;host=$host;path=$pth';
      plugin = '/?plugin=${Uri.encodeQueryComponent(pl)}';
    }
    return 'ss://${_b64e('${s.method}:${s.pass}')}@${s.host}:${s.port}$plugin#$nm';
  }
  if (s.type == 'vless' || s.type == 'trojan') {
    final q = <String, String>{'type': s.net};
    if (s.type == 'vless') {
      q['encryption'] = 'none';
      q['security'] = s.sec;
    } else {
      q['security'] = s.sec == 'none' ? 'none' : 'tls';
    }
    if (s.path.isNotEmpty) q[s.net == 'grpc' ? 'serviceName' : 'path'] = s.path;
    if (s.hosth.isNotEmpty) q['host'] = s.hosth;
    if (s.sni.isNotEmpty) q['sni'] = s.sni;
    if (s.sec != 'none') q['allowInsecure'] = s.insecure ? '1' : '0';
    s.extra.forEach((k, v) => q[k] = v);
    final qs = q.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final cred = Uri.encodeComponent(s.type == 'vless' ? s.uuid : s.pass);
    return '${s.type}://$cred@${s.host}:${s.port}?$qs#$nm';
  }
  // ssh
  final q = <String, String>{};
  if (s.sec == 'tls') q['tls'] = '1';
  if (s.sni.isNotEmpty) q['sni'] = s.sni;
  if (s.hosth.isNotEmpty) q['host'] = s.hosth;
  if (s.payload.isNotEmpty) q['payload'] = base64Url.encode(utf8.encode(s.payload));
  if (s.proxy.isNotEmpty) q['proxy'] = s.proxy;
  if (s.sec == 'tls') q['insecure'] = s.insecure ? '1' : '0';
  final qs = q.isEmpty
      ? ''
      : '?${q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
  return 'ssh://${Uri.encodeComponent(s.user)}:${Uri.encodeComponent(s.pass)}@${s.host}:${s.port}$qs#$nm';
}

// ======================= PARTAGE (csophantom://) =======================

/// Crée un lien de partage contenant une ou plusieurs configurations.
/// [lock] : détails masqués chez le destinataire. [lockSsh] : compte SSH masqué.
/// [expires] : date d'expiration en ms (0 = illimitée). [hwids] : appareils autorisés.
String exportBundle(
  List<Server> list, {
  bool lock = false,
  bool lockSsh = false,
  int expires = 0,
  String name = '',
  String msg = '',
  String connMsg = '',
  String hwids = '',
}) {
  final items = list.map((s) {
    final j = s.toJson();
    j['locked'] = lock || s.locked;
    j['lockSsh'] = lockSsh || s.lockSsh;
    j['expires'] = expires > 0 ? expires : s.expires;
    if (name.isNotEmpty && list.length == 1) j['name'] = name;
    if (msg.isNotEmpty) j['msg'] = msg;
    if (connMsg.isNotEmpty) j['connMsg'] = connMsg;
    if (hwids.trim().isNotEmpty) j['hwids'] = hwids.trim();
    return j;
  }).toList();
  final body = base64Url.encode(utf8.encode(jsonEncode({'v': 1, 's': items})));
  return 'csophantom://$body';
}

/// Lit un lien csophantom:// et renvoie les serveurs (nouveaux identifiants), ou null.
List<Server>? parseBundle(String raw) {
  final l = raw.trim();
  if (!l.startsWith('csophantom://')) return null;
  try {
    final j = jsonDecode(_b64d(l.substring(13)));
    if (j is! Map || j['s'] is! List) return null;
    final out = <Server>[];
    for (final e in j['s'] as List) {
      final s = Server.fromJson(Map<String, dynamic>.from(e as Map));
      s.id = newId() + out.length.toString();
      out.add(s);
    }
    return out;
  } catch (_) {
    return null;
  }
}
