import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/pages/us/us_theme.dart';
import 'package:omi/providers/us_provider.dart';

/// SIMONSBOOKCLUB: who talked, and how — on every conversation with more than
/// one voice in it.
///
/// Time and words come straight from the transcript on the phone, so this
/// works on every conversation the moment it opens and never disagrees with
/// the transcript underneath it. Tone comes from the server, which scores each
/// person's own lines (speech_sentiment.people); until that lands for a
/// conversation the tone line is simply absent, not invented.
class WhoTalkedCard extends StatelessWidget {
  const WhoTalkedCard({super.key, required this.conversation});

  final ServerConversation conversation;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<UsProvider>();
    final people = _tally(conversation, provider);
    if (people.length < 2) return const SizedBox.shrink();
    final totalSeconds = people.fold<double>(0, (a, p) => a + p.seconds);
    final totalWords = people.fold<int>(0, (a, p) => a + p.words);
    if (totalSeconds < 30 || totalWords < 40) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: UsCard(
        children: [
          const UsLabel('Who talked'),
          const SizedBox(height: 12),
          // One bar, everyone's share of the talking time in their colour.
          Row(
            children: [
              for (var i = 0; i < people.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  flex: (people[i].seconds * 10).round().clamp(1, 1 << 20),
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: people[i].colour,
                      borderRadius: BorderRadius.horizontal(
                        left: Radius.circular(i == 0 ? 3 : 0),
                        right: Radius.circular(i == people.length - 1 ? 3 : 0),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < people.length; i++) ...[
            if (i > 0) const Divider(height: 18, thickness: 0.5, color: UsInk.hairline),
            _PersonRow(person: people[i], totalSeconds: totalSeconds, totalWords: totalWords),
          ],
        ],
      ),
    );
  }

  /// Every voice in the transcript with its time, words and turns, most
  /// talkative first. Media (a video playing) and pinned markers are not voices.
  static List<_Person> _tally(ServerConversation c, UsProvider provider) {
    final segments = c.transcriptSegments;
    final byKey = <String, _Person>{};
    String? lastKey;
    final partnerName = provider.partnerName.trim().toLowerCase();
    final people = c.speechSentiment?['people'];

    for (final s in segments) {
      if (s.speaker == 'MARKER' || s.media || s.text.trim().isEmpty) continue;
      final String key;
      final String name;
      final Color colour;
      if (s.isUser) {
        key = 'me';
        name = provider.ownerName;
        colour = UsInk.you;
      } else if (s.personId != null) {
        key = 'person:${s.personId}';
        final person = SharedPreferencesUtil().getPersonById(s.personId!);
        name = person?.name ?? 'Someone';
        colour = name.trim().toLowerCase() == partnerName ? UsInk.them : UsInk.faint;
      } else {
        key = 'speaker:${s.stream ?? ''}:${s.speakerId}';
        name = 'Speaker ${TranscriptSegment.getDisplaySpeakerId(s.speakerId, segments, stream: s.stream)}';
        colour = UsInk.faint;
      }
      final p = byKey.putIfAbsent(key, () {
        final tone = people is Map && people[key] is Map ? people[key] as Map : null;
        return _Person(
          key: key,
          name: name,
          colour: colour,
          valence: (tone?['valence'] as num?)?.toDouble(),
          arousal: (tone?['arousal'] as num?)?.toDouble(),
          emotion: tone?['emotion']?.toString(),
        );
      });
      p.seconds += (s.end - s.start).clamp(0, 600).toDouble();
      p.words += s.text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      if (key != lastKey) p.turns += 1;
      lastKey = key;
    }
    final list = byKey.values.where((p) => p.words > 0).toList()..sort((a, b) => b.seconds.compareTo(a.seconds));
    return list;
  }
}

class _Person {
  _Person({required this.key, required this.name, required this.colour, this.valence, this.arousal, this.emotion});
  final String key;
  final String name;
  final Color colour;
  double seconds = 0;
  int words = 0;
  int turns = 0;
  final double? valence;
  final double? arousal;
  final String? emotion;
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, required this.totalSeconds, required this.totalWords});
  final _Person person;
  final double totalSeconds;
  final int totalWords;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final timeShare = totalSeconds > 0 ? (p.seconds / totalSeconds * 100).round() : 0;
    final wordShare = totalWords > 0 ? (p.words / totalWords * 100).round() : 0;
    final tone = _toneLine(p);
    const num = TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]);
    const lbl = TextStyle(color: UsInk.label, fontSize: 11);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: p.colour, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.name, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            Text('${p.turns} turn${p.turns == 1 ? '' : 's'}', style: lbl),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _Figure(value: _mmss(p.seconds), label: 'talking · $timeShare%', style: num, labelStyle: lbl)),
            Expanded(child: _Figure(value: _thousands(p.words), label: 'words · $wordShare%', style: num, labelStyle: lbl)),
            Expanded(
              child: _Figure(
                value: p.seconds >= 20 ? '${(p.words / (p.seconds / 60)).round()}' : '—',
                label: 'words / min',
                style: num,
                labelStyle: lbl,
              ),
            ),
          ],
        ),
        if (tone != null) ...[
          const SizedBox(height: 6),
          Text(tone, style: const TextStyle(color: UsInk.body, fontSize: 12.5, height: 1.35)),
        ],
      ],
    );
  }

  /// Valence and arousal in words, from the server's score of this person's
  /// own lines. Null when the server has not scored this conversation yet.
  static String? _toneLine(_Person p) {
    final v = p.valence, a = p.arousal;
    if (v == null || a == null) return null;
    final warmth = v > 0.35 ? 'warm' : v > 0.1 ? 'mildly positive' : v < -0.35 ? 'negative' : v < -0.1 ? 'a little flat' : 'neutral';
    final energy = a > 0.65 ? 'animated' : a > 0.4 ? 'engaged' : 'calm';
    final emotion = (p.emotion ?? '').trim();
    return '${emotion.isNotEmpty ? '${_cap(emotion)} — ' : ''}$warmth, $energy';
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label, required this.style, required this.labelStyle});
  final String value;
  final String label;
  final TextStyle style;
  final TextStyle labelStyle;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(value, style: style), const SizedBox(height: 2), Text(label, style: labelStyle)],
      );
}

String _mmss(double seconds) {
  final s = seconds.round();
  final m = s ~/ 60;
  return '$m:${(s % 60).toString().padLeft(2, '0')}';
}

String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
