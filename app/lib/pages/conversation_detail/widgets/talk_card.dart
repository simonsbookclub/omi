import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/pages/us/us_theme.dart';
import 'package:omi/providers/us_provider.dart';

/// SIMONSBOOKCLUB ("Us"): the deep read of a conversation that was actually a
/// conversation.
///
/// The server scores every exchange for tension and repair, which is the right
/// question about an argument and a useless one about a morning over coffee —
/// it answered 0.2 / 0.8 on every warm talk alike. So a conversation now has to
/// earn a second, different read (see us-talk.ts): both partners speaking at
/// length and taking the floor repeatedly. Over the eight days to 2026-09-11
/// that was 8 conversations out of 535; the other 527 were "are you coming?".
///
/// Everything shown here is anchored to something they actually said — a claim
/// whose quote could not be found in the transcript is dropped server-side
/// rather than rendered.
class TalkCard extends StatelessWidget {
  const TalkCard({super.key, required this.us});

  final UsInfo us;

  @override
  Widget build(BuildContext context) {
    final analysis = us.analysis;
    if (analysis == null || analysis['talk'] != true) return const SizedBox.shrink();
    final depth = analysis['depth'];
    // `failed: true` is a recorded "the model could not read this", stored so
    // the server stops retrying. It is not something to show.
    if (depth is! Map<String, dynamic> || depth['failed'] == true) return const SizedBox.shrink();

    // Watched, not read: the couple loads asynchronously at startup, so the
    // names fill in when it lands rather than staying "Partner" forever.
    final provider = context.watch<UsProvider>();
    final ownerId = us.ownerUserId;
    // The partner comes out of the conversation itself. Reading it off the
    // provider would leave the balance bar at 0% whenever this screen opens
    // before the Us tab has ever been visited.
    String nameOf(String id) => id == ownerId ? provider.ownerName : provider.partnerName;
    bool isMine(String id) => id == ownerId;

    final threads = _list(depth['threads']);
    final questions = _list(depth['questions']);
    final disclosures = _list(depth['disclosures']);
    final agreements = _list(depth['agreements']);
    final arc = (depth['arc'] as String?)?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: UsCard(
        children: [
          _Header(us: us, ownerName: provider.ownerName, partnerName: provider.partnerName),
          if (arc.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              arc,
              style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.45, fontWeight: FontWeight.w500),
            ),
          ],
          if (threads.isNotEmpty) ...[
            const SizedBox(height: 22),
            const UsLabel('What we talked about'),
            const SizedBox(height: 10),
            _Threads(threads: threads, nameOf: nameOf, isMine: isMine),
          ],
          if (questions.isNotEmpty) ...[
            const SizedBox(height: 22),
            const UsLabel('What we asked each other'),
            const SizedBox(height: 10),
            for (final q in questions) _Question(q: q, nameOf: nameOf, isMine: isMine),
          ],
          if (disclosures.isNotEmpty) ...[
            const SizedBox(height: 22),
            const UsLabel('What we said about ourselves'),
            const SizedBox(height: 10),
            for (final d in disclosures) _Moment(m: d, nameOf: nameOf, isMine: isMine),
          ],
          if (agreements.isNotEmpty) ...[
            const SizedBox(height: 22),
            const UsLabel('What we said we would do'),
            const SizedBox(height: 10),
            for (final a in agreements) _Moment(m: a, nameOf: nameOf, isMine: isMine, tick: true),
          ],
        ],
      ),
    );
  }

  static List<Map<String, dynamic>> _list(dynamic v) =>
      v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

}

class _Header extends StatelessWidget {
  const _Header({required this.us, required this.ownerName, required this.partnerName});
  final UsInfo us;
  final String ownerName;
  final String partnerName;

  @override
  Widget build(BuildContext context) {
    final words = (us.participation?['total_words'] as num?)?.toInt() ?? 0;
    return Row(
      children: [
        UsPairMark(you: ownerName, them: partnerName, size: 26),
        const SizedBox(width: 12),
        const Expanded(child: UsLabel('A real talk')),
        if (words > 0)
          Text(
            '${_thousands(words)} words',
            style: const TextStyle(color: UsInk.label, fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }
}

/// The threads, down a rail. The dot is the colour of whoever opened it, so
/// who steers the morning reads off the left edge without counting anything.
class _Threads extends StatelessWidget {
  const _Threads({required this.threads, required this.nameOf, required this.isMine});
  final List<Map<String, dynamic>> threads;
  final String Function(String) nameOf;
  final bool Function(String) isMine;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < threads.length; i++)
          _ThreadRow(
            thread: threads[i],
            first: i == 0,
            last: i == threads.length - 1,
            nameOf: nameOf,
            isMine: isMine,
          ),
      ],
    );
  }
}

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({
    required this.thread,
    required this.first,
    required this.last,
    required this.nameOf,
    required this.isMine,
  });
  final Map<String, dynamic> thread;
  final bool first;
  final bool last;
  final String Function(String) nameOf;
  final bool Function(String) isMine;

  @override
  Widget build(BuildContext context) {
    final by = (thread['opened_by'] as String?) ?? '';
    final mine = isMine(by);
    final colour = UsInk.person(mine);
    final min = (thread['start_min'] as num?)?.toInt() ?? 0;
    // stretch, not start: the rail's Expanded connector needs a bounded height,
    // and only stretch hands IntrinsicHeight's measurement down as a tight one.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 34,
            child: Align(
              alignment: Alignment.topRight,
              child: Text(
                '${min}m',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: UsInk.faint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: Column(
              children: [
                Container(width: 2, height: 5, color: first ? Colors.transparent : UsInk.hairline),
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                ),
                Expanded(child: Container(width: 2, color: last ? Colors.transparent : UsInk.hairline)),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (thread['topic'] as String?) ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${nameOf(by)} brought it up',
                    style: TextStyle(color: colour.withValues(alpha: 0.75), fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A question one of them put to the other. The ones that never got an answer
/// are the point of the section, so they are the ones that carry colour.
class _Question extends StatelessWidget {
  const _Question({required this.q, required this.nameOf, required this.isMine});
  final Map<String, dynamic> q;
  final String Function(String) nameOf;
  final bool Function(String) isMine;

  @override
  Widget build(BuildContext context) {
    final by = (q['asked_by'] as String?) ?? '';
    final answered = q['answered'] == true;
    final mine = isMine(by);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: UsInk.raised,
        borderRadius: BorderRadius.circular(12),
        border: answered ? null : Border.all(color: UsInk.elevated.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UsPersonChip(nameOf(by), mine: mine),
              const Spacer(),
              if (!answered) ...[
                const Icon(Icons.subdirectory_arrow_right_rounded, size: 13, color: UsInk.elevated),
                const SizedBox(width: 4),
                const Text(
                  'never answered',
                  style: TextStyle(color: UsInk.elevated, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '“${((q['text'] as String?) ?? '').trim()}”',
            style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// A disclosure or an agreement: the gloss in plain English, their own words
/// underneath it so the reading can always be checked against what was said.
class _Moment extends StatelessWidget {
  const _Moment({required this.m, required this.nameOf, required this.isMine, this.tick = false});
  final Map<String, dynamic> m;
  final String Function(String) nameOf;
  final bool Function(String) isMine;
  final bool tick;

  @override
  Widget build(BuildContext context) {
    final by = (m['by'] as String?) ?? '';
    final mine = isMine(by);
    final colour = UsInk.person(mine);
    final quote = ((m['quote'] as String?) ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 2, height: 34, margin: const EdgeInsets.only(top: 2, right: 12), color: colour),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (tick) ...[
                      Icon(Icons.check_rounded, size: 13, color: colour),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        (m['text'] as String?) ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (quote.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    '“$quote”',
                    style: const TextStyle(color: UsInk.body, fontSize: 12.5, height: 1.35, fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The measured half: who held the floor, and how often either of them picked
/// up what the other had just said.
String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
