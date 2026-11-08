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
  var closing = false;
  final st = _Stats();

  Future<void> shutdown() async {
    if (closing) return;
    closing = true;
    timer?.cancel();
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

    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = srv;
    srv.listen((Socket s) {
      _socks(s, c, st).catchError((Object _) {});
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
Future<void> _socks(Socket sock, SSHClient client, _Stats st) async {
  try {
    sock.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
  final buf = <int>[];
  var stage = 0;
  SSHForwardChannel? ch;
  StreamSubscription<Uint8List>? sub;

  void reply(int code) {
    try {
      sock.add(<int>[5, code, 0, 1, 0, 0, 0, 0, 0, 0]);
    } catch (_) {}
  }

  sub = sock.listen(
    (Uint8List data) async {
      try {
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
          if (cmd != 1) {
            reply(7); // seule la commande CONNECT est prise en charge
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
      try {
        ch?.sink.close();
      } catch (_) {}
    },
    onError: (Object e) {
      try {
        ch?.destroy();
      } catch (_) {}
    },
    cancelOnError: true,
  );
}
