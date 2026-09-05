import 'dart:convert';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): the couple early-warning API on the pendant
/// worker — /omi/v1/us/* (src/us-routes.ts). Every call carries the
/// Chronicle session (or the owner token) through makeApiCall.
class UsApi {
  static String get _base => '${Env.apiBaseUrl}v1/us';

  static Future<Map<String, dynamic>?> _call(String method, String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await makeApiCall(
        url: '$_base/$path',
        headers: {},
        method: method,
        body: body == null ? '' : jsonEncode(body),
      );
      if (res == null) return null;
      final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        if (res.statusCode >= 400) {
          decoded['_status'] = res.statusCode;
          decoded['error'] ??= 'Request failed (${res.statusCode})';
        }
        return decoded;
      }
      return {'data': decoded};
    } catch (e) {
      Logger.debug('UsApi $method $path failed: $e');
      return {'error': 'Network error: $e'};
    }
  }

  static Future<Map<String, dynamic>?> me() => _call('GET', 'me');
  static Future<Map<String, dynamic>?> updateMe({String? givenName, String? timezone}) =>
      _call('PATCH', 'me', body: {if (givenName != null) 'given_name': givenName, if (timezone != null) 'timezone': timezone});
  static Future<Map<String, dynamic>?> signOut() => _call('POST', 'signout', body: {});
  static Future<Map<String, dynamic>?> ouraLinkUrl() => _call('GET', 'oura/link');
  static Future<Map<String, dynamic>?> ouraSync() => _call('POST', 'oura/sync', body: {});
  static Future<Map<String, dynamic>?> ouraUnlink() => _call('DELETE', 'oura');
  static Future<Map<String, dynamic>?> claimVoice(String personName) => _call('POST', 'voice', body: {'person_name': personName});
  static Future<Map<String, dynamic>?> voices() => _call('GET', 'voices');

  static Future<Map<String, dynamic>?> couple() => _call('GET', 'couple');
  static Future<Map<String, dynamic>?> invite() => _call('POST', 'couple/invite', body: {});
  static Future<Map<String, dynamic>?> accept(String code) => _call('POST', 'couple/accept', body: {'code': code});
  static Future<Map<String, dynamic>?> pause(bool paused) => _call('POST', 'couple/pause', body: {'paused': paused});
  static Future<Map<String, dynamic>?> endCouple() => _call('DELETE', 'couple');
  static Future<Map<String, dynamic>?> sharing(Map<String, bool> patch) => _call('PATCH', 'couple/sharing', body: patch);

  static Future<Map<String, dynamic>?> cycle() => _call('GET', 'cycle');
  static Future<Map<String, dynamic>?> logPeriod({String? startedOn}) =>
      _call('POST', 'cycle/period', body: {if (startedOn != null) 'started_on': startedOn, 'source': 'app'});
  static Future<Map<String, dynamic>?> deletePeriod(String startedOn) => _call('DELETE', 'cycle/period?started_on=$startedOn');

  static Future<Map<String, dynamic>?> today({bool refresh = false}) => _call('GET', refresh ? 'today?refresh=1' : 'today');
  static Future<Map<String, dynamic>?> history({int days = 28}) => _call('GET', 'history?days=$days');
  static Future<Map<String, dynamic>?> weekly({bool refresh = false}) => _call('GET', refresh ? 'weekly?refresh=1' : 'weekly');

  static Future<Map<String, dynamic>?> setScope(String conversationId, String? override) =>
      _call('POST', 'conversations/$conversationId/scope', body: {'override': override});
  static Future<Map<String, dynamic>?> setHard(String conversationId, bool? hard) =>
      _call('POST', 'conversations/$conversationId/hard', body: {'hard': hard});
  static Future<Map<String, dynamic>?> label(String conversationId, {bool? wasConflict, bool? resolved, String? note}) =>
      _call('POST', 'conversations/$conversationId/label', body: {
        if (wasConflict != null) 'was_conflict': wasConflict,
        if (resolved != null) 'resolved': resolved,
        if (note != null) 'note': note,
      });

  static Future<Map<String, dynamic>?> dismissPrompt(int id) => _call('POST', 'prompts/$id/dismiss', body: {});
  static Future<Map<String, dynamic>?> answerPrompt(int id) => _call('POST', 'prompts/$id/answer', body: {});
  static Future<Map<String, dynamic>?> protocols() => _call('GET', 'protocols');
  static Future<Map<String, dynamic>?> protocolEvent(String protocolId, String status, {String? trigger, String? conversationId}) =>
      _call('POST', 'protocols/$protocolId/$status', body: {
        if (trigger != null) 'trigger': trigger,
        if (conversationId != null) 'conversation_id': conversationId,
      });
}
