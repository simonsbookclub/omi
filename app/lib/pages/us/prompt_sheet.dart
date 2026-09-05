import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/us/protocol_page.dart';
import 'package:omi/providers/us_provider.dart';

/// SIMONSBOOKCLUB ("Us"): the two questions the model learns from, asked
/// thirty minutes after a hard conversation — and the in-the-moment offer.
Future<void> showUsPromptSheet(BuildContext context, Map<String, dynamic> prompt) async {
  final kind = (prompt['kind'] ?? '').toString();
  final payload = (prompt['payload'] is Map<String, dynamic>) ? prompt['payload'] as Map<String, dynamic> : prompt;
  final id = prompt['id'] is int ? prompt['id'] as int : int.tryParse('${prompt['id']}');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1F1F25),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => kind == 'in_moment' ? _InMomentSheet(id: id, payload: payload) : _PostConflictSheet(id: id, payload: payload),
  );
}

class _PostConflictSheet extends StatefulWidget {
  final int? id;
  final Map<String, dynamic> payload;
  const _PostConflictSheet({required this.id, required this.payload});

  @override
  State<_PostConflictSheet> createState() => _PostConflictSheetState();
}

class _PostConflictSheetState extends State<_PostConflictSheet> {
  bool? _conflict;
  bool? _resolved;
  bool _saving = false;

  Future<void> _save() async {
    final conv = widget.payload['conversation_id']?.toString();
    if (_conflict == null || conv == null) return;
    setState(() => _saving = true);
    final us = context.read<UsProvider>();
    if (widget.id != null) {
      await us.answerPostConflict(widget.id!, conv, wasConflict: _conflict!, resolved: _resolved);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    final protocol = widget.payload['protocol'];
    if (_conflict == true && _resolved != true && protocol is Map<String, dynamic>) {
      final full = us.protocols.where((p) => p['id'] == protocol['id']).firstOrNull ?? protocol;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProtocolPage(protocol: full, trigger: 'post_conflict', conversationId: conv)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.payload['title']?.toString();
    final summary = widget.payload['summary']?.toString();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A moment ago', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
            const SizedBox(height: 6),
            Text(title ?? 'Your conversation', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
            if (summary != null && summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(summary, style: const TextStyle(color: Colors.white70, height: 1.4))),
            const SizedBox(height: 20),
            const Text('Was that a conflict?', style: TextStyle(color: Colors.white, fontSize: 17)),
            const SizedBox(height: 8),
            Row(children: [
              _choice('Yes', _conflict == true, () => setState(() => _conflict = true)),
              const SizedBox(width: 8),
              _choice('No', _conflict == false, () => setState(() { _conflict = false; _resolved = null; })),
            ]),
            if (_conflict == true) ...[
              const SizedBox(height: 16),
              const Text('Did it resolve?', style: TextStyle(color: Colors.white, fontSize: 17)),
              const SizedBox(height: 8),
              Row(children: [
                _choice('Yes', _resolved == true, () => setState(() => _resolved = true)),
                const SizedBox(width: 8),
                _choice('Not yet', _resolved == false, () => setState(() => _resolved = false)),
              ]),
            ],
            const SizedBox(height: 20),
            Row(children: [
              TextButton(
                onPressed: _saving ? null : () async { if (widget.id != null) await context.read<UsProvider>().dismissPrompt(widget.id!); if (context.mounted) Navigator.of(context).pop(); },
                child: const Text('Skip', style: TextStyle(color: Colors.white54)),
              ),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6FC3B8), foregroundColor: Colors.black),
                onPressed: _saving || _conflict == null || (_conflict == true && _resolved == null) ? null : _save,
                child: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _choice(String label, bool selected, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF6FC3B8) : const Color(0xFF2A2A30),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: Text(label, style: TextStyle(color: selected ? Colors.black : Colors.white, fontWeight: FontWeight.w600))),
          ),
        ),
      );
}

class _InMomentSheet extends StatelessWidget {
  final int? id;
  final Map<String, dynamic> payload;
  const _InMomentSheet({required this.id, required this.payload});

  @override
  Widget build(BuildContext context) {
    final protocol = payload['protocol'];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(payload['text']?.toString() ?? 'Things are heating up.', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600, height: 1.3)),
            const SizedBox(height: 20),
            Row(children: [
              TextButton(
                onPressed: () async { if (id != null) await context.read<UsProvider>().dismissPrompt(id!); if (context.mounted) Navigator.of(context).pop(); },
                child: const Text('Not now', style: TextStyle(color: Colors.white54)),
              ),
              const Spacer(),
              if (protocol is Map<String, dynamic>)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6FC3B8), foregroundColor: Colors.black),
                  onPressed: () async {
                    final us = context.read<UsProvider>();
                    if (id != null) await us.dismissPrompt(id!);
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    final full = us.protocols.where((p) => p['id'] == protocol['id']).firstOrNull ?? protocol;
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProtocolPage(protocol: full, trigger: 'in_moment', conversationId: payload['conversation_id']?.toString())));
                  },
                  child: Text('Start ${protocol['title']}'),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}
