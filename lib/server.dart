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
  String net; // tcp | ws | grpc
  String path;
  String hosth;
  String sec; // tls | none
  String sni;

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
  });

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
      );
}

/// Lit un lien vless:// vmess:// trojan:// ss:// et renvoie un Server (ou null).
Server? parseLink(String raw) {
  final l = raw.trim();
  if (l.isEmpty) return null;
  try {
    if (l.startsWith('vmess://')) {
      final j = jsonDecode(_b64d(l.substring(8))) as Map<String, dynamic>;
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
      final q = body.indexOf('?');
      if (q >= 0) body = body.substring(0, q);
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
      return Server(
        id: newId(),
        type: 'ss',
        name: name.isEmpty ? host : name,
        host: host,
        port: port,
        method: method,
        pass: pass,
      );
    }

    final pm = RegExp(r'^(vless|trojan)://').firstMatch(l);
    if (pm != null) {
      final type = pm.group(1)!;
      final u = Uri.parse(l);
      final q = u.queryParameters;
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
      );
      final cred = Uri.decodeComponent(u.userInfo);
      if (type == 'vless') {
        s.uuid = cred;
        s.sec = (q['security'] ?? 'none') == 'none' ? 'none' : 'tls';
      } else {
        s.pass = cred;
      }
      return s;
    }
  } catch (_) {}
  return null;
}

/// Construit le lien de partage d'un serveur.
String toLink(Server s) {
  final nm = Uri.encodeComponent(s.name);
  if (s.type == 'vmess') {
    return 'vmess://' +
        _b64e(jsonEncode({
          'v': '2',
          'ps': s.name,
          'add': s.host,
          'port': s.port.toString(),
          'id': s.uuid,
          'aid': '0',
          'net': s.net,
          'type': 'none',
          'host': s.hosth,
          'path': s.path,
          'tls': s.sec == 'tls' ? 'tls' : '',
          'sni': s.sni,
        }));
  }
  if (s.type == 'ss') {
    return 'ss://' + _b64e('${s.method}:${s.pass}') + '@${s.host}:${s.port}#$nm';
  }
  if (s.type == 'vless' || s.type == 'trojan') {
    final q = <String, String>{'type': s.net};
    if (s.type == 'vless') {
      q['encryption'] = 'none';
      q['security'] = s.sec;
    } else {
      q['security'] = 'tls';
    }
    if (s.path.isNotEmpty) q[s.net == 'grpc' ? 'serviceName' : 'path'] = s.path;
    if (s.hosth.isNotEmpty) q['host'] = s.hosth;
    if (s.sni.isNotEmpty) q['sni'] = s.sni;
    final qs = q.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final cred = Uri.encodeComponent(s.type == 'vless' ? s.uuid : s.pass);
    return '${s.type}://$cred@${s.host}:${s.port}?$qs#$nm';
  }
  final extra =
      s.sni.isNotEmpty ? '?sni=${Uri.encodeQueryComponent(s.sni)}' : '';
  return 'ssh://${Uri.encodeComponent(s.user)}:${Uri.encodeComponent(s.pass)}@${s.host}:${s.port}$extra#$nm';
}
