import 'package:flutter/services.dart';

import 'package:omi/backend/http/api/integrations.dart';
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
  Future<List<Map<String, dynamic>>?> getSamples({required int sinceMs}) async {
    if (!isAvailable) return null;
    try {
      final result = await _channel.invokeMethod('getSamples', {'sinceMs': sinceMs.toDouble()});
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
  Future<bool> syncGranularSamples({bool force = false}) async {
    if (!isAvailable) return false;
    final prefs = SharedPreferencesUtil();
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastRun = prefs.getInt('healthSamplesLastRunMs');
    if (!force && now - lastRun < 60 * 60 * 1000) return false;

    final lastSynced = prefs.getInt('healthSamplesSyncedToMs');
    final sinceMs = lastSynced > 0 ? lastSynced - 24 * 60 * 60 * 1000 : now - 30 * 24 * 60 * 60 * 1000;

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
