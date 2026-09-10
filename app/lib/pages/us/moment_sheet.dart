import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/pages/us/us_theme.dart';
import 'package:omi/providers/us_provider.dart';

/// SIMONSBOOKCLUB ("Us"): marking a moment.
///
/// A ring measures the body and nothing else. Sex, an argument, a night out —
/// these only exist in the data if one of you says so. Oura's own tags arrive
/// on their own (src/us-oura.ts reads enhanced_tag); this is the same thing
/// without leaving the app, and it works for the partner who has no ring.
const _labels = <String, String>{
  'sex': 'Sex',
  'together': 'Time together',
  'date': 'Date',
  'argument': 'Argument',
  'walk': 'Walk',
  'meditation': 'Meditation',
  'alcohol': 'Alcohol',
  'late_meal': 'Late meal',
  'nap': 'Nap',
  'sauna': 'Sauna',
  'travel': 'Travel',
  'sick': 'Unwell',
  'caffeine': 'Caffeine',
  'stress': 'Stressful day',
};

String momentLabel(String kind) =>
    _labels[kind] ??
    kind.replaceAll('_', ' ').replaceFirstMapped(RegExp(r'^.'), (m) => m.group(0)!.toUpperCase());

Future<void> showMomentSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _MomentSheet(),
    );

class _MomentSheet extends StatefulWidget {
  const _MomentSheet();

  @override
  State<_MomentSheet> createState() => _MomentSheetState();
}

class _MomentSheetState extends State<_MomentSheet> {
  String? _kind;
  bool _shared = true;
  DateTime _at = DateTime.now();
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final us = context.watch<UsProvider>();
    final kinds = us.momentKinds;
    final whose = us.isActingAsPartner ? us.ownerName : us.ownerName;
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: UsInk.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          border: Border(top: BorderSide(color: UsInk.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: const Color(0x2EFFFFFF), borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const Text('Mark a moment',
              style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
          const SizedBox(height: 4),
          const Text('A ring can measure your body. It cannot know what you were doing.',
              style: TextStyle(color: UsInk.label, fontSize: 13, height: 1.45)),
          const SizedBox(height: 18),
          // Whose moment this is follows the person switch at the top of the
          // tab, the same rule the period log uses. Saying so beats a second
          // control that can disagree with the first.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: UsInk.raised, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              UsAvatar(whose, mine: !us.isActingAsPartner, size: 22),
              const SizedBox(width: 9),
              Expanded(
                child: Text('Logs under $whose',
                    style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
              if (us.partnerOnThisPhone)
                const Text('switch at the top', style: TextStyle(color: UsInk.faint, fontSize: 11.5)),
            ]),
          ),
          const SizedBox(height: 20),
          const UsLabel('What happened'),
          const SizedBox(height: 11),
          Wrap(spacing: 9, runSpacing: 9, children: [
            for (final k in kinds) _chip(k, momentLabel(k)),
          ]),
          const SizedBox(height: 20),
          const UsLabel('When'),
          const SizedBox(height: 11),
          Row(children: [
            _when('Now', _at.difference(DateTime.now()).abs().inMinutes < 2, () => setState(() => _at = DateTime.now())),
            const SizedBox(width: 9),
            _when('An hour ago', _at.difference(DateTime.now().subtract(const Duration(hours: 1))).abs().inMinutes < 2,
                () => setState(() => _at = DateTime.now().subtract(const Duration(hours: 1)))),
            const SizedBox(width: 9),
            _when('Pick a time', false, _pickTime),
          ]),
          const SizedBox(height: 20),
          InkWell(
            onTap: () => setState(() => _shared = !_shared),
            borderRadius: BorderRadius.circular(13),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
              decoration: BoxDecoration(color: UsInk.raised, borderRadius: BorderRadius.circular(13)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${us.partnerName} can see this',
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    const Text('Turn it off and the moment stays yours alone.',
                        style: TextStyle(color: UsInk.faint, fontSize: 11.5)),
                  ]),
                ),
                Switch(
                  value: _shared,
                  activeColor: UsInk.you,
                  onChanged: (v) => setState(() => _shared = v),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                disabledBackgroundColor: const Color(0x1FFFFFFF),
                disabledForegroundColor: UsInk.faint,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _kind == null || _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save moment',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text('Tags you set in the Oura app arrive here on their own.',
                style: TextStyle(color: Color(0x47FFFFFF), fontSize: 11.5)),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String kind, String label) {
    final on = _kind == kind;
    return InkWell(
      onTap: () => setState(() => _kind = kind),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: on ? UsInk.you.withValues(alpha: 0.16) : UsInk.raised,
          borderRadius: BorderRadius.circular(14),
          border: on ? Border.all(color: UsInk.you.withValues(alpha: 0.45)) : null,
        ),
        child: Text(label,
            style: TextStyle(
              color: on ? UsInk.you : Colors.white,
              fontSize: 14,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            )),
      ),
    );
  }

  Widget _when(String label, bool on, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: on ? Colors.white : UsInk.raised,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(label,
                style: TextStyle(
                  color: on ? Colors.black : const Color(0xBFFFFFFF),
                  fontSize: 13.5,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                )),
          ),
        ),
      );

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (picked == null || !mounted) return;
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
    // A time later than now means yesterday, not the future.
    if (at.isAfter(now)) at = at.subtract(const Duration(days: 1));
    setState(() => _at = at);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final us = context.read<UsProvider>();
    final err = await us.logMoment(_kind!, at: _at, shared: _shared);
    if (!mounted) return;
    if (err != null) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    Navigator.of(context).pop();
  }
}
