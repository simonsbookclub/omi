// Drained flash recordings, read on this phone instead of uploaded.
//
// The pendant records to its own storage whenever the Bluetooth link is down,
// and the phone later ships those files off to be transcribed. This does the
// work here: the app's existing Opus decoder turns each .bin into a WAV, the
// Scribe engine diarizes and transcribes it, and only the resulting text and
// names go to our worker. The audio never leaves the phone and is deleted the
// moment it has been read.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/audio/audio_transcoder.dart';
import 'package:omi/utils/logger.dart';

class ScribeDrainResult {
  final bool ok;
  final String? conversationId;
  final int segments;
  final String? error;
  const ScribeDrainResult({required this.ok, this.conversationId, this.segments = 0, this.error});
}

class ScribeDrain {
  static const MethodChannel _method = MethodChannel('com.simonsbookclub.scribe');

  /// One WAL file: decode, read, post, delete. Returns what the worker made of it.
  static Future<ScribeDrainResult> process(Wal wal, File file) async {
    File? wav;
    try {
      final transcoder = OpusFramesToWavTranscoder(
        sampleRate: wal.sampleRate,
        channels: wal.channel,
        frameSizeBytes: wal.codec == BleAudioCodec.opusFS320 ? 160 : 80,
      );
      final bytes = await file.readAsBytes();
      final wavBytes = transcoder.transcode(bytes);
      if (wavBytes.isEmpty) {
        return const ScribeDrainResult(ok: false, error: 'could not decode');
      }
      wav = File('${file.path}.wav');
      await wav.writeAsBytes(wavBytes, flush: true);

      final stream = 'device:${wal.id}';
      final raw = await _method.invokeMethod<String>('processFile', {
        'wavPath': wav.path,
        'stream': stream,
      });
      final segments = (jsonDecode(raw ?? '[]') as List).cast<Map<String, dynamic>>();
      if (segments.isEmpty) {
        // Genuinely silent. Tell the worker so it stops expecting this file,
        // exactly as the old server-side path recorded silence.
        await _post(wal, stream, const []);
        return const ScribeDrainResult(ok: true, segments: 0);
      }
      final id = await _post(wal, stream, segments);
      Logger.log('[ScribeDrain] ${wal.id}: ${segments.length} segments on device');
      return ScribeDrainResult(ok: true, conversationId: id, segments: segments.length);
    } catch (e) {
      Logger.error('[ScribeDrain] ${wal.id} failed: $e');
      return ScribeDrainResult(ok: false, error: '$e');
    } finally {
      if (wav != null && await wav.exists()) {
        await wav.delete().catchError((_) => wav!);
      }
    }
  }

  static Future<String?> _post(Wal wal, String stream, List<Map<String, dynamic>> segments) async {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(wal.timerStart * 1000, isUtc: true);
    final res = await makeApiCall(
      url: '${Env.apiBaseUrl}v1/device/drain',
      headers: {'Content-Type': 'application/json'},
      method: 'POST',
      body: jsonEncode({
        'file_name': wal.getFileName(),
        'stream': stream,
        'started_at': startedAt.toIso8601String(),
        'seconds': wal.seconds,
        'segments': segments,
      }),
    );
    if (res == null || res.statusCode != 200) {
      throw Exception('worker rejected the drain: ${res?.statusCode} ${res?.body.substring(0, 120)}');
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['conversation_id'] as String?;
  }
}
