import 'package:flutter/foundation.dart';

import 'package:omi/backend/http/api/us.dart';
import 'package:omi/services/us_session.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): state for the Us tab — today's card, the couple,
/// pending prompts, history and the weekly report. Refreshed on open, on
/// foreground, and when the listen socket delivers a us_* event.
class UsProvider extends ChangeNotifier {
  Map<String, dynamic>? today;
  Map<String, dynamic>? history;
  Map<String, dynamic>? weekly;
  Map<String, dynamic>? account;
  List<Map<String, dynamic>> protocols = [];
  bool loading = false;
  String? error;
  DateTime? _lastRefresh;

  /// A prompt the socket just delivered, for the sheet to show once.
  Map<String, dynamic>? incomingPrompt;

  Map<String, dynamic>? get couple => today?['couple'] as Map<String, dynamic>?;
  Map<String, dynamic>? get card => today?['card'] as Map<String, dynamic>?;
  String get coupleState => (couple?['state'] ?? 'none').toString();
  bool get isLive => coupleState == 'live';
  List<Map<String, dynamic>> get prompts =>
      ((today?['prompts'] as List?) ?? const []).cast<Map<String, dynamic>>();

  Future<void> refresh({bool force = false, bool card = false}) async {
    if (!force && _lastRefresh != null && DateTime.now().difference(_lastRefresh!) < const Duration(seconds: 20)) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      await UsSession.ensureSession();
      final t = await UsApi.today(refresh: card);
      if (t != null && t['error'] != null) {
        error = t['error'].toString();
      } else if (t != null) {
        today = t;
      }
      if (isLive) {
        final h = await UsApi.history(days: 28);
        if (h != null && h['error'] == null) history = h;
      }
      if (protocols.isEmpty) {
        final p = await UsApi.protocols();
        if (p != null && p['protocols'] is List) protocols = (p['protocols'] as List).cast<Map<String, dynamic>>();
      }
      _lastRefresh = DateTime.now();
    } catch (e) {
      error = e.toString();
      Logger.debug('UsProvider.refresh failed: $e');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadWeekly({bool refresh = false}) async {
    final w = await UsApi.weekly(refresh: refresh);
    if (w != null && w['error'] == null) {
      weekly = w;
      notifyListeners();
    }
  }

  Future<void> loadAccount() async {
    final a = await UsApi.me();
    if (a != null && a['error'] == null) {
      account = a;
      notifyListeners();
    }
  }

  /// Called by the capture controller when a us_* frame arrives.
  void onSocketEvent(String type, Map<String, dynamic> payload) {
    if (type == 'us_prompt') {
      incomingPrompt = payload;
    }
    _lastRefresh = null;
    notifyListeners();
    refresh(force: true);
  }

  void consumeIncomingPrompt() {
    incomingPrompt = null;
  }

  Future<String?> createInvite() async {
    final r = await UsApi.invite();
    if (r == null || r['error'] != null) return r?['error']?.toString() ?? 'Could not create a code.';
    await refresh(force: true);
    return null;
  }

  Future<String?> acceptInvite(String code) async {
    final r = await UsApi.accept(code);
    if (r == null || r['error'] != null) return r?['error']?.toString() ?? 'Could not join.';
    await refresh(force: true, card: true);
    return null;
  }

  Future<void> setPaused(bool paused) async {
    await UsApi.pause(paused);
    await refresh(force: true);
  }

  Future<void> endCouple() async {
    await UsApi.endCouple();
    today = null;
    history = null;
    weekly = null;
    await refresh(force: true);
  }

  Future<void> setSharing(String key, bool value) async {
    await UsApi.sharing({key: value});
    await refresh(force: true);
  }

  Future<void> logPeriodStarted({String? day}) async {
    await UsApi.logPeriod(startedOn: day);
    await refresh(force: true, card: true);
  }

  Future<void> answerPostConflict(int promptId, String conversationId, {required bool wasConflict, bool? resolved}) async {
    await UsApi.label(conversationId, wasConflict: wasConflict, resolved: resolved);
    await UsApi.answerPrompt(promptId);
    await refresh(force: true, card: true);
  }

  Future<void> dismissPrompt(int promptId) async {
    await UsApi.dismissPrompt(promptId);
    await refresh(force: true);
  }

  Future<void> protocolEvent(String protocolId, String status, {String? trigger, String? conversationId}) async {
    await UsApi.protocolEvent(protocolId, status, trigger: trigger, conversationId: conversationId);
    await refresh(force: true);
  }
}
