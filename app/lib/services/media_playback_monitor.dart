import 'dart:async';

import 'package:flutter/services.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB: watches whether this phone is playing audio through a
/// speaker the pendant can hear (a video, a voice note, music) and reports
/// each change so the relay can tag that speech as media instead of
/// treating it as people in the room.
///
/// Two consecutive polls must agree before a change is reported: a
/// notification chime does not open a window, a one-second pause in a video
/// does not close one. The native side (MediaPlaybackService in
/// AppDelegate.swift) already discounts headphones and phone calls.
class MediaPlaybackMonitor {
  static const _channel = MethodChannel('com.simonsbookclub.media');
  static const pollInterval = Duration(seconds: 2);

  final void Function(Map<String, dynamic> state) onChange;
  Timer? _timer;
  bool _reported = false;
  bool? _pendingState;
  int _pendingCount = 0;
  Map<String, dynamic>? _last;

  MediaPlaybackMonitor({required this.onChange});

  bool get isPlaying => _reported;
  Map<String, dynamic>? get lastStatus => _last;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
    _poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _reported = false;
    _pendingState = null;
    _pendingCount = 0;
  }

  /// The current state, for a socket that just (re)connected.
  Map<String, dynamic> snapshot() => _payload(_reported);

  Future<void> _poll() async {
    Map<String, dynamic>? status;
    try {
      final raw = await _channel.invokeMethod<Map>('status');
      if (raw != null) status = Map<String, dynamic>.from(raw);
    } catch (e) {
      Logger.debug('media monitor: status failed: $e');
      return;
    }
    if (status == null) return;
    _last = status;
    final audible = status['audible'] == true;
    if (audible == _reported) {
      _pendingState = null;
      _pendingCount = 0;
      return;
    }
    if (_pendingState == audible) {
      _pendingCount++;
    } else {
      _pendingState = audible;
      _pendingCount = 1;
    }
    if (_pendingCount >= 2) {
      _reported = audible;
      _pendingState = null;
      _pendingCount = 0;
      onChange(_payload(audible));
    }
  }

  Map<String, dynamic> _payload(bool playing) => {
        'type': 'media',
        'playing': playing,
        'audible': playing,
        'route': _last?['route'],
        'port': _last?['port'],
        'at': DateTime.now().toUtc().toIso8601String(),
      };
}
