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
import 'package:flutter/services.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/utils/logger.dart';

class LocalScribeSocket implements IPureSocket {
  static const MethodChannel _method = MethodChannel('com.simonsbookclub.scribe');
  static const EventChannel _segments = EventChannel('com.simonsbookclub.scribe/segments');

  final String sessionId;
  IPureSocketListener? _listener;
  StreamSubscription? _sub;
  PureSocketStatus _status = PureSocketStatus.notConnected;

  LocalScribeSocket({required this.sessionId});

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
      // Raw PCM16 from the pendant, the same bytes the relay used to get.
      _method.invokeMethod('audio', Uint8List.fromList(message)).catchError((e) {
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
