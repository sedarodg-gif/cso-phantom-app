import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

// ======================================================================
//  Moteur SSH de CSO PHANTOM
//  - ouvre la connexion SSH (direct, payload, proxy, SSL/TLS + SNI, WebSocket)
//  - expose un proxy SOCKS5 local (127.0.0.1) qui passe par le tunnel SSH
//  - tourne dans un « isolate » séparé pour ne pas ralentir l'interface
// ======================================================================

class SshEngine {
  final void Function(Map<String, dynamic>) onEvent;
  SshEngine(this.onEvent);

  Isolate? _iso;
  ReceivePort? _rx;
  SendPort? _cmd;
  int port = 0;
  List<String> ips = [];

  /// Démarre le tunnel. Lance une erreur (String) si la connexion échoue.
  Future<void> start(Map<String, dynamic> cfg) async {
    stop();
    final rx = ReceivePort();
    _rx = rx;
    final ready = Completer<void>();
    ready.future.ignore();
    rx.listen((dynamic m) {
      if (m is! Map) return;
      final t = m['t'];
      if (t == 'cmd') {
        _cmd = m['port'] as SendPort;
      } else if (t == 'ready') {
        port = (m['port'] as num).toInt();
        ips = List<String>.from(m['ips'] as List);
        if (!ready.isCompleted) ready.complete();
      } else if (t == 'error' && !ready.isCompleted) {
        ready.completeError((m['msg'] ?? 'Erreur SSH').toString());
      } else {
        onEvent(Map<String, dynamic>.from(m));
      }
    });
    _iso = await Isolate.spawn<List<dynamic>>(_sshEntry, <dynamic>[rx.sendPort, cfg]);
    try {
      await ready.future.timeout(const Duration(seconds: 60));
    } catch (e) {
      stop();
      rethrow;
    }
  }

  void stop() {
    try {
      _cmd?.send('stop');
    } catch (_) {}
    _cmd = null;
    final iso = _iso;
    _iso = null;
    if (iso != null) {
      Timer(const Duration(seconds: 2), () => iso.kill(priority: Isolate.immediate));
    }
    _rx?.close();
    _rx = null;
  }
}

class _Stats {
  int up = 0;
  int down = 0;
}

bool _isReady = false;

String _clean(Object e) {
  final s = e.toString();
  if (e is TimeoutException) return 'Délai dépassé : le serveur ne répond pas';
  if (s.contains('AuthFail') || s.contains('AuthAbort')) {
    return 'Identifiants SSH refusés (utilisateur ou mot de passe)';
  }
  if (e is SocketException) return 'Connexion impossible : ${e.message}';
  if (e is HandshakeException || e is TlsException) return 'Échec TLS/SNI : $s';
  return s.length > 180 ? s.substring(0, 180) : s;
}

void _sshEntry(List<dynamic> args) {
  final out = args[0] as SendPort;
  runZonedGuarded(() {
    _run(args);
  }, (Object e, StackTrace s) {
    try {
      out.send({'t': _isReady ? 'log' : 'error', 'msg': _clean(e)});
    } catch (_) {}
  });
}

Future<void> _run(List<dynamic> args) async {
  final out = args[0] as SendPort;
  final cfg = Map<String, dynamic>.from(args[1] as Map);
  final cmd = ReceivePort();
  out.send({'t': 'cmd', 'port': cmd.sendPort});

  SSHClient? client;
  ServerSocket? server;
  Timer? timer;
  _UdpGw? gwRef;
  var closing = false;
  final st = _Stats();

  Future<void> shutdown() async {
    if (closing) return;
    closing = true;
    timer?.cancel();
    gwRef?.close();
    try {
      await server?.close();
    } catch (_) {}
    try {
      client?.close();
    } catch (_) {}
    cmd.close();
  }

  cmd.listen((dynamic m) {
    if (m == 'stop') shutdown();
  });

  try {
    final host = (cfg['host'] ?? '').toString();
    final port = (cfg['port'] as num?)?.toInt() ?? 22;
    final user = (cfg['user'] ?? '').toString();
    final pass = (cfg['pass'] ?? '').toString();
    final tls = cfg['tls'] == true;
    final insecure = cfg['insecure'] != false;
    final sni = (cfg['sni'] ?? '').toString().trim();
    final hosth = (cfg['hosth'] ?? '').toString().trim();
    final proxy = (cfg['proxy'] ?? '').toString().trim();
    var payload = (cfg['payload'] ?? '').toString();

    // cible réelle de la connexion TCP (proxy intermédiaire ou serveur SSH)
    var ch = host;
    var cp = port;
    if (proxy.isNotEmpty) {
      final i = proxy.lastIndexOf(':');
      if (i > 0) {
        ch = proxy.substring(0, i);
        cp = int.tryParse(proxy.substring(i + 1)) ?? 8080;
      } else {
        ch = proxy;
        cp = 8080;
      }
    }

    // résolution AVANT l'ouverture du VPN
    final addrs = await InternetAddress.lookup(ch).timeout(const Duration(seconds: 12));
    if (addrs.isEmpty) throw 'Serveur introuvable : $ch';
    var addr = addrs.first;
    for (final a in addrs) {
      if (a.type == InternetAddressType.IPv4) {
        addr = a;
        break;
      }
    }
    final ips = addrs.map((a) => a.address).toList();

    final raw = await Socket.connect(addr, cp, timeout: const Duration(seconds: 15));
    raw.setOption(SocketOption.tcpNoDelay, true);
    Socket sock = raw;
    if (tls) {
      final sn = sni.isNotEmpty ? sni : (hosth.isNotEmpty ? hosth : host);
      sock = await SecureSocket.secure(
        raw,
        host: sn,
        onBadCertificate: (X509Certificate c) => insecure,
      ).timeout(const Duration(seconds: 15));
    }

    if (payload.trim().isEmpty && proxy.isNotEmpty) {
      payload = '[netData][crlf]Host: [host_port][crlf][crlf]';
    }
    final hasPayload = payload.trim().isNotEmpty;
    if (hasPayload) {
      await _sendPayload(sock, payload, hosth.isNotEmpty ? hosth : host, host, port);
    }

    final tun = _Tunnel(sock, hasPayload);
    await tun.ready.future.timeout(const Duration(seconds: 8), onTimeout: () {});

    final c = SSHClient(
      tun,
      username: user,
      onPasswordRequest: () => pass,
      keepAliveInterval: Duration(seconds: ((cfg['keepAlive'] as num?)?.toInt() ?? 15).clamp(5, 120).toInt()),
    );
    client = c;
    await c.authenticated.timeout(const Duration(seconds: 30));

    final gwPort = (cfg['udpgw'] as num?)?.toInt() ?? 0;
    final gw = gwPort > 0 ? _UdpGw(c, gwPort, st) : null;
    gwRef = gw;
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = srv;
    srv.listen((Socket s) {
      _socks(s, c, st, gw).catchError((Object _) {});
    });

    c.done.then((_) {
      if (!closing) out.send({'t': 'closed'});
      shutdown();
    }, onError: (Object e) {
      if (!closing) out.send({'t': 'closed', 'msg': _clean(e)});
      shutdown();
    });

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      out.send({'t': 'stat', 'up': st.up, 'down': st.down});
    });

    _isReady = true;
    out.send({'t': 'ready', 'port': srv.port, 'ips': ips});
  } catch (e) {
    out.send({'t': 'error', 'msg': _clean(e)});
    await shutdown();
  }
}

// ----------------------------------------------------------------------
//  Payload (HTTP Injector / Dark Tunnel)
//  Balises : [crlf] [cr] [lf] [lfcr] [host] [port] [host_port] [protocol]
//            [ssh] [netData] [ua] [split] [instant_split] [delay_split]
// ----------------------------------------------------------------------
Future<void> _sendPayload(
    Socket s, String tpl, String hostHeader, String sshHost, int sshPort) async {
  var t = tpl.replaceAll('\r\n', '\n');
  if (!t.contains('[crlf]') && t.contains('\n')) {
    t = t.replaceAll('\n', '[crlf]');
  } else {
    t = t.replaceAll('\n', '');
  }
  t = t.replaceAllMapped(RegExp(r'\[(\w+)\]'), (Match m) {
    switch (m.group(1)!.toLowerCase()) {
      case 'crlf':
        return '\r\n';
      case 'cr':
        return '\r';
      case 'lf':
        return '\n';
      case 'lfcr':
        return '\n\r';
      case 'host':
        return hostHeader;
      case 'port':
        return '$sshPort';
      case 'host_port':
        return '$sshHost:$sshPort';
      case 'ssh':
        return '$sshHost:$sshPort';
      case 'protocol':
        return 'HTTP/1.1';
      case 'netdata':
        return 'CONNECT $sshHost:$sshPort HTTP/1.1';
      case 'ua':
        return 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
      default:
        return m.group(0)!;
    }
  });

  final re = RegExp(r'\[(split|instant_split|delay_split)\]', caseSensitive: false);
  final parts = <String>[];
  final delays = <int>[];
  var last = 0;
  for (final m in re.allMatches(t)) {
    parts.add(t.substring(last, m.start));
    final k = m.group(1)!.toLowerCase();
    delays.add(k == 'instant_split' ? 0 : (k == 'delay_split' ? 1500 : 500));
    last = m.end;
  }
  parts.add(t.substring(last));

  for (var i = 0; i < parts.length; i++) {
    if (parts[i].isNotEmpty) {
      s.add(utf8.encode(parts[i]));
      await s.flush();
    }
    if (i < delays.length && delays[i] > 0) {
      await Future<void>.delayed(Duration(milliseconds: delays[i]));
    }
  }
}

// ----------------------------------------------------------------------
//  Tunnel : lit la réponse HTTP du payload (101 / 200...) puis laisse
//  passer le flux SSH tel quel.
// ----------------------------------------------------------------------
class _Tunnel implements SSHSocket {
  final Socket _sock;
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final BytesBuilder _pend = BytesBuilder();
  final Completer<void> ready = Completer<void>();
  bool _pass;

  static final List<int> _ssh = utf8.encode('SSH-');
  static final List<int> _http = utf8.encode('HTTP/');

  _Tunnel(this._sock, bool expectHttp) : _pass = !expectHttp {
    ready.future.ignore();
    if (_pass) ready.complete();
    _sock.listen(
      _onData,
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
        _out.addError(e);
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError('Connexion fermée par le serveur');
        }
        _out.close();
      },
    );
  }

  static bool _starts(List<int> b, List<int> p) {
    if (b.length < p.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (b[i] != p[i]) return false;
    }
    return true;
  }

  static bool _isPrefix(List<int> b, List<int> p) {
    if (b.length > p.length) return false;
    for (var i = 0; i < b.length; i++) {
      if (b[i] != p[i]) return false;
    }
    return true;
  }

  static int _find(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }

  void _release(Uint8List b) {
    _pass = true;
    _pend.clear();
    _out.add(b);
    if (!ready.isCompleted) ready.complete();
  }

  void _onData(Uint8List data) {
    if (_pass) {
      _out.add(data);
      return;
    }
    _pend.add(data);
    while (true) {
      final b = _pend.toBytes();
      if (b.isEmpty) return;
      if (_starts(b, _ssh)) {
        _release(b);
        return;
      }
      if (_starts(b, _http)) {
        final i = _find(b);
        if (i < 0) return; // en-tête incomplet : on attend la suite
        final head = ascii.decode(b.sublist(0, i), allowInvalid: true);
        final m = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(head);
        final code = m == null ? 0 : int.parse(m.group(1)!);
        if (code != 101 && (code < 200 || code >= 300)) {
          final line = head.split('\r\n').first;
          if (!ready.isCompleted) ready.completeError('Le serveur a répondu : $line');
          _sock.destroy();
          return;
        }
        _pend.clear();
        if (i + 4 < b.length) _pend.add(b.sublist(i + 4));
        if (!ready.isCompleted) ready.complete();
        continue;
      }
      if (b.length < 5 && (_isPrefix(b, _ssh) || _isPrefix(b, _http))) return;
      _release(b);
      return;
    }
  }

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  StreamSink<List<int>> get sink => _sock;

  @override
  Future<void> get done => _sock.done;

  @override
  Future<void> close() async {
    await _sock.close();
  }

  @override
  void destroy() {
    _sock.destroy();
  }

  @override
  Future<void> flush() => _sock.flush();
}

// ----------------------------------------------------------------------
//  Proxy SOCKS5 local (CONNECT uniquement) -> canal SSH direct-tcpip
// ----------------------------------------------------------------------
Future<void> _socks(Socket sock, SSHClient client, _Stats st, _UdpGw? gw) async {
  try {
    sock.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
  final buf = <int>[];
  var stage = 0;
  SSHForwardChannel? ch;
  _UdpAssoc? assoc;
  StreamSubscription<Uint8List>? sub;

  void reply(int code) {
    try {
      sock.add(<int>[5, code, 0, 1, 0, 0, 0, 0, 0, 0]);
    } catch (_) {}
  }

  sub = sock.listen(
    (Uint8List data) async {
      try {
        if (stage == 4) return; // canal de contrôle d'une association UDP
        if (stage == 2) {
          st.up += data.length;
          ch?.sink.add(data);
          return;
        }
        buf.addAll(data);
        if (stage == 0) {
          if (buf.length < 2) return;
          final n = buf[1];
          if (buf.length < 2 + n) return;
          buf.removeRange(0, 2 + n);
          sock.add(<int>[5, 0]);
          stage = 1;
        }
        if (stage == 1) {
          if (buf.length < 5) return;
          final cmd = buf[1];
          final atyp = buf[3];
          int need;
          String host;
          if (atyp == 1) {
            need = 10;
            if (buf.length < need) return;
            host = '${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}';
          } else if (atyp == 3) {
            final l = buf[4];
            need = 5 + l + 2;
            if (buf.length < need) return;
            host = utf8.decode(buf.sublist(5, 5 + l), allowMalformed: true);
          } else if (atyp == 4) {
            need = 22;
            if (buf.length < need) return;
            host = InternetAddress.fromRawAddress(
              Uint8List.fromList(buf.sublist(4, 20)),
            ).address;
          } else {
            reply(8);
            sock.destroy();
            return;
          }
          final port = (buf[need - 2] << 8) | buf[need - 1];
          buf.removeRange(0, need);
          if (cmd == 3) {
            // UDP ASSOCIATE : passe par UDPGW si le serveur l'offre
            if (gw == null) {
              reply(7);
              sock.destroy();
              return;
            }
            stage = 4;
            sub?.pause();
            final okGw = await gw.ensure();
            if (!okGw) {
              reply(1);
              sock.destroy();
              return;
            }
            final u = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
            assoc = gw.newAssoc(u);
            sock.add(<int>[5, 0, 0, 1, 127, 0, 0, 1, (u.port >> 8) & 0xff, u.port & 0xff]);
            sub?.resume();
            return;
          }
          if (cmd != 1) {
            reply(7); // commande non prise en charge
            sock.destroy();
            return;
          }
          stage = 3;
          sub?.pause();
          SSHForwardChannel f;
          try {
            f = await client.forwardLocal(host, port);
          } catch (_) {
            reply(5);
            sock.destroy();
            return;
          }
          ch = f;
          reply(0);
          f.stream.listen(
            (Uint8List d) {
              st.down += d.length;
              try {
                sock.add(d);
              } catch (_) {}
            },
            onDone: () {
              try {
                sock.close();
              } catch (_) {}
            },
            onError: (Object e) {
              try {
                sock.destroy();
              } catch (_) {}
            },
            cancelOnError: true,
          );
          stage = 2;
          if (buf.isNotEmpty) {
            st.up += buf.length;
            f.sink.add(Uint8List.fromList(buf));
            buf.clear();
          }
          sub?.resume();
        }
      } catch (_) {
        try {
          sock.destroy();
        } catch (_) {}
      }
    },
    onDone: () {
      assoc?.close();
      try {
        ch?.sink.close();
      } catch (_) {}
    },
    onError: (Object e) {
      assoc?.close();
      try {
        ch?.destroy();
      } catch (_) {}
    },
    cancelOnError: true,
  );
}

// ----------------------------------------------------------------------
//  UDPGW (badvpn-udpgw, port 7300 du serveur) : UDP à travers le tunnel SSH
//  Trame : [longueur 2 octets LE][flags 1][conid 2 octets LE][IPv4 4][port 2 BE][données]
//  flags : 1 = keepalive, 2 = rebind, 4 = DNS, 8 = IPv6
// ----------------------------------------------------------------------
class _UdpGw {
  final SSHClient client;
  final int port;
  final _Stats st;
  SSHForwardChannel? _ch;
  Future<bool>? _opening;
  Timer? _ka;
  final List<int> _rx = <int>[];
  final Map<int, _UdpAssoc> _byCon = <int, _UdpAssoc>{};
  int _nextCon = 1;

  _UdpGw(this.client, this.port, this.st);

  Future<bool> ensure() {
    if (_ch != null) return Future<bool>.value(true);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<bool> _open() async {
    try {
      final f = await client.forwardLocal('127.0.0.1', port).timeout(const Duration(seconds: 8));
      _ch = f;
      f.stream.listen(
        _onData,
        onDone: _reset,
        onError: (Object _) => _reset(),
        cancelOnError: true,
      );
      _ka?.cancel();
      _ka = Timer.periodic(const Duration(seconds: 15), (_) => _sendRaw(<int>[1, 0, 0]));
      return true;
    } catch (_) {
      _ch = null;
      return false;
    }
  }

  void _reset() {
    _ch = null;
    _ka?.cancel();
    _rx.clear();
  }

  void close() {
    _ka?.cancel();
    for (final a in _byCon.values.toList()) {
      a.close();
    }
    _byCon.clear();
    try {
      _ch?.destroy();
    } catch (_) {}
    _ch = null;
  }

  _UdpAssoc newAssoc(RawDatagramSocket u) => _UdpAssoc(this, u);

  int newCon(_UdpAssoc a) {
    var c = _nextCon;
    _nextCon = (_nextCon + 1) & 0xFFFF;
    if (_nextCon == 0) _nextCon = 1;
    if (c == 0) c = 1;
    _byCon[c] = a;
    return c;
  }

  void drop(_UdpAssoc a) {
    _byCon.removeWhere((_, v) => identical(v, a));
  }

  void _sendRaw(List<int> body) {
    final f = _ch;
    if (f == null) return;
    try {
      final len = body.length;
      f.sink.add(Uint8List.fromList(<int>[len & 0xff, (len >> 8) & 0xff, ...body]));
    } catch (_) {}
  }

  void sendDatagram(int con, List<int> ip4, int dport, List<int> payload) {
    if (payload.length > 65000) return;
    st.up += payload.length;
    _sendRaw(<int>[0, con & 0xff, (con >> 8) & 0xff, ...ip4, (dport >> 8) & 0xff, dport & 0xff, ...payload]);
  }

  void _onData(Uint8List d) {
    _rx.addAll(d);
    while (_rx.length >= 2) {
      final len = _rx[0] | (_rx[1] << 8);
      if (_rx.length < 2 + len) break;
      final fr = _rx.sublist(2, 2 + len);
      _rx.removeRange(0, 2 + len);
      if (fr.length < 3) continue;
      final flags = fr[0];
      if ((flags & 1) != 0) continue; // keepalive
      final con = fr[1] | (fr[2] << 8);
      final isV6 = (flags & 8) != 0;
      final hl = 3 + (isV6 ? 18 : 6);
      if (fr.length < hl) continue;
      if (isV6) continue; // IPv6 non géré
      final ip = fr.sublist(3, 7);
      final p = (fr[7] << 8) | fr[8];
      final data = fr.sublist(hl);
      st.down += data.length;
      _byCon[con]?.deliver(ip, p, data);
    }
  }
}

class _UdpAssoc {
  final _UdpGw gw;
  final RawDatagramSocket sock;
  InternetAddress? _cAddr;
  int _cPort = 0;
  final Map<String, int> _con = <String, int>{};
  bool _closed = false;

  _UdpAssoc(this.gw, this.sock) {
    sock.listen((RawSocketEvent e) {
      if (e != RawSocketEvent.read) return;
      Datagram? d = sock.receive();
      while (d != null) {
        _fromClient(d);
        d = sock.receive();
      }
    });
  }

  void _fromClient(Datagram d) {
    _cAddr = d.address;
    _cPort = d.port;
    final b = d.data;
    if (b.length < 10 || b[2] != 0 || b[3] != 1) return; // pas de fragments, IPv4 seulement
    final ip = b.sublist(4, 8);
    final p = (b[8] << 8) | b[9];
    final key = '${ip.join('.')}:$p';
    var c = _con[key];
    if (c == null) {
      c = gw.newCon(this);
      _con[key] = c;
    }
    gw.sendDatagram(c, ip, p, b.sublist(10));
  }

  void deliver(List<int> ip, int port, List<int> data) {
    if (_closed || _cAddr == null) return;
    try {
      sock.send(<int>[0, 0, 0, 1, ...ip, (port >> 8) & 0xff, port & 0xff, ...data], _cAddr!, _cPort);
    } catch (_) {}
  }

  void close() {
    if (_closed) return;
    _closed = true;
    gw.drop(this);
    try {
      sock.close();
    } catch (_) {}
  }
}
