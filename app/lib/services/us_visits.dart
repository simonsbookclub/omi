import 'package:flutter/services.dart';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): time outside. Thin wrapper over the native
/// VisitsService (AppDelegate.swift): configure the endpoint + bearer,
/// start/stop CoreLocation visit monitoring, read its status.
class UsVisits {
  static const _channel = MethodChannel('com.simonsbookclub.visits');

  static bool get enabled => SharedPreferencesUtil().getBool('usTrackOutside');

  /// Hand the native side where to post and how to authenticate. Cheap;
  /// call at startup and after sign-in so a rotated session still works.
  static Future<void> configure() async {
    try {
      final auth = await getAuthHeader();
      await _channel.invokeMethod('configure', {
        'endpoint': '${Env.apiBaseUrl}v1/us/visits',
        'auth': auth,
      });
    } catch (e) {
      Logger.debug('UsVisits.configure failed: $e');
    }
  }

  static Future<Map<String, dynamic>> start() async {
    SharedPreferencesUtil().saveBool('usTrackOutside', true);
    await configure();
    try {
      final r = await _channel.invokeMethod('start');
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      Logger.debug('UsVisits.start failed: $e');
      return {'enabled': false, 'authorization': 'error'};
    }
  }

  static Future<Map<String, dynamic>> stop() async {
    SharedPreferencesUtil().saveBool('usTrackOutside', false);
    try {
      final r = await _channel.invokeMethod('stop');
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      return {'enabled': false};
    }
  }

  static Future<Map<String, dynamic>> status() async {
    try {
      final r = await _channel.invokeMethod('status');
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      return {'enabled': false, 'authorization': 'unavailable'};
    }
  }
}
