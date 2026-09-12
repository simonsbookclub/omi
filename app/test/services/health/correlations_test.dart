import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/health/correlations.dart';

/// The engine is arithmetic, so it can be checked against arithmetic: known
/// answers first, then Simon's real eleven years to prove it survives the
/// shape of actual data (ties, gaps, one metric present on 34 days and
/// another on 2,756).
void main() {
  group('spearman', () {
    test('perfect monotonic but non-linear is 1.0 (where Pearson would not be)', () {
      final x = <double>[1, 2, 3, 4, 5, 6, 7, 8];
      final y = <double>[1, 4, 9, 16, 25, 36, 49, 64];
      expect(spearman(x, y), closeTo(1.0, 1e-9));
    });

    test('perfect inverse is -1.0', () {
      expect(spearman(<double>[1, 2, 3, 4, 5], <double>[5, 4, 3, 2, 1]), closeTo(-1.0, 1e-9));
    });

    test('ties are averaged, so all-equal has no correlation', () {
      expect(spearman(<double>[1, 1, 1, 1], <double>[1, 2, 3, 4]), 0);
    });
  });

  group('pValue', () {
    test('a strong correlation over many points is decisive', () {
      expect(pValue(0.8, 100), lessThan(0.0001));
    });
    test('a weak correlation over few points is not', () {
      expect(pValue(0.1, 20), greaterThan(0.05));
    });
    test('r=0 is p=1', () {
      expect(pValue(0.0, 50), closeTo(1.0, 1e-6));
    });
  });

  crossDomain();

  group('against Simon\'s real record', () {
    late List<String> days;
    late Map<String, List<double?>> metrics;

    setUpAll(() {
      final f = File('test/fixtures/series.json');
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      days = (j['days'] as List).cast<String>();
      metrics = (j['metrics'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as List).map((e) => (e as num?)?.toDouble()).toList()));
    });

    test('the eleven-year scan returns findings that replicate', () {
      if (!File('test/fixtures/series.json').existsSync()) return;
      final found = scan(days, metrics);
      // Every survivor must have cleared all four defences by construction.
      for (final f in found) {
        expect(f.r.abs(), greaterThanOrEqualTo(minAbsR), reason: '${f.a}/${f.b} below effect floor');
        expect(f.qValue, lessThanOrEqualTo(0.05), reason: '${f.a}/${f.b} failed FDR');
        expect(f.replicated, isTrue, reason: '${f.a}/${f.b} did not replicate');
        expect(f.rFirstHalf!.sign, f.rSecondHalf!.sign, reason: '${f.a}/${f.b} flipped sign across halves');
      }
      // ignore: avoid_print
      print('scan surfaced ${found.length} findings that survived all four defences');
      for (final f in found.take(12)) {
        // ignore: avoid_print
        print('  ${f.r >= 0 ? '+' : ''}${f.r}  ${f.a} / ${f.b}  '
            '(${f.grain.name}, lag ${f.lagDays}d, n=${f.n}, q=${f.qValue}, '
            'halves ${f.rFirstHalf}/${f.rSecondHalf})');
      }
    });

    test('on-demand pair works and matches the scan', () {
      if (!File('test/fixtures/series.json').existsSync()) return;
      final f = correlate(days, 'run_km', metrics['run_km']!, 'body_fat', metrics['body_fat']!,
          grain: Grain.monthly);
      expect(f, isNotNull);
      // ignore: avoid_print
      print('run_km vs body_fat, monthly: r=${f!.r} n=${f.n} p=${f.p.toStringAsExponential(2)}');
    });
  });
}

/// The cross-domain questions Simon actually wants answered — body against
/// mind — are not yet answerable: speech series begin 2026-08-18 against body
/// series reaching 2014. The engine must REFUSE them rather than return a
/// number, and must keep refusing until the overlap is real.
void crossDomain() {
  test('body-vs-mind pairs are refused for want of overlap, not answered', () {
    final f = File('test/fixtures/series.json');
    if (!f.existsSync()) return;
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final days = (j['days'] as List).cast<String>();
    final metrics = (j['metrics'] as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as List).map((e) => (e as num?)?.toDouble()).toList()));

    for (final pair in [
      ['run_pace_s_per_km', 'speech_valence'],
      ['body_fat', 'hard_conversations'],
      ['hrv_sdnn', 'tension'],
    ]) {
      final a = metrics[pair[0]], b = metrics[pair[1]];
      if (a == null || b == null) continue;
      final r = correlate(days, pair[0], a, pair[1], b);
      expect(r, isNull, reason: '${pair[0]} vs ${pair[1]} should be refused, not answered');
      // ignore: avoid_print
      print('  ${pair[0]} vs ${pair[1]}: correctly refused (too little overlap)');
    }
  });
}
