/// Finding correlations across a decade of health data, on the phone, with no
/// model call.
///
/// Correlation is arithmetic. Twenty-three metrics make 253 pairs, and a rank
/// correlation over ~3,400 days is a few million operations — microseconds
/// here. Nothing needs a server and nothing needs a model.
///
/// The computation was never the hard part. **Not fooling yourself is.**
/// Testing 253 pairs at a conventional p < 0.05 produces about thirteen
/// "findings" that are pure chance, which is exactly how a quantified-self
/// dashboard ends up claiming your HRV depends on your Tuesday step count.
/// Four defences, all of them cheap arithmetic and all applied here:
///
///  1. **Spearman, not Pearson.** Ranks are robust to the single 25 km day
///     that would otherwise drag a line through the whole decade, and catch
///     relationships that are monotonic without being straight.
///  2. **Benjamini–Hochberg** across every pair tested in a scan, so the rate
///     of false discoveries is controlled rather than multiplied.
///  3. **Split-half replication.** Fit on the first half of the record, test on
///     the second. A real association survives both; a coincidence does not.
///     This is the most honest filter available and it costs one extra pass.
///  4. **A floor on effect size.** Over three thousand days an r of 0.08 is
///     "significant" and means nothing. Below [minAbsR] it is not reported.
///
/// What is deliberately NOT here: any claim of cause. These are one person's
/// observational days. A running month differs from a still month in diet,
/// season, daylight and mood, and no amount of history separates them.
library;

import 'dart:math' as math;

/// Below this, a correlation is real and uninteresting.
const double minAbsR = 0.25;

/// Fewer overlapping points than this and the pair is not tested at all.
const int minOverlap = 30;

/// How a pair of series is lined up in time.
enum Grain {
  /// Day against day. Right for things that move daily — sleep, HRV, load.
  daily,

  /// Month against month, each collapsed to its median. Right for anything
  /// slow: a single run cannot move body fat, so pairing them daily measures
  /// noise and nothing else.
  monthly,
}

class Finding {
  const Finding({
    required this.a,
    required this.b,
    required this.r,
    required this.n,
    required this.p,
    required this.lagDays,
    required this.grain,
    this.qValue,
    this.replicated,
    this.rFirstHalf,
    this.rSecondHalf,
  });

  final String a;
  final String b;
  final double r;
  final int n;
  final double p;

  /// 0 = same period. 1 = `a` today against `b` tomorrow.
  final int lagDays;
  final Grain grain;

  /// Benjamini–Hochberg adjusted p, set once the whole scan is known.
  final double? qValue;

  /// Whether the sign and a usable size held in both halves of the record.
  final bool? replicated;
  final double? rFirstHalf;
  final double? rSecondHalf;

  Finding withScanResults({double? q, bool? replicated, double? first, double? second}) => Finding(
        a: a, b: b, r: r, n: n, p: p, lagDays: lagDays, grain: grain,
        qValue: q ?? qValue,
        replicated: replicated ?? this.replicated,
        rFirstHalf: first ?? rFirstHalf,
        rSecondHalf: second ?? rSecondHalf,
      );

  /// Strength in words, so a UI never has to invent its own thresholds.
  String get strength {
    final abs = r.abs();
    if (abs >= 0.6) return 'strong';
    if (abs >= 0.4) return 'moderate';
    return 'weak';
  }

  String get direction => r < 0 ? 'inverse' : 'direct';

  Map<String, dynamic> toJson() => {
        'a': a, 'b': b, 'r': r, 'n': n, 'p': p, 'lag_days': lagDays,
        'grain': grain.name, 'q': qValue, 'replicated': replicated,
        'r_first_half': rFirstHalf, 'r_second_half': rSecondHalf,
      };
}

/// Ranks with ties averaged — the tie handling matters here, because days with
/// no run are all zero and would otherwise take arbitrary distinct ranks.
List<double> _rank(List<double> xs) {
  final idx = List<int>.generate(xs.length, (i) => i)..sort((i, j) => xs[i].compareTo(xs[j]));
  final ranks = List<double>.filled(xs.length, 0);
  var i = 0;
  while (i < idx.length) {
    var j = i;
    while (j + 1 < idx.length && xs[idx[j + 1]] == xs[idx[i]]) {
      j++;
    }
    final avg = (i + j) / 2.0 + 1.0;
    for (var k = i; k <= j; k++) {
      ranks[idx[k]] = avg;
    }
    i = j + 1;
  }
  return ranks;
}

double _pearson(List<double> x, List<double> y) {
  final n = x.length;
  if (n < 2) return 0;
  final mx = x.reduce((a, b) => a + b) / n;
  final my = y.reduce((a, b) => a + b) / n;
  var sxy = 0.0, sxx = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = x[i] - mx, dy = y[i] - my;
    sxy += dx * dy;
    sxx += dx * dx;
    syy += dy * dy;
  }
  if (sxx == 0 || syy == 0) return 0;
  return sxy / math.sqrt(sxx * syy);
}

/// Spearman's rho: Pearson over the ranks.
double spearman(List<double> a, List<double> b) => _pearson(_rank(a), _rank(b));

/// Two-sided p for a correlation, via the t approximation.
///
/// Exact enough well past the sample sizes here, and it avoids shipping a
/// statistics package for one function.
double pValue(double r, int n) {
  if (n < 3) return 1;
  final rr = r.clamp(-0.999999, 0.999999);
  final t = rr * math.sqrt((n - 2) / (1 - rr * rr));
  return _studentTwoSided(t.abs(), n - 2);
}

double _studentTwoSided(double t, int df) {
  // Incomplete beta via a continued fraction — the standard route to a t-test
  // p-value without a stats library.
  final x = df / (df + t * t);
  return _incompleteBeta(x, df / 2.0, 0.5).clamp(0.0, 1.0);
}

double _incompleteBeta(double x, double a, double b) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final lbeta = _lgamma(a) + _lgamma(b) - _lgamma(a + b);
  final front = math.exp(math.log(x) * a + math.log(1 - x) * b - lbeta) / a;
  var f = 1.0, c = 1.0, d = 0.0;
  for (var i = 0; i <= 200; i++) {
    final m = i ~/ 2;
    double numerator;
    if (i == 0) {
      numerator = 1.0;
    } else if (i % 2 == 0) {
      numerator = (m * (b - m) * x) / ((a + 2 * m - 1) * (a + 2 * m));
    } else {
      numerator = -((a + m) * (a + b + m) * x) / ((a + 2 * m) * (a + 2 * m + 1));
    }
    d = 1.0 + numerator * d;
    if (d.abs() < 1e-30) d = 1e-30;
    d = 1.0 / d;
    c = 1.0 + numerator / c;
    if (c.abs() < 1e-30) c = 1e-30;
    final cd = c * d;
    f *= cd;
    if ((1.0 - cd).abs() < 1e-10) break;
  }
  return front * (f - 1.0);
}

double _lgamma(double x) {
  const g = [
    676.5203681218851, -1259.1392167224028, 771.32342877765313,
    -176.61502916214059, 12.507343278686905, -0.13857109526572012,
    9.9843695780195716e-6, 1.5056327351493116e-7,
  ];
  if (x < 0.5) return math.log(math.pi / math.sin(math.pi * x)) - _lgamma(1 - x);
  final z = x - 1;
  var a = 0.99999999999980993;
  final t = z + 7.5;
  for (var i = 0; i < g.length; i++) {
    a += g[i] / (z + i + 1);
  }
  return 0.5 * math.log(2 * math.pi) + (z + 0.5) * math.log(t) - t + math.log(a);
}

/// Line two series up, honouring grain and lag, dropping days either is missing.
({List<double> a, List<double> b}) align(
  List<String> days,
  List<double?> a,
  List<double?> b, {
  int lagDays = 0,
  Grain grain = Grain.daily,
  bool sumA = false,
  bool sumB = false,
}) {
  if (grain == Grain.monthly) {
    final ma = _monthly(days, a, sumA), mb = _monthly(days, b, sumB);
    final keys = ma.keys.where(mb.containsKey).toList()..sort();
    return (
      a: [for (final k in keys) ma[k]!],
      b: [for (final k in keys) mb[k]!],
    );
  }
  final xs = <double>[], ys = <double>[];
  for (var i = 0; i + lagDays < days.length; i++) {
    final va = a[i], vb = b[i + lagDays];
    if (va == null || vb == null) continue;
    xs.add(va);
    ys.add(vb);
  }
  return (a: xs, b: ys);
}

/// Collapse a month, respecting what the metric IS.
///
/// This distinction is not cosmetic. Taking the median of daily `run_km` gives
/// the size of a typical run; summing gives the distance covered that month.
/// They are different variables and they answer different questions — against
/// body fat, the monthly total came out at r = -0.49 while the median of run
/// days came out at 0.02. Getting this wrong silently substitutes one question
/// for another, which is worse than returning nothing.
///
/// Totals for things you accumulate (kilometres, minutes, volume); medians for
/// things you simply are on a given day (weight, HRV, pace) — and a median
/// rather than a mean there, so one enormous day cannot define the month.
Map<String, double> _monthly(List<String> days, List<double?> values, bool sum) {
  final buckets = <String, List<double>>{};
  // For an accumulating metric, a month with no readings is a REAL zero, not a
  // missing value: a month he did not run is 0 km, and dropping it silently
  // restricts the question to "among months he ran at all". That single
  // difference took run_km against body fat from -0.49 across 130 months to
  // -0.02 across 65 — the same question, two opposite answers, because half
  // the evidence had been discarded.
  if (sum) {
    for (final d in days) {
      buckets.putIfAbsent(d.substring(0, 7), () => <double>[]);
    }
  }
  for (var i = 0; i < days.length; i++) {
    final v = values[i];
    if (v == null) continue;
    buckets.putIfAbsent(days[i].substring(0, 7), () => []).add(v);
  }
  return buckets.map((k, vs) {
    if (sum && vs.isEmpty) return MapEntry(k, 0.0);
    if (sum) return MapEntry(k, vs.reduce((x, y) => x + y));
    vs.sort();
    final mid = vs.length ~/ 2;
    return MapEntry(k, vs.length.isOdd ? vs[mid] : (vs[mid - 1] + vs[mid]) / 2);
  });
}

/// Metrics you accumulate over a month rather than simply have.
const accumulating = <String>{
  'run_km', 'run_minutes', 'lift_minutes', 'lift_volume_kg', 'walk_minutes',
  'steps_hourly', 'active_energy_hourly', 'distance_hourly', 'exercise_hourly',
  'daylight_hourly', 'sleep_stage', 'steps', 'active_kcal', 'stress_high', 'recovery_high',
};

/// Pairs that are the same fact twice, so a "finding" between them is a
/// tautology. Weight and body fat move together because body fat is computed
/// from weight; a run's distance and its duration are one event described two
/// ways. Reporting these as discoveries is how a dashboard loses trust.
bool _tautological(String a, String b) {
  const twins = <Set<String>>[
    {'body_mass', 'body_fat'},
    {'body_mass', 'lean_mass'},
    {'body_fat', 'lean_mass'},
    {'run_km', 'run_minutes'},
    {'run_km', 'run_pace_s_per_km'},
    {'run_minutes', 'run_pace_s_per_km'},
    {'running_speed', 'run_pace_s_per_km'},
    {'lift_minutes', 'lift_volume_kg'},
    {'steps_hourly', 'distance_hourly'},
    {'hrv_sdnn', 'hrv_avg'},
  ];
  return twins.any((t) => t.contains(a) && t.contains(b));
}

/// One pair, on demand. Returns null when there is not enough overlap.
Finding? correlate(
  List<String> days,
  String nameA,
  List<double?> a,
  String nameB,
  List<double?> b, {
  int lagDays = 0,
  Grain grain = Grain.daily,
}) {
  final aligned = align(days, a, b,
      lagDays: lagDays, grain: grain,
      sumA: accumulating.contains(nameA), sumB: accumulating.contains(nameB));
  final n = aligned.a.length;
  if (n < (grain == Grain.monthly ? 12 : minOverlap)) return null;
  final r = spearman(aligned.a, aligned.b);
  if (!r.isFinite) return null;
  return Finding(a: nameA, b: nameB, r: _r3(r), n: n, p: pValue(r, n), lagDays: lagDays, grain: grain);
}

double _r3(double v) => (v * 1000).round() / 1000;

/// Scan every pair and return only what survives all four defences.
///
/// [lags] are in days and only apply at daily grain; 0 and 1 answer different
/// questions ("together" vs "today predicts tomorrow") and are counted as
/// separate tests, because they are.
List<Finding> scan(
  List<String> days,
  Map<String, List<double?>> metrics, {
  List<int> lags = const [0, 1],
  List<Grain> grains = const [Grain.daily, Grain.monthly],
  double fdr = 0.05,
}) {
  final names = metrics.keys.toList()..sort();
  final candidates = <Finding>[];

  for (var i = 0; i < names.length; i++) {
    for (var j = i + 1; j < names.length; j++) {
      if (_tautological(names[i], names[j])) continue;
      for (final grain in grains) {
        for (final lag in grain == Grain.monthly ? const [0] : lags) {
          final f = correlate(days, names[i], metrics[names[i]]!, names[j], metrics[names[j]]!,
              lagDays: lag, grain: grain);
          if (f != null) candidates.add(f);
        }
      }
    }
  }
  if (candidates.isEmpty) return [];

  // Benjamini–Hochberg over everything tested, not per pair.
  candidates.sort((x, y) => x.p.compareTo(y.p));
  final m = candidates.length;
  final withQ = <Finding>[];
  var minQ = 1.0;
  for (var k = m - 1; k >= 0; k--) {
    final q = (candidates[k].p * m / (k + 1)).clamp(0.0, 1.0);
    minQ = math.min(minQ, q);
    withQ.insert(0, candidates[k].withScanResults(q: (minQ * 10000).round() / 10000));
  }

  final survivors = <Finding>[];
  for (final f in withQ) {
    if (f.r.abs() < minAbsR) continue;
    if ((f.qValue ?? 1) > fdr) continue;
    final rep = _replicates(days, metrics, f);
    if (rep == null || !rep.ok) continue;
    survivors.add(f.withScanResults(replicated: true, first: rep.first, second: rep.second));
  }
  survivors.sort((x, y) => y.r.abs().compareTo(x.r.abs()));
  return survivors;
}

/// Does it hold in both halves of the record?
({bool ok, double first, double second})? _replicates(
  List<String> days,
  Map<String, List<double?>> metrics,
  Finding f,
) {
  final cut = days.length ~/ 2;
  final a = metrics[f.a]!, b = metrics[f.b]!;
  final first = correlate(days.sublist(0, cut), f.a, a.sublist(0, cut), f.b, b.sublist(0, cut),
      lagDays: f.lagDays, grain: f.grain);
  final second = correlate(days.sublist(cut), f.a, a.sublist(cut), f.b, b.sublist(cut),
      lagDays: f.lagDays, grain: f.grain);
  if (first == null || second == null) return null;
  // Same sign in both halves, and at least half the headline size in each.
  final sameSign = first.r.sign == second.r.sign && first.r.sign == f.r.sign;
  final holds = first.r.abs() >= minAbsR / 2 && second.r.abs() >= minAbsR / 2;
  return (ok: sameSign && holds, first: first.r, second: second.r);
}
