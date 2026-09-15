// A transcription "socket" that never opens one.
//
// Everywhere upstream — CompositeTranscriptionSocket, CaptureController, the
// backend's listen socket — expects something it can send PCM to and receive
// `{"segments":[…]}` from. That contract is all the relay ever was, so Scribe
// can stand in its place: the frames go to the phone's own engine (Parakeet
// for the words, a diarizer for the turns, a voiceprint match for the name)
// and the same JSON comes back. Nothing above this file knows the difference,
// and no audio leaves the device.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/audio/audio_transcoder.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/utils/logger.dart';

class LocalScribeSocket implements IPureSocket {
  static const MethodChannel _method = MethodChannel('com.simonsbookclub.scribe');
  static const EventChannel _segments = EventChannel('com.simonsbookclub.scribe/segments');

  final String sessionId;
  /// The pendant sends Opus; the engine wants 16-bit PCM. The relay socket did
  /// this conversion inside itself, so it has to happen here too — without it
  /// Scribe would be handed compressed bytes and read them as samples.
  final IAudioTranscoder _toPcm;
  IPureSocketListener? _listener;
  StreamSubscription? _sub;
  PureSocketStatus _status = PureSocketStatus.notConnected;

  LocalScribeSocket({
    required this.sessionId,
    required BleAudioCodec codec,
    required int sampleRate,
  }) : _toPcm = AudioTranscoderFactory.createToRawPcm(sourceCodec: codec, sampleRate: sampleRate);

  @override
  PureSocketStatus get status => _status;

  @override
  void setListener(IPureSocketListener listener) => _listener = listener;

  @override
  Future<bool> connect() async {
    try {
      _status = PureSocketStatus.connecting;
      // The first call downloads the models; afterwards it is a few hundred ms.
      await _method.invokeMethod('start', {'sessionId': sessionId});
      // Give the phone the enrolled voices before any audio arrives, so the
      // first utterance can already carry a name.
      unawaited(_loadVoiceprints());
      _sub = _segments.receiveBroadcastStream().listen(
        (event) => onMessage(event),
        onError: (e, t) => onError(e, t is StackTrace ? t : StackTrace.current),
      );
      _status = PureSocketStatus.connected;
      onConnected();
      Logger.log('[Scribe] engine ready, session $sessionId');
      return true;
    } catch (e, t) {
      _status = PureSocketStatus.notConnected;
      Logger.error('[Scribe] failed to start: $e');
      onError(e, t);
      return false;
    }
  }

  @override
  void send(dynamic message) {
    if (_status != PureSocketStatus.connected) return;
    if (message is List<int>) {
      final pcm = _toPcm.transcode(Uint8List.fromList(message));
      if (pcm.isEmpty) return;
      _method.invokeMethod('audio', pcm).catchError((e) {
        Logger.error('[Scribe] audio rejected: $e');
        return null;
      });
      return;
    }
    // Control frames. Only the media signal means anything here; CloseStream
    // and KeepAlive exist for a socket that isn't one.
    final text = message.toString();
    if (text.contains('"type":"media"')) {
      final playing = text.contains('"playing":true');
      _method.invokeMethod('media', {'playing': playing}).catchError((_) => null);
    }
  }

  /// Fetch the enrolled voices from our own worker and hand them to the engine.
  /// These are WeSpeaker vectors, the space the phone's diarizer works in.
  static Future<void> _loadVoiceprints() async {
    try {
      final res = await makeApiCall(
        url: '${Env.apiBaseUrl}v1/voices/prints',
        headers: {},
        body: '',
        method: 'GET',
      );
      if (res == null || res.statusCode != 200) {
        Logger.log('[Scribe] no voiceprints (${res?.statusCode}); voices stay unnamed');
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final prints = (body['prints'] as List? ?? [])
          .map((p) => {
                'name': p['name'],
                'centroid': (p['centroid'] as List).map((v) => (v as num).toDouble()).toList(),
                'count': p['count'] ?? 1,
              })
          .toList();
      if (prints.isEmpty) return;
      await setVoiceprints(prints.cast<Map<String, dynamic>>());
      Logger.log('[Scribe] ${prints.length} voiceprint(s) loaded: ${prints.map((p) => p['name']).join(', ')}');
    } catch (e) {
      Logger.error('[Scribe] voiceprint fetch failed: $e');
    }
  }

  /// Hand the phone the voices the worker knows about, so it can put names on
  /// turns without asking anything.
  static Future<void> setVoiceprints(List<Map<String, dynamic>> prints) async {
    try {
      await _method.invokeMethod('setVoiceprints', {'prints': prints});
    } catch (e) {
      Logger.error('[Scribe] could not set voiceprints: $e');
    }
  }

  static Future<Map<dynamic, dynamic>> enrolledVoices() async {
    try {
      return await _method.invokeMethod('enrolledVoices') ?? {};
    } catch (_) {
      return {};
    }
  }

  @override
  Future disconnect() async => stop();

  @override
  Future stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    _status = PureSocketStatus.disconnected;
    onClosed();
  }

  @override
  void onMessage(dynamic message) => _listener?.onMessage(message);

  @override
  void onConnected() => _listener?.onConnected();

  @override
  void onClosed() => _listener?.onClosed();

  @override
  void onError(Object err, StackTrace trace) => _listener?.onError(err, trace);
}
