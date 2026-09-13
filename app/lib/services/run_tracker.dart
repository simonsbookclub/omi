import 'package:flutter/services.dart';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB: the run in progress, from the phone's GPS. Thin wrapper
/// over the native RunTracker (RunTracker.swift): hand it the worker's base
/// URL and bearer once, and it does the rest — Core Motion decides when a
/// run starts and stops, CoreLocation supplies the points, batches go to
/// POST v1/run/live every thirty seconds, and the stats page follows.
class RunTracker {
  static const _channel = MethodChannel('com.simonsbookclub.run');

  /// Cheap; call at startup and after sign-in so a rotated session still
  /// works. Also where iOS asks for Always location and Motion & Fitness
  /// the first time.
  static Future<Map<String, dynamic>> configure() async {
    try {
      final token = (await getAuthHeader()).replaceFirst(RegExp(r'^Bearer\s+'), '');
      final r = await _channel.invokeMethod('configure', {
        'endpoint': Env.apiBaseUrl ?? '',
        'auth': token,
      });
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      Logger.debug('RunTracker.configure failed: $e');
      return {'location': 'error'};
    }
  }

  static Future<Map<String, dynamic>> status() async {
    try {
      final r = await _channel.invokeMethod('status');
      return Map<String, dynamic>.from(r as Map);
    } catch (_) {
      return {'location': 'error'};
    }
  }
}
