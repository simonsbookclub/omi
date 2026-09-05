import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';

import 'package:omi/providers/us_provider.dart';

/// SIMONSBOOKCLUB ("Us"): a protocol to do, with a timer. Logs
/// accepted → completed so the app learns which protocols actually work.
class ProtocolPage extends StatefulWidget {
  final Map<String, dynamic> protocol;
  final String trigger;
  final String? conversationId;

  const ProtocolPage({super.key, required this.protocol, this.trigger = 'morning', this.conversationId});

  @override
  State<ProtocolPage> createState() => _ProtocolPageState();
}

class _ProtocolPageState extends State<ProtocolPage> {
  Timer? _timer;
  int _remaining = 0;
  bool _running = false;
  bool _done = false;

  int get _minutes => (widget.protocol['minutes'] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    _remaining = _minutes * 60;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<UsProvider>().protocolEvent(widget.protocol['id'].toString(), 'accept', trigger: widget.trigger, conversationId: widget.conversationId);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    setState(() => _running = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        setState(() { _remaining = 0; _running = false; });
      } else {
        setState(() => _remaining--);
      }
    });
  }

  Future<void> _complete() async {
    _timer?.cancel();
    await context.read<UsProvider>().protocolEvent(widget.protocol['id'].toString(), 'complete', trigger: widget.trigger, conversationId: widget.conversationId);
    if (mounted) setState(() { _done = true; _running = false; });
  }

  @override
  Widget build(BuildContext context) {
    final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
    final ss = (_remaining % 60).toString().padLeft(2, '0');
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text(widget.protocol['title'].toString())),
      body: Column(
        children: [
          Expanded(
            child: Markdown(
              data: widget.protocol['body_md'].toString(),
              padding: const EdgeInsets.all(20),
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(color: Colors.white, fontSize: 17, height: 1.5),
                listBullet: const TextStyle(color: Colors.white, fontSize: 17),
                blockquote: const TextStyle(color: Color(0xFFD4A64F), fontSize: 18, fontStyle: FontStyle.italic),
                blockquoteDecoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(10)),
                strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            decoration: const BoxDecoration(color: Color(0xFF141418), borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            child: Column(
              children: [
                if (_minutes > 0)
                  Text('$mm:$ss', style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w300, fontFeatures: [FontFeature.tabularFigures()])),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_minutes > 0 && !_done)
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(vertical: 14)),
                          onPressed: _running ? () { _timer?.cancel(); setState(() => _running = false); } : _start,
                          child: Text(_running ? 'Pause' : (_remaining == _minutes * 60 ? 'Start timer' : 'Resume')),
                        ),
                      ),
                    if (_minutes > 0 && !_done) const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: _done ? const Color(0xFF2A7A72) : const Color(0xFF6FC3B8), foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14)),
                        onPressed: _done ? () => Navigator.of(context).pop() : _complete,
                        child: Text(_done ? 'Done — close' : 'We did it'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
