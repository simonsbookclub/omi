import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): the Chronicle session — an opaque 90-day token
/// minted by the worker after Sign in with Apple, Oura OAuth, or the owner
/// shortcut (a build that carries the static OMI_NATIVE_TOKEN trades it for
/// a real session so linking a ring attaches to the right person).
///
/// Stored in SharedPreferences next to the legacy uid; auth_service.dart's
/// gateway reads it first and falls back to the static build token.
class UsSession {
  static String get token => SharedPreferencesUtil().getString('usSessionToken');
  static String get userId => SharedPreferencesUtil().getString('usUserId');
  static String get userName => SharedPreferencesUtil().getString('usUserName');
  static bool get hasSession => token.isNotEmpty;

  /// Origin of the worker (Env.apiBaseUrl is the /omi/ prefix).
  static String get origin {
    final base = Env.apiBaseUrl ?? 'https://pendant.output.social/omi/';
    return Uri.parse(base).origin;
  }

  static Future<void> save({required String token, required String userId, String? name}) async {
    final prefs = SharedPreferencesUtil();
    await prefs.saveString('usSessionToken', token);
    await prefs.saveString('usUserId', userId);
    if (name != null && name.trim().isNotEmpty) {
      await prefs.saveString('usUserName', name.trim());
      prefs.givenName = name.trim();
    }
    prefs.uid = userId;
    // The HTTP layer caches the bearer; make it re-read from the gateway.
    prefs.authToken = '';
    prefs.tokenExpirationTime = 0;
  }

  static Future<void> clear() async {
    final prefs = SharedPreferencesUtil();
    await prefs.saveString('usSessionToken', '');
    await prefs.saveString('usUserId', '');
    await prefs.saveString('usUserName', '');
    prefs.authToken = '';
    prefs.tokenExpirationTime = 0;
  }

  /// A build with the static owner token but no session yet: mint one so
  /// account actions (link Oura, claim a voice) land on 'simon'.
  static Future<bool> ensureSession() async {
    if (hasSession) return true;
    if (Env.nativeBackendToken.isEmpty) return false;
    try {
      final res = await http.post(
        Uri.parse('$origin/auth/owner'),
        headers: {'Authorization': 'Bearer ${Env.nativeBackendToken}', 'Content-Type': 'application/json'},
        body: jsonEncode({'device': 'owner-phone'}),
      );
      if (res.statusCode != 200) {
        Logger.debug('UsSession.ensureSession: ${res.statusCode} ${res.body}');
        return false;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final user = data['user'] as Map<String, dynamic>?;
      await save(token: data['token'] as String, userId: (user?['id'] ?? Env.nativeBackendUid) as String, name: user?['given_name'] as String?);
      return true;
    } catch (e) {
      Logger.debug('UsSession.ensureSession failed: $e');
      return false;
    }
  }

  /// Sign in with Apple: hand Apple's identity token to the worker.
  static Future<String?> signInWithApple({required String identityToken, String? givenName, String? link}) async {
    try {
      final res = await http.post(
        Uri.parse('$origin/auth/apple'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identity_token': identityToken,
          if (givenName != null && givenName.isNotEmpty) 'given_name': givenName,
          if (link != null && link.isNotEmpty) 'link': link,
          'device': 'iphone',
        }),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) return (data['error'] ?? 'Sign-in failed (${res.statusCode})').toString();
      final user = data['user'] as Map<String, dynamic>?;
      await save(token: data['token'] as String, userId: (user?['id'] ?? '') as String, name: (user?['given_name'] as String?) ?? givenName);
      return null;
    } catch (e) {
      return 'Sign-in failed: $e';
    }
  }

  /// The browser came back with chronicle://auth?token=…&user=… (or ?error=).
  static Future<String?> handleAuthCallback(Uri uri) async {
    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) return error;
    final token = uri.queryParameters['token'];
    final user = uri.queryParameters['user'];
    if (token == null || token.isEmpty || user == null || user.isEmpty) return 'The sign-in link was incomplete.';
    await save(token: token, userId: user);
    return null;
  }
}
