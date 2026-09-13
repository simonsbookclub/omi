import 'dart:async';
import 'package:flutter/services.dart';

import 'package:omi/backend/http/api/integrations.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';

class AppleHealthService {
  static const _channel = MethodChannel('com.omi.apple_health');

  static final AppleHealthService _instance = AppleHealthService._internal();
  factory AppleHealthService() => _instance;
  AppleHealthService._internal();

  /// Check if Apple Health is available on this platform
  bool get isAvailable => PlatformService.isApple;

  /// Check if the app has permission to access health data
  Future<bool> hasPermission() async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('hasPermission');
      return result == true;
    } catch (e) {
      Logger.debug('Error checking health permission: $e');
      return false;
    }
  }

  /// Request permission to access health data
  /// True while iOS still owes the user its sheet for the workout-route
  /// type. requestPermission's result says nothing about that.
  Future<bool> routeAuthorizationNeeded() async {
    if (!isAvailable) return false;
    try {
      return await _channel.invokeMethod('routeAuthorizationNeeded') == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPermission() async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('requestPermission');
      return result == true;
    } catch (e) {
      Logger.debug('Error requesting health permission: $e');
      return false;
    }
  }

  /// Probe for actual read access. HealthKit's `requestAuthorization` succeeds
  /// even when the user denies read permission (Apple hides read-auth status
  /// for privacy), so this queries several data types over the last 90 days and
  /// returns true only if at least one sample is readable — the only reliable
  /// way to distinguish allow from deny.
  Future<bool> probeAccess() async {
    if (!isAvailable) return false;

    try {
      final result = await _channel.invokeMethod('probeAccess');
      return result == true;
    } catch (e) {
      Logger.debug('Error probing health access: $e');
      return false;
    }
  }

  /// Get health summary data for the chat context
  /// Returns a map containing various health metrics
  Future<Map<String, dynamic>?> getHealthSummary({int days = 7}) async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getHealthSummary', {'days': days});

      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      Logger.debug('Error fetching health summary: $e');
      return null;
    }
  }

  /// Get step count for a specific date range
  Future<int?> getStepCount({DateTime? startDate, DateTime? endDate}) async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getStepCount', {
        'startDate': startDate?.millisecondsSinceEpoch,
        'endDate': endDate?.millisecondsSinceEpoch,
      });

      return result as int?;
    } catch (e) {
      Logger.debug('Error fetching step count: $e');
      return null;
    }
  }

  /// Get sleep data for a specific date range
  Future<Map<String, dynamic>?> getSleepData({DateTime? startDate, DateTime? endDate}) async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getSleepData', {
        'startDate': startDate?.millisecondsSinceEpoch,
        'endDate': endDate?.millisecondsSinceEpoch,
      });

      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      Logger.debug('Error fetching sleep data: $e');
      return null;
    }
  }

  /// Get heart rate data for a specific date range
  Future<Map<String, dynamic>?> getHeartRateData({DateTime? startDate, DateTime? endDate}) async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getHeartRateData', {
        'startDate': startDate?.millisecondsSinceEpoch,
        'endDate': endDate?.millisecondsSinceEpoch,
      });

      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } catch (e) {
      Logger.debug('Error fetching heart rate data: $e');
      return null;
    }
  }

  /// Get active energy burned for a specific date range
  Future<double?> getActiveEnergy({DateTime? startDate, DateTime? endDate}) async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getActiveEnergy', {
        'startDate': startDate?.millisecondsSinceEpoch,
        'endDate': endDate?.millisecondsSinceEpoch,
      });

      return (result as num?)?.toDouble();
    } catch (e) {
      Logger.debug('Error fetching active energy: $e');
      return null;
    }
  }

  /// Get workout data for a specific date range
  Future<List<Map<String, dynamic>>?> getWorkouts({DateTime? startDate, DateTime? endDate}) async {
    if (!isAvailable) return null;

    try {
      final result = await _channel.invokeMethod('getWorkouts', {
        'startDate': startDate?.millisecondsSinceEpoch,
        'endDate': endDate?.millisecondsSinceEpoch,
      });

      if (result is List) {
        return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return null;
    } catch (e) {
      Logger.debug('Error fetching workouts: $e');
      return null;
    }
  }

  /// SIMONSBOOKCLUB: granular timestamped samples (heart rate, HRV, resting
  /// HR, respiratory rate, SpO2, VO2max, hourly steps/energy, sleep stages,
  /// workouts) since a given time. Feeds the speech×body correlation.
  Future<List<Map<String, dynamic>>?> getSamples({required int sinceMs, List<String>? onlyTypes}) async {
    if (!isAvailable) return null;
    try {
      final result = await _channel.invokeMethod('getSamples', {
        'sinceMs': sinceMs.toDouble(),
        if (onlyTypes != null && onlyTypes.isNotEmpty) 'onlyTypes': onlyTypes,
      });
      if (result is List) {
        return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return null;
    } catch (e) {
      Logger.debug('Error fetching granular health samples: $e');
      return null;
    }
  }

  /// Push granular samples to the backend, chunked. First run reaches 30
  /// days back; after that, since the last successful sync (minus a day of
  /// overlap — HealthKit backfills late, e.g. sleep arrives on morning
  /// unlock, and the server dedupes). Throttled to once per hour.
  /// Hand the native side the base URL and token so HealthKit can wake the
  /// app and upload on its own. Without this the only push was opening the
  /// app, which left the desktop panel hours behind (2026-09-10).
  Future<bool> configureBackgroundSync() async {
    if (!isAvailable) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('configureBackgroundSync', {
        'baseUrl': Env.apiBaseUrl ?? '',
        // getAuthHeader returns the whole header value; the native side adds
        // its own "Bearer ".
        'token': (await getAuthHeader()).replaceFirst(RegExp(r'^Bearer\s+'), ''),
      });
      return ok ?? false;
    } catch (e) {
      Logger.debug('configureBackgroundSync failed: $e');
      return false;
    }
  }

  /// Types worth pulling over YEARS rather than a month.
  ///
  /// All sparse: a weigh-in or a run is a handful of rows a week, where heart
  /// rate is one every thirty seconds. A decade of these is a few thousand
  /// rows; a decade of heart rate would be millions, which is why the deep
  /// pull is an allowlist rather than a wider window on everything.
  static const deepBackfillTypes = <String>[
    'body_mass',
    'body_fat',
    'lean_mass',
    'vo2_max',
    'resting_heart_rate',
    'walking_heart_rate',
    'workout',
  ];

  /// Pull the full history of the sparse types, once.
  ///
  /// The routine sync has never reached further back than thirty days
  /// (`now - 30 * 24 * 60 * 60 * 1000` below), so years of weigh-ins and runs
  /// sitting in Apple Health had never been uploaded — the body-composition
  /// history in the database came from Hevy instead, and started in 2022.
  /// Runs older than a month were simply absent.
  ///
  /// Idempotent: the server keys on (type, start, end) and ignores duplicates,
  /// so a repeat costs bandwidth and nothing else.
  Future<bool> deepBackfill({int years = 12}) async {
    if (!isAvailable) return false;
    final prefs = SharedPreferencesUtil();
    final sinceMs = DateTime.now().subtract(Duration(days: 365 * years)).millisecondsSinceEpoch;
    Logger.debug('AppleHealth: deep backfill from ${DateTime.fromMillisecondsSinceEpoch(sinceMs)}');
    final samples = await getSamples(sinceMs: sinceMs, onlyTypes: deepBackfillTypes);
    if (samples == null || samples.isEmpty) {
      Logger.debug('AppleHealth: deep backfill returned nothing');
      return false;
    }
    var uploaded = 0;
    for (var i = 0; i < samples.length; i += 2000) {
      final chunk = samples.sublist(i, i + 2000 > samples.length ? samples.length : i + 2000);
      final ok = await syncAppleHealthSamples(chunk);
      if (!ok) {
        Logger.debug('AppleHealth: deep backfill chunk failed at $i of ${samples.length}');
        return false;
      }
      uploaded += chunk.length;
    }
    Logger.debug('AppleHealth: deep backfill uploaded $uploaded samples');
    await prefs.saveInt('healthDeepBackfillV1', 1);
    return true;
  }

  /// One-off (2026-09-13): re-export two years of workouts so their per-km
  /// splits are recomputed by the fixed native walk — the old one stamped
  /// every boundary inside a coarse distance sample with the sample's end,
  /// which read as a 12:21 first kilometre and 4:06s later on a steady run.
  /// The server updates a workout's meta on conflict, so this overwrites.
  static bool _reexportRunning = false;

  Future<bool> reexportWorkouts({int years = 2}) async {
    if (!isAvailable || _reexportRunning) return false;
    _reexportRunning = true;
    final prefs = SharedPreferencesUtil();
    final status = <String, dynamic>{'beacon': 'workout_reexport', 'reexport': 'started'};
    try {
      // The route is a new HealthKit read type: iOS shows its sheet once, for
      // that type only, and hands back nothing for it until it is allowed.
      // Ask, then check the sheet really was shown; until it has been, this
      // runs again on every foreground and never marks itself done.
      // Counted before ANY native call, so a crash anywhere in here still
      // counts: three strikes and this stops running on every launch
      // (2 = gave up). Waiting on the permission sheet is not a strike.
      final attempts = prefs.getInt('workoutSplitsV3Attempts');
      if (attempts >= 3) {
        await prefs.saveInt('workoutSplitsV3', 2);
        status['reexport'] = 'gave_up_after_$attempts';
        return false;
      }
      await prefs.saveInt('workoutSplitsV3Attempts', attempts + 1);
      status['attempt'] = attempts + 1;
      status['permission_prompt_ok'] = await requestPermission();
      final needed = await routeAuthorizationNeeded();
      status['route_auth_needed'] = needed;
      if (needed) {
        await prefs.saveInt('workoutSplitsV3Attempts', attempts);
        status['reexport'] = 'waiting_for_route_sheet';
        return false;
      }
      final sinceMs = DateTime.now().subtract(Duration(days: 365 * years)).millisecondsSinceEpoch;
      final samples = await getSamples(sinceMs: sinceMs, onlyTypes: const ['workout']);
      if (samples == null) {
        status['reexport'] = 'no_samples';
        return false;
      }
      var withRoute = 0;
      for (final s in samples) {
        if ((s['meta'] as String? ?? '').contains('"splits_source":"route"')) withRoute++;
      }
      status['workouts'] = samples.length;
      status['with_route'] = withRoute;
      for (var i = 0; i < samples.length; i += 500) {
        final chunk = samples.sublist(i, i + 500 > samples.length ? samples.length : i + 500);
        if (!await syncAppleHealthSamples(chunk)) {
          status['reexport'] = 'upload_failed_at_$i';
          return false;
        }
      }
      await prefs.saveInt('workoutSplitsV3', 1);
      status['reexport'] = 'ok';
      return true;
    } catch (e) {
      status['reexport'] = 'error';
      status['error'] = e.toString().substring(0, e.toString().length > 300 ? 300 : e.toString().length);
      return false;
    } finally {
      _reexportRunning = false;
      try {
        await syncAppleHealthData(status);
      } catch (_) {}
    }
  }

  Future<bool> syncGranularSamples({bool force = false}) async {
    if (!isAvailable) return false;
    final prefs = SharedPreferencesUtil();
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastRun = prefs.getInt('healthSamplesLastRunMs');
    // Was one hour. The desktop Vitals panel refreshes every minute and the
    // heart-rate graph is only as fresh as this push, so the throttle is the
    // real limit — not the polling. Ten minutes, with a narrower catch-up
    // window below so the upload stays small at that cadence.
    const throttleMs = 10 * 60 * 1000;
    // One-off (2026-09-13): per-km splits from the workout's GPS route.
    // Ahead of the throttle so it retries on every foreground until the
    // route permission sheet has been answered and the export has run.
    if (prefs.getInt('workoutSplitsV3') == 0) {
      unawaited(reexportWorkouts());
    }
    if (!force && now - lastRun < throttleMs) return false;

    // One-time full re-sync (v2): the first backfill truncated heart rate
    // to its oldest 20k samples (ascending sort + cap), losing the most
    // recent week. Refetch the full 30 days once under the fixed native
    // query; the server dedupes everything already stored.
    // v3 (2026-09-05): Time in Daylight, exercise minutes and workout
    // heart-rate stats were added — refetch thirty days once so the new
    // types have history (idempotent inserts on the server).
    final needsFullResyncV2 = prefs.getInt('healthFullResyncV3') == 0;
    // One-time deep pull of the sparse types. Fire-and-forget so it never
    // delays or fails the routine sync it rides along with.
    if (prefs.getInt('healthDeepBackfillV1') == 0) {
      unawaited(deepBackfill());
    }
    final lastSynced = prefs.getInt('healthSamplesSyncedToMs');
    // The 24-hour overlap catches samples the watch delivers late. At a
    // ten-minute cadence that would re-upload the same day over and over, so
    // only the first sync of each hour reaches that far back; the rest carry
    // a three-hour tail, which is ample for a watch that is on the wrist.
    final wideCatchUp = now - lastRun >= 60 * 60 * 1000;
    final overlapMs = wideCatchUp ? 24 * 60 * 60 * 1000 : 3 * 60 * 60 * 1000;
    final sinceMs = (!needsFullResyncV2 && lastSynced > 0)
        ? lastSynced - overlapMs
        : now - 30 * 24 * 60 * 60 * 1000;

    // Release builds have no visible logging, so this sync reports its own
    // outcome to the backend (the snapshot endpoint stores arbitrary JSON)
    // — that beacon is the only way to see WHY a sync produced nothing.
    final status = <String, dynamic>{'granular_status': 'started', 'since_ms': sinceMs};
    try {
      // Ask for authorization first: iOS shows the sheet only for types the
      // user hasn't been asked about yet (e.g. after we add new HealthKit
      // types), and is completely silent otherwise. Without this, a user who
      // connected under the old, smaller type set never gets asked for the
      // new types and their samples silently come back empty.
      status['permission_prompt_ok'] = await requestPermission();

      final samples = await getSamples(sinceMs: sinceMs);
      prefs.saveInt('healthSamplesLastRunMs', now);
      status['sample_count'] = samples?.length ?? -1;
      if (samples != null && samples.isNotEmpty) {
        final byType = <String, int>{};
        for (final s in samples) {
          final t = s['type'] as String? ?? '?';
          byType[t] = (byType[t] ?? 0) + 1;
        }
        status['by_type'] = byType;
      }

      if (samples == null || samples.isEmpty) {
        status['granular_status'] = 'no_samples';
        return false;
      }

      const chunkSize = 2000;
      for (var i = 0; i < samples.length; i += chunkSize) {
        final chunk = samples.sublist(i, i + chunkSize > samples.length ? samples.length : i + chunkSize);
        final ok = await syncAppleHealthSamples(chunk);
        if (!ok) {
          status['granular_status'] = 'upload_failed_at_chunk_${i ~/ chunkSize}';
          return false;
        }
      }
      prefs.saveInt('healthSamplesSyncedToMs', now);
      prefs.saveInt('healthFullResyncV2', 1);
      prefs.saveInt('healthFullResyncV3', 1);
      status['granular_status'] = 'ok';
      return true;
    } catch (e) {
      status['granular_status'] = 'error';
      status['error'] = e.toString().substring(0, e.toString().length > 300 ? 300 : e.toString().length);
      return false;
    } finally {
      try {
        await syncAppleHealthData(status);
      } catch (_) {}
    }
  }

  /// Connect to Apple Health with automatic permission handling
  Future<AppleHealthResult> connect() async {
    if (!isAvailable) {
      return AppleHealthResult.unsupported;
    }

    final promptShown = await requestPermission();
    if (!promptShown) {
      return AppleHealthResult.permissionDenied;
    }

    // HealthKit's request callback returns true whether the user allowed or
    // denied read access, so verify by probing for actual data.
    final canRead = await probeAccess();
    if (!canRead) {
      return AppleHealthResult.permissionDenied;
    }

    return AppleHealthResult.success;
  }

  /// Sync health data to the backend
  /// This fetches all available health data and sends it to the server
  Future<bool> syncHealthDataToBackend({int days = 7}) async {
    if (!isAvailable) return false;

    try {
      // Get health summary which contains all the data
      final summary = await getHealthSummary(days: days);

      if (summary == null) {
        Logger.debug('No health summary data available');
        return false;
      }

      // Build the request body matching the backend schema
      final requestData = <String, dynamic>{'period_days': days};

      // Steps
      if (summary['totalSteps'] != null) {
        requestData['total_steps'] = summary['totalSteps'];
        requestData['average_steps_per_day'] = summary['averageStepsPerDay'];
      }

      // Daily steps breakdown
      if (summary['dailySteps'] != null) {
        requestData['daily_steps'] = summary['dailySteps'];
      }

      // Sleep
      final sleep = summary['sleep'];
      if (sleep != null) {
        requestData['total_sleep_hours'] = sleep['totalSleepHours'];
        requestData['total_in_bed_hours'] = sleep['totalInBedHours'];
        requestData['sleep_sessions_count'] = sleep['sessionsCount'];
        requestData['sleep_sessions'] = sleep['sessions'];
        requestData['daily_sleep'] = sleep['daily']; // Daily breakdown
      }

      // Heart rate
      final heartRate = summary['heartRate'];
      if (heartRate != null) {
        requestData['heart_rate_average'] = heartRate['average'];
        requestData['heart_rate_min'] = heartRate['minimum'];
        requestData['heart_rate_max'] = heartRate['maximum'];
      }

      // Active energy
      if (summary['totalActiveEnergy'] != null) {
        requestData['total_active_energy'] = summary['totalActiveEnergy'];
        requestData['average_active_energy_per_day'] = summary['averageActiveEnergyPerDay'];
        requestData['daily_active_energy'] = summary['dailyActiveEnergy']; // Daily breakdown
      }

      // Workouts
      if (summary['workouts'] != null) {
        requestData['workouts'] = summary['workouts'];
      }

      // Send to backend
      final success = await syncAppleHealthData(requestData);
      if (success) {
        Logger.debug('Successfully synced Apple Health data to backend');
      }
      return success;
    } catch (e) {
      Logger.debug('Error syncing health data to backend: $e');
      return false;
    }
  }
}

enum AppleHealthResult { success, failed, permissionDenied, unsupported }

extension AppleHealthResultExtension on AppleHealthResult {
  String get message {
    switch (this) {
      case AppleHealthResult.success:
        return 'Connected to Apple Health';
      case AppleHealthResult.failed:
        return 'Failed to connect to Apple Health';
      case AppleHealthResult.permissionDenied:
        return 'Permission denied for Apple Health';
      case AppleHealthResult.unsupported:
        return 'Apple Health not available';
    }
  }

  bool get isSuccess => this == AppleHealthResult.success;
}
