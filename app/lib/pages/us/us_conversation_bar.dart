import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/us.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/providers/us_provider.dart';

/// SIMONSBOOKCLUB ("Us"): the two toggles on a conversation — was this the
/// two of you, and was it a hard one. Overrides feed the analysis; labels
/// teach the model.
class UsConversationBar extends StatefulWidget {
  final ServerConversation conversation;
  const UsConversationBar({super.key, required this.conversation});

  @override
  State<UsConversationBar> createState() => _UsConversationBarState();
}

class _UsConversationBarState extends State<UsConversationBar> {
  late String? _scope;
  late String? _override;
  late bool? _hard;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final us = widget.conversation.us;
    _scope = us?.scope;
    _override = us?.override;
    _hard = us?.hard;
  }

  bool get _isUs => _override == 'us' || (_override == null && (_scope == 'us' || _scope == 'us_others'));

  Future<void> _toggleUs() async {
    setState(() => _busy = true);
    final next = _isUs ? 'not_us' : 'us';
    final r = await UsApi.setScope(widget.conversation.id, next);
    if (mounted) {
      setState(() {
        _override = next;
        _scope = r?['scope']?.toString() ?? _scope;
        _busy = false;
      });
      context.read<UsProvider>().refresh(force: true);
    }
  }

  Future<void> _toggleHard() async {
    setState(() => _busy = true);
    final next = _hard == true ? false : true;
    await UsApi.setHard(widget.conversation.id, next);
    if (mounted) {
      setState(() { _hard = next; _busy = false; });
      context.read<UsProvider>().refresh(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final us = context.watch<UsProvider>();
    if (!us.isLive && widget.conversation.us?.coupleId == null) return const SizedBox.shrink();
    final analysis = widget.conversation.us?.analysis;
    final tension = (analysis?['tension'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          _chip(
            label: _isUs ? 'This was us' : 'Not us',
            selected: _isUs,
            color: const Color(0xFFD4A64F),
            onTap: _busy ? null : _toggleUs,
          ),
          const SizedBox(width: 8),
          if (_isUs)
            _chip(
              label: _hard == true ? 'Hard conversation' : 'Mark as hard',
              selected: _hard == true,
              color: const Color(0xFFE5785C),
              onTap: _busy ? null : _toggleHard,
            ),
          const Spacer(),
          if (_isUs && tension != null)
            Text('tension ${(tension * 100).round()}%', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _chip({required String label, required bool selected, required Color color, required VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.25) : const Color(0xFF2A2A30),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? color : Colors.transparent),
          ),
          child: Text(label, style: TextStyle(color: selected ? color : Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      );
}
