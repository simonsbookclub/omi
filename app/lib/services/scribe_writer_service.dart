// Titles and the read on a conversation, written by this phone.
//
// When a conversation finishes, the worker used to pay a model on Cloudflare to
// name it and score it. Apple's on-device model does both for nothing, offline,
// and without the transcript leaving the device. Only the results go up, into
// the same columns the cron was filling — and the version markers there stop it
// re-doing the work.
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

class ScribeWriterService {
  static const MethodChannel _method = MethodChannel('com.simonsbookclub.scribe');
  static bool? _available;

  /// Cached: the answer cannot change while the app is running.
  static Future<bool> get available async {
    if (_available != null) return _available!;
    try {
      _available = await _method.invokeMethod<bool>('writerAvailable') ?? false;
    } catch (_) {
      _available = false;
    }
    if (_available == false) Logger.log('[ScribeWriter] no on-device model; the worker keeps writing titles');
    return _available!;
  }

  /// Read a finished conversation and send up what the phone made of it.
  /// Best effort throughout: a failure here costs a nicer title, never the
  /// conversation itself.
  static Future<void> describe(ServerConversation conversation) async {
    if (!await available) return;
    final transcript = conversation.transcriptSegments
        .where((s) => !s.media && s.text.trim().isNotEmpty)
        .map((s) => '${s.isUser ? 'Me' : (s.personId ?? s.speaker)}: ${s.text.trim()}')
        .join('\n');
    if (transcript.split(RegExp(r'\s+')).length < 25) return; // too little to describe

    final payload = <String, dynamic>{};
    payload['structured'] = await _ask('structured', transcript);
    payload['sentiment'] = await _ask('sentiment', transcript);
    payload['relationship'] = await _ask('relationship', transcript);
    payload.removeWhere((_, v) => v == null);
    if (payload.isEmpty) return;

    try {
      final res = await makeApiCall(
        url: '${Env.apiBaseUrl}v1/conversations/${conversation.id}/analysis',
        headers: {'Content-Type': 'application/json'},
        method: 'POST',
        body: jsonEncode(payload),
      );
      if (res?.statusCode == 200) {
        Logger.log('[ScribeWriter] wrote ${payload.keys.join(', ')} for ${conversation.id}');
      } else {
        Logger.error('[ScribeWriter] worker refused: ${res?.statusCode}');
      }
    } catch (e) {
      Logger.error('[ScribeWriter] could not send: $e');
    }
  }

  static Future<Map<String, dynamic>?> _ask(String want, String transcript) async {
    try {
      final r = await _method.invokeMethod('summarise', {'want': want, 'transcript': transcript});
      if (r is Map) return Map<String, dynamic>.from(r);
      return null;
    } catch (e) {
      Logger.error('[ScribeWriter] $want failed: $e');
      return null;
    }
  }
}
