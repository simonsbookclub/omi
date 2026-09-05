import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:omi/pages/us/prompt_sheet.dart';
import 'package:omi/pages/us/protocol_page.dart';
import 'package:omi/pages/us/us_account_page.dart';
import 'package:omi/pages/us/voice_enroll_page.dart';
import 'package:omi/backend/http/api/us.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:omi/providers/us_provider.dart';
import 'package:omi/services/us_visits.dart';
import 'package:omi/widgets/dialog.dart';

/// SIMONSBOOKCLUB ("Us"): the tab. Today's risk with reasons for both of
/// you, the base rate beside it, tonight's protocol, the conversations
/// that were us, and the week. See docs/plans/PLAN-chronicle-couple.md.
class UsPage extends StatefulWidget {
  const UsPage({super.key});

  @override
  State<UsPage> createState() => _UsPageState();
}

class _UsPageState extends State<UsPage> with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final GlobalKey _weeklyKey = GlobalKey();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final us = context.read<UsProvider>();
      us.refresh(force: true);
      us.addListener(_maybeShowIncoming);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) context.read<UsProvider>().refresh();
  }

  void _maybeShowIncoming() {
    final us = context.read<UsProvider>();
    final p = us.incomingPrompt;
    if (p == null || !mounted) return;
    us.consumeIncomingPrompt();
    // The socket frame carries the payload flat; the sheet accepts both.
    showUsPromptSheet(context, {'kind': p['kind'], 'payload': p, 'id': null});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final us = context.watch<UsProvider>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: RefreshIndicator(
          color: Colors.white,
          backgroundColor: const Color(0xFF1F1F25),
          onRefresh: () => us.refresh(force: true, card: true),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              Row(
                children: [
                  const Text('Us', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (us.isLive && us.partnerOnThisPhone) _personSwitch(us),
                  IconButton(
                    icon: const FaIcon(FontAwesomeIcons.circleUser, color: Colors.white70, size: 22),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UsAccountPage())),
                  ),
                ],
              ),
              if (us.isActingAsPartner) _notice('Acting as ${us.ownerName}. Everything below is theirs: period log, sharing, prompts, voice, ring.'),
              if (us.error != null) _errorBox(us.error!),
              if (us.today == null && us.loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: Colors.white54))),
              if (us.today != null) ...[
                if (!us.isLive) _coupleSetup(us) else ..._live(us),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Couple setup

  Widget _coupleSetup(UsProvider us) {
    final couple = us.couple ?? {};
    final state = couple['state']?.toString() ?? 'none';
    final invite = couple['invite'] as Map<String, dynamic>?;
    if (state == 'paused') {
      return _card(children: [
        const Text('Paused', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('${couple['partner']?['name'] ?? 'Your partner'} and you paused Us. Nothing is analyzed while paused.', style: const TextStyle(color: Colors.white70, height: 1.4)),
        const SizedBox(height: 12),
        Row(children: [
          ElevatedButton(onPressed: () => us.setPaused(false), style: _primary, child: const Text('Resume')),
          const SizedBox(width: 12),
          TextButton(onPressed: () => _confirmEnd(us), child: const Text('End', style: TextStyle(color: Color(0xFFE5785C)))),
        ]),
      ]);
    }
    if (state == 'pending' && us.pendingPartnerConsent) {
      final partnerName = couple['partner']?['name'] ?? 'your partner';
      return _card(children: [
        Text('Hand the phone to $partnerName', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Text(
          '$partnerName, this app listens through ${couple['me']?['name'] ?? 'your partner'}\'s pendant. If you agree, conversations where both of you are present will be scored for tension and repair, and each morning you both get one number with reasons. Your own body data and cycle are yours to share or not. You can pause or end this at any time from this screen.',
          style: const TextStyle(color: Colors.white70, height: 1.45),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: ElevatedButton(
              style: _primary,
              onPressed: () async {
                final err = await us.partnerConsent();
                if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
              },
              child: Text('I agree — I\'m $partnerName'),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: () => _confirmEnd(us), child: const Text('Not now', style: TextStyle(color: Colors.white54))),
        ]),
      ]);
    }
    return Column(children: [
      _card(children: [
        const Text('Two of you, one phone', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(
          'Only one of you wears the pendant, so your partner lives inside this app: add them by name, hand them the phone once to say yes, and switch between you at the top of this tab.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: const InputDecoration(hintText: 'Partner\'s first name', hintStyle: TextStyle(color: Colors.white24), filled: true, fillColor: Color(0xFF2A2A30), border: OutlineInputBorder(borderSide: BorderSide.none)),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            style: _primary,
            onPressed: () async {
              final name = _nameController.text.trim();
              if (name.isEmpty) return;
              final err = await us.addPartner(name);
              if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
            },
            child: const Text('Add'),
          ),
        ]),
      ]),
      const SizedBox(height: 12),
      _card(children: [
        const Text('Or a second phone', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
        const SizedBox(height: 6),
        const Text('If your partner installs Chronicle themselves, send a code instead.', style: TextStyle(color: Colors.white54, fontSize: 13)),
        const SizedBox(height: 12),
        if (invite != null) ...[
          const Text('Your code', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          Row(children: [
            SelectableText(invite['code'].toString(), style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 4)),
            const Spacer(),
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.share, color: Colors.white70, size: 18),
              onPressed: () => Share.share('Join me on Chronicle · Us. Code: ${invite['code']}'),
            ),
          ]),
          const Text('Valid for three days. Sending it is your consent.', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ] else
          ElevatedButton(
            style: _primary,
            onPressed: () async {
              final err = await us.createInvite();
              if (err != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
            },
            child: const Text('Create a code'),
          ),
      ]),
      const SizedBox(height: 12),
      _card(children: [
        const Text('Have a code?', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Colors.white, letterSpacing: 3, fontSize: 18),
              decoration: const InputDecoration(hintText: 'ABCD2345', hintStyle: TextStyle(color: Colors.white24), filled: true, fillColor: Color(0xFF2A2A30), border: OutlineInputBorder(borderSide: BorderSide.none)),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            style: _primary,
            onPressed: () async {
              final err = await us.acceptInvite(_codeController.text.trim());
              if (!mounted) return;
              if (err != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
            },
            child: const Text('Join'),
          ),
        ]),
        const SizedBox(height: 8),
        const Text('Entering it is your consent. Either of you can pause or end this at any time.', style: TextStyle(color: Colors.white38, fontSize: 12)),
      ]),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Live

  List<Widget> _live(UsProvider us) {
    final card = us.card;
    final couple = us.couple ?? {};
    final me = couple['me'] as Map<String, dynamic>? ?? {};
    final partner = couple['partner'] as Map<String, dynamic>? ?? {};
    final myVoice = me['voice'];
    return [
      if (myVoice == null) _notice('Your voice is not chosen yet. Open Account → "This voice is me" so the app knows which speaker is you.'),
      if (partner['voice'] == null) _notice('${partner['name']} has not chosen a voice yet. Until then no conversation can be "us".'),
      for (final p in us.prompts) _promptRow(us, p),
      if (us.isActingAsPartner) _partnerSetup(us, me),
      _todayCard(us, card, me, partner),
      const SizedBox(height: 12),
      _quickActions(us, me),
      const SizedBox(height: 12),
      _bodyCard(us),
      const SizedBox(height: 12),
      _weekStrip(us),
      const SizedBox(height: 12),
      _trend(us),
      const SizedBox(height: 12),
      _conversations(us),
      const SizedBox(height: 12),
      _weeklyReport(us),
      const SizedBox(height: 12),
      _sharing(us, couple),
      const SizedBox(height: 24),
      Center(child: Text('Since ${(couple['since'] ?? '').toString().substring(0, 10)} · ${me['name']} & ${partner['name']}', style: const TextStyle(color: Colors.white24, fontSize: 12))),
    ];
  }

  Widget _personSwitch(UsProvider us) {
    // Names as the owner sees them: me = owner, partner = partner, whatever
    // the current act-as is.
    final ownerLabel = us.isActingAsPartner ? us.partnerName : us.ownerName;
    final partnerLabel = us.isActingAsPartner ? us.ownerName : us.partnerName;
    final pid = us.partnerId;
    Widget seg(String label, bool selected, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: selected ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(999)),
            child: Text(label, style: TextStyle(color: selected ? Colors.black : Colors.white70, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(color: const Color(0xFF2A2A30), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(ownerLabel, !us.isActingAsPartner, () => us.actAs(null)),
        seg(partnerLabel, us.isActingAsPartner, () { if (pid != null) us.actAs(pid); }),
      ]),
    );
  }

  Widget _partnerSetup(UsProvider us, Map<String, dynamic> me) {
    final voice = me['voice'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _card(children: [
        Text('${us.ownerName}\'s setup', style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
        const SizedBox(height: 6),
        Row(children: [
          const Text('Voice', style: TextStyle(color: Colors.white54)),
          const Spacer(),
          Text(voice?.toString() ?? 'not set', style: const TextStyle(color: Colors.white)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VoiceEnrollPage()));
              if (mounted) us.refresh(force: true);
            },
            icon: const FaIcon(FontAwesomeIcons.microphone, size: 14),
            label: const Text('Record voice'),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
            onPressed: () => _pickKnownVoice(us),
            icon: const FaIcon(FontAwesomeIcons.userCheck, size: 14),
            label: const Text('Pick a known voice'),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24)),
            onPressed: () async {
              final r = await UsApi.ouraLinkUrl();
              final url = r?['url'];
              if (url is String) {
                await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              } else if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text((r?['error'] ?? 'Oura is not configured yet.').toString())));
              }
            },
            icon: const FaIcon(FontAwesomeIcons.ring, size: 14),
            label: const Text('Link Oura'),
          ),
        ]),
      ]),
    );
  }

  Future<void> _pickKnownVoice(UsProvider us) async {
    final r = await UsApi.voices();
    final voices = ((r?['voices'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1F1F25),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Which voice?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600))),
          for (final v in voices)
            ListTile(
              title: Text(v['person_name'].toString(), style: const TextStyle(color: Colors.white)),
              subtitle: Text('${v['sample_count']} samples${v['user_id'] != null ? ' · linked' : ''}', style: const TextStyle(color: Colors.white54)),
              onTap: () => Navigator.of(ctx).pop(v['person_name'].toString()),
            ),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (chosen == null) return;
    final res = await UsApi.claimVoice(chosen);
    if (!mounted) return;
    if (res?['error'] != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res!['error'].toString())));
    } else {
      us.refresh(force: true);
    }
  }

  Widget _todayCard(UsProvider us, Map<String, dynamic>? card, Map<String, dynamic> me, Map<String, dynamic> partner) {
    if (card == null) {
      return _card(children: const [
        Text('Today', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
        SizedBox(height: 6),
        Text('No card yet. Pull to refresh once there is body data for today.', style: TextStyle(color: Colors.white70)),
      ]);
    }
    final level = (card['level'] ?? 'unknown').toString();
    final factors = ((card['factors'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final active = factors.where((f) => f['active'] == true).toList();
    final inactive = factors.where((f) => f['active'] != true).toList();
    final base = card['base'] as Map<String, dynamic>? ?? {};
    final protocol = card['protocol'] as Map<String, dynamic>?;
    final learning = (card['factors_still_learning'] as num?)?.toInt() ?? 0;
    final hidden = (card['hidden_by_partner'] as num?)?.toInt() ?? 0;
    final likeDays = (base['like_days'] as num?)?.toInt() ?? 0;
    final likeHard = (base['like_hard'] as num?)?.toInt() ?? 0;
    final baseDays = (base['days'] as num?)?.toInt() ?? 0;
    final rate = (base['rate'] as num?)?.toDouble();
    final levelColor = level == 'high' ? const Color(0xFFE5785C) : level == 'elevated' ? const Color(0xFFD4A64F) : level == 'calm' ? const Color(0xFF6FC3B8) : Colors.white38;
    final levelText = level == 'high' ? 'High' : level == 'elevated' ? 'Elevated' : level == 'calm' ? 'Calm' : 'Not enough data';
    return _card(children: [
      Row(children: [
        const Text('Today', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
        const Spacer(),
        Text(card['day']?.toString() ?? '', style: const TextStyle(color: Colors.white24, fontSize: 12)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: levelColor, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(levelText, style: TextStyle(color: levelColor, fontSize: 22, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 12),
      if (active.isEmpty && level != 'unknown') const Text('Nothing pulling on either of you today.', style: TextStyle(color: Colors.white70)),
      for (final f in active) _factorRow(f, active: true),
      if (inactive.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final f in inactive) _factorRow(f, active: false),
      ],
      if (learning > 0 || hidden > 0) ...[
        const SizedBox(height: 8),
        Text(
          [
            if (learning > 0) '$learning factor${learning == 1 ? '' : 's'} still learning (needs eight days each)',
            if (hidden > 0) '$hidden of ${partner['name']}\'s factors kept private',
          ].join(' · '),
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
      const Divider(color: Colors.white12, height: 24),
      Text(
        baseDays == 0
            ? 'No history yet. The base rate appears after the first days together.'
            : likeDays > 0
                ? 'On $likeHard of $likeDays days like this, there was a hard conversation. Your average is ${(rate! * likeDays).round()} in $likeDays.'
                : 'Average over $baseDays days: ${rate == null ? '—' : '${(rate * 100).round()}%'} of days had a hard conversation.',
        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
      ),
      if (card['note'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(card['note'].toString(), style: const TextStyle(color: Colors.white38, fontSize: 12))),
      if (protocol != null) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF1F3A37), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('TONIGHT\'S PROTOCOL', style: TextStyle(color: Color(0xFF6FC3B8), fontSize: 11, letterSpacing: 1.2)),
            const SizedBox(height: 4),
            Text('${protocol['title']}${protocol['minutes'] != null ? ' · ${protocol['minutes']} min' : ''}${protocol['time'] != null ? ' · ${protocol['time']}' : ''}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6FC3B8), foregroundColor: Colors.black),
                  onPressed: () {
                    final full = us.protocols.where((p) => p['id'] == protocol['id']).firstOrNull ?? protocol;
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProtocolPage(protocol: full, trigger: (protocol['trigger'] ?? 'morning').toString())));
                  },
                  child: const Text('Start'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24)),
                  onPressed: () => us.protocolEvent(protocol['id'].toString(), 'decline', trigger: (protocol['trigger'] ?? 'morning').toString()),
                  child: const Text('Not today'),
                ),
              ),
            ]),
          ]),
        ),
      ],
    ]);
  }

  Widget _factorRow(Map<String, dynamic> f, {required bool active}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 64, child: Text(f['who'].toString(), style: TextStyle(color: active ? Colors.white : Colors.white38, fontWeight: FontWeight.w600))),
          Expanded(child: Text(f['text'].toString(), style: TextStyle(color: active ? Colors.white : Colors.white38, decoration: active ? null : TextDecoration.lineThrough, decorationColor: Colors.white24))),
        ]),
      );

  Widget _promptRow(UsProvider us, Map<String, dynamic> p) {
    final kind = p['kind'].toString();
    final payload = p['payload'] as Map<String, dynamic>? ?? {};
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => showUsPromptSheet(context, p),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF3A3122), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFD4A64F))),
          child: Row(children: [
            const FaIcon(FontAwesomeIcons.solidCircleQuestion, color: Color(0xFFD4A64F), size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(kind == 'in_moment' ? (payload['text'] ?? 'Breathe together?').toString() : 'Was that a conflict? Did it resolve?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                if (payload['title'] != null) Text(payload['title'].toString(), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ]),
            ),
            const FaIcon(FontAwesomeIcons.chevronRight, color: Colors.white38, size: 14),
          ]),
        ),
      ),
    );
  }

  Widget _quickActions(UsProvider us, Map<String, dynamic> me) {
    final f = us.today?['my_features'] as Map<String, dynamic>?;
    final cycleDay = f?['cycle_day'];
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(vertical: 12)),
          onPressed: () => _periodStarted(us),
          icon: const FaIcon(FontAwesomeIcons.droplet, size: 14, color: Color(0xFFE5785C)),
          label: Text(cycleDay == null ? 'Period started' : 'Cycle day $cycleDay · log'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(vertical: 12)),
          onPressed: () => us.refresh(force: true, card: true),
          icon: const FaIcon(FontAwesomeIcons.rotate, size: 14),
          label: const Text('Recompute'),
        ),
      ),
    ]);
  }

  Future<void> _periodStarted(UsProvider us) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1F1F25),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16), child: Text('Period started', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600))),
          ListTile(title: const Text('Today', style: TextStyle(color: Colors.white)), onTap: () => Navigator.of(ctx).pop('today')),
          ListTile(title: const Text('Yesterday', style: TextStyle(color: Colors.white)), onTap: () => Navigator.of(ctx).pop('yesterday')),
          ListTile(title: const Text('Pick a date', style: TextStyle(color: Colors.white)), onTap: () => Navigator.of(ctx).pop('pick')),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    DateTime day = DateTime.now();
    if (choice == 'yesterday') day = day.subtract(const Duration(days: 1));
    if (choice == 'pick') {
      final picked = await showDatePicker(context: context, firstDate: DateTime.now().subtract(const Duration(days: 400)), lastDate: DateTime.now(), initialDate: day);
      if (picked == null) return;
      day = picked;
    }
    final s = '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    await us.logPeriodStarted(day: s);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Logged $s')));
  }

  Widget _bodyCard(UsProvider us) {
    final b = us.body;
    final workouts = ((b?['workouts'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final last = b?['last_workout'] as Map<String, dynamic>?;
    final outside = b?['outside'] as Map<String, dynamic>? ?? const {};
    final daylight = b?['daylight_minutes'];
    final exercise = b?['exercise_minutes'];
    final tracking = outside['tracking'] == true;
    final homeKnown = outside['home_known'] == true;
    final outsideMin = outside['outside_minutes'];
    final sunEst = outside['sun_minutes_est'];
    final sunAvail = outside['sunshine_minutes_available'];
    String workoutLine(Map<String, dynamic> w, {bool withDay = false}) {
      final parts = <String>[w['activity'].toString(), '${w['minutes']} min'];
      if (w['km'] != null) parts.add('${w['km']} km');
      if (w['exertion_label'] != null) parts.add('${w['exertion_label']}${w['avg_hr'] != null ? ' · ${w['avg_hr']} bpm' : ''}');
      if (w['indoor'] == true) parts.add('indoor');
      if (withDay && w['days_ago'] != null) parts.add(w['days_ago'] == 0 ? 'today' : w['days_ago'] == 1 ? 'yesterday' : '${w['days_ago']} days ago');
      return parts.join(' · ');
    }
    return _card(children: [
      Text('${us.isActingAsPartner ? us.ownerName : 'Your'} body today', style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
      const SizedBox(height: 8),
      if (workouts.isEmpty && last == null) const Text('No workouts on record.', style: TextStyle(color: Colors.white54)),
      for (final w in workouts) _kv('Workout', workoutLine(w)),
      if (workouts.isEmpty && last != null) _kv('Last workout', workoutLine(last, withDay: true)),
      if (b?['days_since_strength'] != null) _kv('Strength', b!['days_since_strength'] == 0 ? 'today' : '${b['days_since_strength']} days ago'),
      if (exercise != null) _kv('Exercise minutes', '$exercise'),
      _kv('Daylight (watch)', daylight == null ? 'not reported yet' : '$daylight min'),
      _kv('Away from home', !tracking ? 'off' : !homeKnown ? 'learning where home is' : outsideMin == null ? '—' : '${(outsideMin / 60).toStringAsFixed(1)} h${sunEst != null ? ' · ~$sunEst min of sun (of $sunAvail available)' : ''}'),
      const SizedBox(height: 4),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        activeColor: const Color(0xFF6FC3B8),
        title: const Text('Track time outside', style: TextStyle(color: Colors.white)),
        subtitle: Text(
          us.visitsStatus['authorization'] == 'denied'
              ? 'Location is denied in Settings.'
              : 'Arrivals and departures at places, rounded to 100 m. Needs "Always" location.',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        value: UsVisits.enabled,
        onChanged: us.isActingAsPartner ? null : (v) => us.setTrackOutside(v),
      ),
    ]);
  }

  Widget _weekStrip(UsProvider us) {
    final days = ((us.history?['days'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final last7 = days.length > 7 ? days.sublist(days.length - 7) : days;
    int sum(String k) => last7.fold(0, (a, d) => a + ((d[k] as num?)?.toInt() ?? 0));
    return Row(children: [
      _stat('${sum('minutes_together')}', 'min together'),
      _stat('${sum('hard_conversations')}', 'hard talks'),
      _stat('${sum('protocol_done')}/${sum('protocol_offered')}', 'protocols'),
    ]);
  }

  Widget _stat(String v, String l) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Text(v, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
            Text(l, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        ),
      );

  Widget _trend(UsProvider us) {
    final risk = ((us.history?['risk'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final days = ((us.history?['days'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final hardBy = {for (final d in days) d['day'].toString(): ((d['hard_conversations'] as num?)?.toInt() ?? 0) > 0};
    final last = risk.length > 14 ? risk.sublist(risk.length - 14) : risk;
    if (last.isEmpty) return const SizedBox.shrink();
    return _card(children: [
      const Text('Last two weeks', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final r in last)
            Column(children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: r['level'] == 'high' ? const Color(0xFFE5785C) : r['level'] == 'elevated' ? const Color(0xFFD4A64F) : r['level'] == 'calm' ? const Color(0xFF6FC3B8) : Colors.white12,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 4),
              Container(width: 6, height: 6, decoration: BoxDecoration(color: hardBy[r['day'].toString()] == true ? Colors.white : Colors.transparent, shape: BoxShape.circle)),
            ]),
        ],
      ),
      const SizedBox(height: 6),
      const Text('Colour: the morning forecast. White dot: a hard conversation that day. The honest test is whether they line up.', style: TextStyle(color: Colors.white38, fontSize: 12)),
    ]);
  }

  Widget _conversations(UsProvider us) {
    final convs = ((us.history?['conversations'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (convs.isEmpty) return _card(children: const [Text('No conversations between the two of you yet.', style: TextStyle(color: Colors.white70))]);
    return _card(children: [
      const Text('The two of you', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
      const SizedBox(height: 8),
      for (final c in convs.take(8)) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c['title']?.toString() ?? 'Conversation', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              if (c['summary'] != null) Text(c['summary'].toString(), style: const TextStyle(color: Colors.white54, fontSize: 13)),
              Text('${(c['started_at'] ?? '').toString().replaceFirst('T', ' ').substring(0, 16)}${c['scope'] == 'us_others' ? ' · with others' : ''}', style: const TextStyle(color: Colors.white24, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (c['tension'] != null) Text('${((c['tension'] as num) * 100).round()}%', style: TextStyle(color: (c['tension'] as num) >= 0.55 ? const Color(0xFFE5785C) : Colors.white70, fontWeight: FontWeight.w700)),
            if (c['hard'] == true || (c['hard'] == null && c['model_hard'] == true)) Text(c['hard'] == true ? 'hard' : 'hard?', style: const TextStyle(color: Color(0xFFE5785C), fontSize: 11)),
          ]),
        ]),
        const Divider(color: Colors.white12, height: 18),
      ],
    ]);
  }

  Widget _weeklyReport(UsProvider us) {
    final r = us.weekly?['report'] as Map<String, dynamic>?;
    if (r == null) {
      return _card(children: [
        Row(children: [
          const Text('This week', style: TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
          const Spacer(),
          TextButton(onPressed: () => us.loadWeekly(refresh: true), child: const Text('Build report', style: TextStyle(color: Colors.white70))),
        ]),
      ]);
    }
    final strongest = r['strongest_predictor'] as Map<String, dynamic>?;
    final honest = r['honest_test'] as Map<String, dynamic>? ?? {};
    final text = 'Us · week of ${r['week_start']}\n'
        '${r['hard_conversations']} hard conversation(s) (last week ${r['hard_conversations_prev_week']})\n'
        '${r['repaired_within_twenty']} repaired within twenty minutes\n'
        '${r['minutes_together']} minutes together\n'
        '${r['protocols_done']}/${r['protocols_offered']} protocols done';
    return RepaintBoundary(key: _weeklyKey, child: _card(children: [
      Row(children: [
        Text('Week of ${r['week_start']}', style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
        const Spacer(),
        IconButton(icon: const FaIcon(FontAwesomeIcons.share, color: Colors.white70, size: 16), onPressed: () => _shareWeekly(text)),
        IconButton(icon: const FaIcon(FontAwesomeIcons.rotate, color: Colors.white38, size: 14), onPressed: () => us.loadWeekly(refresh: true)),
      ]),
      _kv('Hard conversations', '${r['hard_conversations']}  (last week ${r['hard_conversations_prev_week']})'),
      _kv('Repaired within 20 min', '${r['repaired_within_twenty']}'),
      _kv('Minutes together', '${r['minutes_together']}'),
      _kv('Protocols done', '${r['protocols_done']} of ${r['protocols_offered']}'),
      if (strongest != null) _kv('Strongest predictor', '${strongest['text']} (${strongest['hard_days']} of ${strongest['days']} days)'),
      const SizedBox(height: 6),
      Text('Honest test: ${honest['verdict'] ?? '—'}', style: const TextStyle(color: Colors.white54, fontSize: 13, fontStyle: FontStyle.italic)),
    ]));
  }

  /// The weekly card as an image for the share sheet: numbers, never text
  /// from a conversation. Falls back to plain text if rendering fails.
  Future<void> _shareWeekly(String fallbackText) async {
    try {
      final boundary = _weeklyKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('no boundary');
      final ui.Image image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('no png');
      final Uint8List bytes = data.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/us-week.png');
      await file.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')], text: 'Us · this week');
    } catch (e) {
      await Share.share(fallbackText);
    }
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k, style: const TextStyle(color: Colors.white70))),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: const TextStyle(color: Colors.white))),
        ]),
      );

  Widget _sharing(UsProvider us, Map<String, dynamic> couple) {
    final sharing = couple['sharing'] as Map<String, dynamic>? ?? {};
    Widget sw(String key, String label) => SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          activeColor: const Color(0xFF6FC3B8),
          title: Text(label, style: const TextStyle(color: Colors.white)),
          value: sharing[key] == true,
          onChanged: (v) => us.setSharing(key, v),
        );
    return _card(children: [
      Text('What ${couple['partner']?['name'] ?? 'your partner'} can see of yours', style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
      sw('share_sleep', 'Sleep'),
      sw('share_readiness', 'Readiness, HRV, heart rate'),
      sw('share_cycle', 'Cycle phase'),
      sw('share_conflict_factors', 'Conflict factors'),
      const Divider(color: Colors.white12),
      Row(children: [
        TextButton(onPressed: () => us.setPaused(true), child: const Text('Pause Us', style: TextStyle(color: Colors.white70))),
        const Spacer(),
        TextButton(onPressed: () => _confirmEnd(us), child: const Text('End Us', style: TextStyle(color: Color(0xFFE5785C)))),
      ]),
    ]);
  }

  Future<void> _confirmEnd(UsProvider us) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(c, () => Navigator.of(c).pop(false), () => Navigator.of(c).pop(true), 'End Us?',
          'Analysis stops at once and everything the two of you produced together (days, risk history, protocol logs) is deleted. Your own data stays yours.',
          okButtonText: 'End'),
    );
    if (ok == true) await us.endCouple();
  }

  // ---------------------------------------------------------------------------

  ButtonStyle get _primary => ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12));

  Widget _card({required List<Widget> children}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _notice(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF3A3122), borderRadius: BorderRadius.circular(12)),
          child: Text(text, style: const TextStyle(color: Color(0xFFD4A64F), fontSize: 13, height: 1.4)),
        ),
      );

  Widget _errorBox(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFF45261F), borderRadius: BorderRadius.circular(12)),
          child: Text(text, style: const TextStyle(color: Color(0xFFE5785C), fontSize: 13)),
        ),
      );
}
