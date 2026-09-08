import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as socket_channel_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_manager.dart';

enum PureSocketStatus { notConnected, connecting, connected, disconnected }

abstract class IPureSocketListener {
  void onConnected();
  void onMessage(dynamic message);
  void onClosed([int? closeCode]);
  void onError(Object err, StackTrace trace);
}

abstract class IPureSocket {
  PureSocketStatus get status;

  Future<bool> connect();
  Future disconnect();
  Future stop();
  void send(dynamic message);

  void setListener(IPureSocketListener listener);

  void onMessage(dynamic message);
  void onConnected();
  void onClosed();
  void onError(Object err, StackTrace trace);
}

class PureSocketMessage {
  String? raw;
}

typedef SocketHeadersProvider = Future<Map<String, String>> Function();

/// Audio frames handed to [PureSocket.send] while the socket is down used
/// to be dropped on the floor, because `send` is `_channel?.sink.add(...)`
/// and `_channel` is null between connections.
///
/// That silently ate the beginning of speech after every quiet stretch. Live
/// on 2026-09-08: the pendant sent nothing for minutes while Simon read, the
/// audio watchdog dropped the socket at 19:54:03, and the wake word he spoke
/// before reading a passage aloud landed in the two seconds before the new
/// socket and Deepgram were up. The transcript began mid-sentence and no
/// command ever ran.
///
/// Frames are now held while the socket is away and flushed in order on
/// connect. Bounded by bytes AND age, because replaying minutes-old audio
/// into a fresh Deepgram generation would be worse than losing it: only the
/// last few seconds before the reconnect are worth anything.
const int _kReplayMaxBytes = 512 * 1024;
const Duration _kReplayMaxAge = Duration(seconds: 20);

class PureSocket implements IPureSocket {
  WebSocketChannel? _channel;
  final List<({List<int> frame, DateTime at})> _replay = [];
  int _replayBytes = 0;
  WebSocketChannel get channel {
    if (_channel == null) {
      throw Exception('Socket is not connected');
    }
    return _channel!;
  }

  PureSocketStatus _status = PureSocketStatus.notConnected;
  @override
  PureSocketStatus get status => _status;

  IPureSocketListener? _listener;

  String url;
  final SocketHeadersProvider _headersProvider;

  PureSocket(this.url, {SocketHeadersProvider? headersProvider})
      : _headersProvider =
            headersProvider ?? (() => buildHeaders(requireAuthCheck: true, url: url, forWebSocket: true));

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() async {
    if (_status == PureSocketStatus.connecting || _status == PureSocketStatus.connected) {
      return false;
    }

    Logger.debug("request wss $url");
    final Map<String, String> headers;
    try {
      headers = await _headersProvider();
    } on AuthTokenUnavailableException catch (e) {
      Logger.debug('[Socket] Connect blocked before send: ${e.result.runtimeType}');
      _status = PureSocketStatus.notConnected;
      return false;
    }

    _channel = IOWebSocketChannel.connect(
      url,
      headers: headers,
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 15),
    );
    if (_channel?.ready == null) {
      return false;
    }

    _status = PureSocketStatus.connecting;
    dynamic err;
    try {
      await channel.ready;
    } on TimeoutException catch (e) {
      err = e;
      DebugLogManager.logWarning('pure_socket_connect_timeout', {'url': url, 'error': e.toString()});
    } on SocketException catch (e) {
      err = e;
      DebugLogManager.logWarning('pure_socket_connect_socket_error', {'url': url, 'error': e.toString()});
    } on WebSocketChannelException catch (e) {
      err = e;
      DebugLogManager.logWarning('pure_socket_connect_websocket_error', {'url': url, 'error': e.toString()});
    }
    if (err != null) {
      Logger.debug("[Socket] Connect error: $err");
      _status = PureSocketStatus.notConnected;
      return false;
    }
    _status = PureSocketStatus.connected;
    DebugLogManager.logEvent('pure_socket_connected', {'url': url});
    onConnected();

    final that = this;

    _channel?.stream.listen(
      (message) {
        if (message == "ping") {
          // Logger.debug(message);
          // Pong frame added manually https://www.rfc-editor.org/rfc/rfc6455#section-5.5.2
          _channel?.sink.add([0x8A, 0x00]);
          return;
        }
        that.onMessage(message);
      },
      onError: (err, trace) {
        that.onError(err, trace);
      },
      onDone: () {
        Logger.debug("onDone with close code: ${_channel?.closeCode}");
        that.onClosed(_channel?.closeCode);
      },
      cancelOnError: true,
    );

    return true;
  }

  @override
  Future disconnect() async {
    DebugLogManager.logEvent('pure_socket_disconnecting', {'url': url, 'current_status': _status.toString()});
    if (_status == PureSocketStatus.connected) {
      // Warn: should not use await cause dead end by socket closed.
      _channel?.sink.close(socket_channel_status.normalClosure);
    }
    _status = PureSocketStatus.disconnected;
    Logger.debug("[Socket] disconnect");
    onClosed(_channel?.closeCode);
  }

  @override
  Future stop() async {
    DebugLogManager.logEvent('pure_socket_stopping', {'url': url});
    await disconnect();
  }

  @override
  void onClosed([int? closeCode]) {
    _status = PureSocketStatus.disconnected;
    final closeReason = _getCloseCodeReason(closeCode);
    Logger.debug("Socket closed with code: $closeCode ($closeReason)");

    DebugLogManager.logEvent('pure_socket_closed', {
      'close_code': closeCode ?? -1,
      'close_reason': closeReason,
      'url': url,
    });

    _listener?.onClosed(closeCode);
  }

  String _getCloseCodeReason(int? code) {
    switch (code) {
      case 1000:
        return 'normal_closure';
      case 1001:
        return 'going_away_os_or_background';
      case 1006:
        return 'abnormal_closure';
      case 1008:
        return 'policy_violation_or_auth_error';
      case 1011:
        return 'server_error';
      case 4001:
        return 'auth_token_refresh_required';
      case 4004:
        return 'auth_relogin_required';
      default:
        return 'unknown';
    }
  }

  @override
  void onError(Object err, StackTrace trace) {
    _status = PureSocketStatus.disconnected;
    Logger.debug("[Socket] Error: $err");

    DebugLogManager.logError(err, trace, 'pure_socket_error', {'url': url});

    _listener?.onError(err, trace);
    PlatformManager.instance.crashReporter.reportCrash(err, trace);
  }

  @override
  void onMessage(dynamic message) {
    // Logger.debug("[Socket] Message $message");
    _listener?.onMessage(message);
  }

  @override
  void onConnected() {
    _flushReplay();
    _listener?.onConnected();
  }

  /// Send everything held while the socket was away, oldest first, dropping
  /// anything too old to belong to the speech now arriving.
  void _flushReplay() {
    if (_replay.isEmpty) return;
    final sink = _channel?.sink;
    final cutoff = DateTime.now().subtract(_kReplayMaxAge);
    final held = List<({List<int> frame, DateTime at})>.from(_replay);
    _replay.clear();
    _replayBytes = 0;
    if (sink == null) return;
    var sent = 0;
    for (final held0 in held) {
      if (held0.at.isBefore(cutoff)) continue;
      sink.add(held0.frame);
      sent++;
    }
    if (sent > 0) Logger.debug('[Socket] replayed $sent buffered frame(s) after reconnect');
  }

  void _hold(List<int> frame) {
    final now = DateTime.now();
    _replay.add((frame: frame, at: now));
    _replayBytes += frame.length;
    final cutoff = now.subtract(_kReplayMaxAge);
    while (_replay.isNotEmpty && (_replayBytes > _kReplayMaxBytes || _replay.first.at.isBefore(cutoff))) {
      _replayBytes -= _replay.first.frame.length;
      _replay.removeAt(0);
    }
  }

  @override
  void send(message) {
    final sink = _channel?.sink;
    if (sink != null && _status == PureSocketStatus.connected) {
      sink.add(message);
      return;
    }
    // Only audio is worth replaying; a control frame written while the
    // socket is down belongs to a session that no longer exists.
    if (message is List<int>) _hold(message);
  }
}
