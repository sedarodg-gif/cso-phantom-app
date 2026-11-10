import 'package:flutter/material.dart';

import 'main.dart';

/// Modèles de départ (à adapter à ton fournisseur).
const kPayloadTemplates = <String, String>{
  'HTTP simple': 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]',
  'WebSocket (101)':
      'GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
  'CONNECT': '[netData][crlf]Host: [host_port][crlf][crlf]',
  'CONNECT + User-Agent': '[netData][crlf]Host: [host][crlf]User-Agent: [ua][crlf][crlf]',
  'WebSocket + coupure': 'GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf][split]',
  'GET puis CONNECT': 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf][split][netData][crlf]Host: [host_port][crlf][crlf]',
  'Vide (aucun payload)': '',
};

const kPayloadTokens = <String>[
  '[crlf]',
  '[cr]',
  '[lf]',
  '[host]',
  '[port]',
  '[host_port]',
  '[protocol]',
  '[ua]',
  '[netData]',
  '[split]',
  '[instant_split]',
  '[delay_split]',
];

/// Montre ce que le payload enverra vraiment, avec des valeurs d'exemple.
String payloadPreview(String tpl, String hostHeader, String host, int port) {
  var t = tpl.replaceAll('\r\n', '\n');
  if (!t.contains('[crlf]') && t.contains('\n')) {
    t = t.replaceAll('\n', '[crlf]');
  } else {
    t = t.replaceAll('\n', '');
  }
  final hh = hostHeader.isEmpty ? 'exemple.com' : hostHeader;
  final h = host.isEmpty ? 'serveur.exemple.com' : host;
  return t.replaceAllMapped(RegExp(r'\[(\w+)\]'), (Match m) {
    switch (m.group(1)!.toLowerCase()) {
      case 'crlf':
        return '⏎\n';
      case 'cr':
        return '⏎';
      case 'lf':
        return '⏎\n';
      case 'lfcr':
        return '⏎\n';
      case 'host':
        return hh;
      case 'port':
        return '$port';
      case 'host_port':
        return '$h:$port';
      case 'ssh':
        return '$h:$port';
      case 'protocol':
        return 'HTTP/1.1';
      case 'netdata':
        return 'CONNECT $h:$port HTTP/1.1';
      case 'ua':
        return 'Mozilla/5.0 (Linux; Android 13) ... Chrome/120.0 Mobile Safari/537.36';
      case 'split':
        return '\n── envoi coupé (pause 0,5 s) ──\n';
      case 'instant_split':
        return '\n── envoi coupé (sans pause) ──\n';
      case 'delay_split':
        return '\n── envoi coupé (pause 1,5 s) ──\n';
      default:
        return m.group(0)!;
    }
  });
}

/// Ouvre l'éditeur de payload ; renvoie le nouveau payload ou null si annulé.
Future<String?> showPayloadEditor(
  BuildContext context, {
  required String initial,
  required String host,
  required String hostHeader,
  required int port,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF10121A),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _PayloadSheet(initial: initial, host: host, hostHeader: hostHeader, port: port),
  );
}

class _PayloadSheet extends StatefulWidget {
  final String initial;
  final String host;
  final String hostHeader;
  final int port;
  const _PayloadSheet({
    required this.initial,
    required this.host,
    required this.hostHeader,
    required this.port,
  });

  @override
  State<_PayloadSheet> createState() => _PayloadSheetState();
}

class _PayloadSheetState extends State<_PayloadSheet> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _insert(String t) {
    final v = _c.value;
    final start = v.selection.isValid ? v.selection.start : v.text.length;
    final end = v.selection.isValid ? v.selection.end : v.text.length;
    final nt = v.text.replaceRange(start, end, t);
    _c.value = TextEditingValue(
      text: nt,
      selection: TextSelection.collapsed(offset: start + t.length),
    );
    setState(() {});
  }

  String? _warning() {
    final t = _c.text.trim();
    if (t.isEmpty) return null;
    if (!t.contains('[crlf][crlf]') && !t.contains('\n\n')) {
      return 'Un payload HTTP se termine normalement par [crlf][crlf] (ligne vide).';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final warn = _warning();
    final prev = _c.text.trim().isEmpty
        ? '(aucun payload : la connexion SSH démarre directement)'
        : payloadPreview(_c.text, widget.hostHeader, widget.host, widget.port);
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Éditeur de payload', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text('Modèles', style: TextStyle(color: kMute, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in kPayloadTemplates.entries)
                  ActionChip(
                    label: Text(e.key, style: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      _c.text = e.value;
                      setState(() {});
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _c,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Payload',
                filled: true,
                fillColor: Colors.white.withAlpha(14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 10),
            const Text('Balises (touche pour insérer)', style: TextStyle(color: kMute, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in kPayloadTokens)
                  ActionChip(
                    label: Text(t, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                    onPressed: () => _insert(t),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('Aperçu : ce qui sera envoyé', style: TextStyle(color: kMute, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(90),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withAlpha(25)),
              ),
              child: SelectableText(prev, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4)),
            ),
            if (warn != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(warn, style: const TextStyle(color: kAmber, fontSize: 12)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _c.text.trim()),
                  child: const Text('Appliquer'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
