import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'main.dart';
import 'server.dart';
import 'settings_page.dart';

/// Écran « Exporter la configuration » : nom, messages, appareils autorisés,
/// verrouillage, date d'expiration, puis lien à copier / partager / enregistrer.
class ExportPage extends StatefulWidget {
  final List<Server> list;
  final Future<void> Function(String text) onCopy;
  final Future<void> Function(String text) onShare;
  final Future<void> Function(String text) onSaveFile;
  const ExportPage({
    super.key,
    required this.list,
    required this.onCopy,
    required this.onShare,
    required this.onSaveFile,
  });

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  final _name = TextEditingController();
  final _msg = TextEditingController();
  final _connMsg = TextEditingController();
  final _hwids = TextEditingController();
  bool _lock = false;
  bool _lockSsh = false;
  DateTime? _expiry;
  String _link = '';
  String _err = '';

  bool get _single => widget.list.length == 1;

  @override
  void initState() {
    super.initState();
    if (_single) _name.text = widget.list.first.name;
  }

  @override
  void dispose() {
    _name.dispose();
    _msg.dispose();
    _connMsg.dispose();
    _hwids.dispose();
    super.dispose();
  }

  String _dateLabel(DateTime d) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.day)}/${p(d.month)}/${d.year}';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _expiry ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 3650)),
      helpText: "Date d'expiration",
    );
    if (d != null) setState(() => _expiry = d);
  }

  Future<void> _myId() async {
    String id = '';
    try {
      id = (await const MethodChannel('cso/share').invokeMethod<String>('deviceId')) ?? '';
    } catch (_) {}
    if (id.isEmpty) {
      setState(() => _err = "Impossible de lire l'identifiant de cet appareil");
      return;
    }
    final cur = _hwids.text.trim();
    if (cur.toLowerCase().contains(id.toLowerCase())) return;
    setState(() {
      _err = '';
      _hwids.text = cur.isEmpty ? id : '$cur\n$id';
    });
  }

  void _showQr() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        content: SizedBox(
          width: 260,
          height: 260,
          child: QrImageView(
            data: _link,
            version: QrVersions.auto,
            backgroundColor: Colors.white,
            errorCorrectionLevel: QrErrorCorrectLevel.L,
            errorStateBuilder: (c, e) => const Center(
              child: Text(
                'Trop de données pour un QR code : exporte un seul serveur.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black),
              ),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer'))],
      ),
    );
  }

  void _export() {
    final end = _expiry == null
        ? 0
        : DateTime(_expiry!.year, _expiry!.month, _expiry!.day, 23, 59, 59).millisecondsSinceEpoch;
    setState(() {
      _err = '';
      _link = exportBundle(
        widget.list,
        lock: _lock,
        lockSsh: _lockSsh,
        expires: end,
        name: _name.text.trim(),
        msg: _msg.text.trim(),
        connMsg: _connMsg.text.trim(),
        hwids: _hwids.text.trim(),
      );
    });
  }

  InputDecoration _dec(String label, [String hint = '']) => InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: Colors.white.withAlpha(14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withAlpha(40)),
        ),
      );

  Widget _field(TextEditingController c, String label, {String hint = '', int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        autocorrect: false,
        enableSuggestions: false,
        minLines: lines,
        maxLines: lines == 1 ? 1 : lines + 2,
        decoration: _dec(label, hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSsh = widget.list.any((s) => s.type == 'ssh');
    return CsoPage(
      title: 'Exporter la configuration',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
            decoration: glass(r: 20),
            child: Column(
              children: [
                if (_single) _field(_name, 'Nom'),
                _field(_msg, 'Message', hint: "Affiché au destinataire quand il importe la configuration", lines: 2),
                _field(_connMsg, 'Message de connexion', hint: 'Affiché quand le VPN se connecte', lines: 2),
                _field(_hwids, 'Liste de Hardware ID',
                    hint: 'Un identifiant par ligne. Vide = tous les appareils', lines: 2),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _myId,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Ajouter mon ID'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          sSwitch('Verrouiller', 'Le destinataire se connecte mais ne voit ni les réglages ni les identifiants.',
              _lock, (v) => setState(() => _lock = v),
              icon: Icons.lock_outline),
          sSwitch(
              'Verrouiller le compte SSH',
              hasSsh
                  ? "Masque l'utilisateur et le mot de passe SSH."
                  : "Sans effet : aucune configuration SSH dans cet export.",
              _lockSsh,
              (v) => setState(() => _lockSsh = v),
              icon: Icons.vpn_key_outlined),
          sTile(
            icon: Icons.event_outlined,
            title: _expiry == null ? "Date d'expiration non définie" : "Expire le ${_dateLabel(_expiry!)}",
            sub: _expiry == null ? 'Touche pour choisir une date' : "Fin de journée, heure de l'appareil",
            trailing: _expiry == null
                ? const Icon(Icons.calendar_month_outlined, color: kMute)
                : IconButton(
                    tooltip: 'Retirer la date',
                    icon: const Icon(Icons.close, color: kMute),
                    onPressed: () => setState(() => _expiry = null),
                  ),
            onTap: _pickDate,
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _export,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('EXPORTER', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            ),
          ),
          if (_err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_err, style: const TextStyle(color: kBad)),
            ),
          if (_link.isNotEmpty) ...[
            sTitle('Message de config'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: glass(r: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 130),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _link,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.35),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => widget.onCopy(_link),
                        child: const Text('Copier'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => widget.onSaveFile(_link),
                        child: const Text('Fichier'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _showQr,
                        child: const Text('QR'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => widget.onShare(_link),
                        child: const FittedBox(fit: BoxFit.scaleDown, child: Text('Partager')),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              "Le lien contient les identifiants : ne le donne qu'aux personnes de confiance. "
              'Le verrouillage, la date et la liste d\'appareils sont contrôlés par l\'application : '
              "ils découragent le partage mais ne sont pas un chiffrement.",
              style: TextStyle(fontSize: 12, color: kMute, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}
