import 'package:flutter/material.dart';

import 'package:omi/pages/us/us_theme.dart';

/// SIMONSBOOKCLUB ("Us"): a joint activity, drawn as two hearts on one axis.
///
/// Nothing either of you wears knows who you were with. The server finds
/// these by intersecting each person's own periods of raised heart rate,
/// calibrated to that person — see src/us-together.ts. The card therefore
/// says how it knows, and never states it as observed fact.
class UsTogetherCard extends StatelessWidget {
  const UsTogetherCard({super.key, required this.activity});

  final Map<String, dynamic> activity;

  @override
  Widget build(BuildContext context) {
    final people = ((activity['people'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final series = ((activity['series'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final sharedFrom = (activity['shared_from'] as num?)?.toInt() ?? 0;
    final sharedTo = (activity['shared_to'] as num?)?.toInt() ?? 0;
    final binMinutes = (activity['series_bin_minutes'] as num?)?.toInt() ?? 5;
    final start = DateTime.tryParse(activity['series_start']?.toString() ?? '')?.toLocal();

    List<double?> valuesFor(String userId) {
      final s = series.where((e) => e['user_id'] == userId).firstOrNull;
      return ((s?['values'] as List?) ?? const [])
          .map((v) => v == null ? null : (v as num).toDouble())
          .toList();
    }

    // The server marks the viewer's own row and lists it first, because the
    // client's notion of "me" gets murky under the person switch.
    bool mineAt(int i) => i < people.length ? people[i]['mine'] == true : false;

    return UsCard(
      border: UsInk.you.withValues(alpha: 0.18),
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          ShaderMask(
            shaderCallback: (r) => UsInk.sharedGradient.createShader(r),
            child: const UsLabel('Together', color: Colors.white),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              activity['detail']?.toString().split(' · ').take(2).join(' · ') ?? '',
              textAlign: TextAlign.right,
              style: const TextStyle(color: UsInk.faint, fontSize: 11.5, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ]),
        const SizedBox(height: 7),
        Text(
          activity['headline']?.toString() ?? 'You moved together',
          style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        ),
        if (_tail(activity['detail']?.toString()) != null) ...[
          const SizedBox(height: 3),
          Text(_tail(activity['detail']?.toString())!, style: const TextStyle(color: UsInk.label, fontSize: 13)),
        ],
        if (series.length == 2) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 100,
            child: CustomPaint(
              size: Size.infinite,
              painter: _TwoHeartsPainter(
                first: valuesFor(people.isNotEmpty ? people[0]['user_id'].toString() : ''),
                second: valuesFor(people.length > 1 ? people[1]['user_id'].toString() : ''),
                firstColor: UsInk.person(mineAt(0)),
                secondColor: UsInk.person(people.length > 1 ? mineAt(1) : false),
                sharedFrom: sharedFrom,
                sharedTo: sharedTo,
              ),
            ),
          ),
          const SizedBox(height: 7),
          _axis(start, series.first['values'] as List? ?? const [], binMinutes),
        ],
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < people.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: _personColumn(people[i], mineAt(i))),
          ],
        ]),
        const SizedBox(height: 11),
        Text(
          activity['evidence'] == 'workout'
              ? 'Matched by both heart rates rising in the same window, confirmed by a tagged workout.'
              : 'Matched by both heart rates rising in the same window.',
          style: const TextStyle(color: Color(0x42FFFFFF), fontSize: 11, height: 1.4),
        ),
      ],
    );
  }

  /// The detail line is "08:10–09:00 · 50 min · Masha kept going…"; the head
  /// sits beside the label, so only the tail belongs under the headline.
  static String? _tail(String? detail) {
    if (detail == null) return null;
    final parts = detail.split(' · ');
    if (parts.length < 3) return null;
    final tail = parts.sublist(2).join(' · ');
    return tail.isEmpty ? null : '$tail.';
  }

  Widget _axis(DateTime? start, List values, int binMinutes) {
    if (start == null || values.isEmpty) return const SizedBox.shrink();
    String at(int i) {
      final t = start.add(Duration(minutes: i * binMinutes));
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }
    final marks = [0, (values.length - 1) ~/ 2, values.length - 1];
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      for (final m in marks)
        Text(at(m), style: const TextStyle(color: Color(0x42FFFFFF), fontSize: 10.5, fontFeatures: [FontFeature.tabularFigures()])),
    ]);
  }

  Widget _personColumn(Map<String, dynamic> p, bool mine) {
    final c = UsInk.person(mine);
    final km = p['km'];
    final headline = km != null ? '$km' : '${p['own_minutes'] ?? p['minutes']}';
    final unit = km != null ? 'km' : 'min';
    final kcal = p['kcal'];
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(13),
        border: Border(left: BorderSide(color: c, width: 2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p['name']?.toString() ?? '', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        RichText(
          text: TextSpan(children: [
            TextSpan(
              text: headline,
              style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
            ),
            TextSpan(text: ' $unit', style: const TextStyle(color: UsInk.label, fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
        ),
        const SizedBox(height: 3),
        Text(
          '${p['avg_hr']} avg · ${p['peak_hr']} peak',
          style: const TextStyle(color: Color(0x8CFFFFFF), fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
        ),
        const SizedBox(height: 2),
        Text(
          kcal != null ? '$kcal kcal' : 'ring only · no distance',
          style: const TextStyle(color: UsInk.faint, fontSize: 11.5),
        ),
      ]),
    );
  }
}

/// Two traces, one axis, the shared stretch shaded. Both are scaled together
/// so the difference between the two of you is the thing you see.
class _TwoHeartsPainter extends CustomPainter {
  _TwoHeartsPainter({
    required this.first,
    required this.second,
    required this.firstColor,
    required this.secondColor,
    required this.sharedFrom,
    required this.sharedTo,
  });

  final List<double?> first;
  final List<double?> second;
  final Color firstColor;
  final Color secondColor;
  final int sharedFrom;
  final int sharedTo;

  @override
  void paint(Canvas canvas, Size size) {
    final n = first.length > second.length ? first.length : second.length;
    if (n < 2) return;
    final all = [...first, ...second].whereType<double>().toList();
    if (all.isEmpty) return;
    var lo = all.reduce((a, b) => a < b ? a : b);
    var hi = all.reduce((a, b) => a > b ? a : b);
    // A little air, and never a flat line pinned to an edge.
    final pad = ((hi - lo) * 0.12).clamp(4.0, 30.0);
    lo -= pad;
    hi += pad;
    if (hi - lo < 1) hi = lo + 1;

    double x(int i) => size.width * (i / (n - 1));
    double y(double v) => size.height - (v - lo) / (hi - lo) * size.height;

    // The shared stretch.
    if (sharedTo >= sharedFrom) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x(sharedFrom), 0, x(sharedTo + 1 > n - 1 ? n - 1 : sharedTo + 1), size.height),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, Paint()..color = const Color(0x0DFFFFFF));
    }

    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()..color = const Color(0x1AFFFFFF)..strokeWidth = 1,
    );

    void trace(List<double?> values, Color color) {
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path();
      var open = false;
      for (var i = 0; i < values.length; i++) {
        final v = values[i];
        if (v == null) continue; // a gap in sampling is a gap in the line
        final p = Offset(x(i), y(v));
        if (!open) {
          path.moveTo(p.dx, p.dy);
          open = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, paint);

      // The peak inside the shared stretch, labelled — the number that
      // makes the trace mean something.
      var peakAt = -1;
      var peak = double.negativeInfinity;
      for (var i = sharedFrom; i <= sharedTo && i < values.length; i++) {
        final v = values[i];
        if (v != null && v > peak) {
          peak = v;
          peakAt = i;
        }
      }
      if (peakAt < 0) return;
      final at = Offset(x(peakAt), y(peak));
      canvas.drawCircle(at, 3.5, Paint()..color = UsInk.card);
      canvas.drawCircle(at, 3.5, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
      final tp = TextPainter(
        text: TextSpan(
          text: peak.round().toString(),
          style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (at.dx + 6).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(lx, at.dy - tp.height - 2));
    }

    trace(second, secondColor);
    trace(first, firstColor);
  }

  @override
  bool shouldRepaint(covariant _TwoHeartsPainter old) =>
      old.first != first || old.second != second || old.sharedFrom != sharedFrom || old.sharedTo != sharedTo;
}
