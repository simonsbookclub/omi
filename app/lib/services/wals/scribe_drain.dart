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
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
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
      // The file is a run of Opus frames, each preceded by its length as
      // four little-endian bytes — the layout the worker's parseFrames reads.
      // The first version sliced it into fixed 160-byte pieces instead and
      // decoded garbage; 37 of 39 recordings came back "silent" (2026-09-15).
      final bytes = await file.readAsBytes();
      final frames = _frames(bytes);
      if (frames.isEmpty) {
        return const ScribeDrainResult(ok: false, error: 'no frames in file');
      }
      // Only Opus goes through the Opus decoder. A pcm16 recording fed to it
      // fails on every frame, produces an empty WAV, and would then be posted
      // as "silent" and the .bin deleted — the whole backlog of such a device
      // destroyed in one pass.
      if (!wal.codec.isOpusSupported()) {
        return ScribeDrainResult(ok: false, error: 'not opus (${wal.codec})');
      }
      final decoder = SimpleOpusDecoder(sampleRate: wal.sampleRate, channels: wal.channel);
      final pcm = <int>[];
      var decoded = 0;
      for (final f in frames) {
        try {
          pcm.addAll(decoder.decode(input: f));
          decoded++;
        } catch (_) {
          // one bad frame is normal; all of them is not
        }
      }
      // "Nothing decoded" is a broken file, never silence. Reporting it as
      // silence is how 37 of 39 recordings were written off this morning.
      if (decoded == 0) {
        return ScribeDrainResult(ok: false, error: 'no frames decoded of ${frames.length}');
      }
      if (decoded < frames.length * 0.5) {
        Logger.error('[ScribeDrain] ${wal.id}: only $decoded of ${frames.length} frames decoded');
      }
      final wavBytes = WavBytesUtil.getUInt8ListBytes(pcm, wal.sampleRate);
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

  static List<Uint8List> _frames(Uint8List bytes) {
    final out = <Uint8List>[];
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + 4 <= bytes.length) {
      final len = view.getUint32(offset, Endian.little);
      offset += 4;
      if (len <= 0 || offset + len > bytes.length) break; // corrupt or truncated tail
      out.add(Uint8List.sublistView(bytes, offset, offset + len));
      offset += len;
    }
    return out;
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
      final body = res?.body ?? '';
      throw Exception('worker rejected the drain: ${res?.statusCode} ${body.substring(0, body.length < 200 ? body.length : 200)}');
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['conversation_id'] as String?;
  }
}
