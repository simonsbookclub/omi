import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:pool/pool.dart';

class HttpPoolManager {
  static final HttpPoolManager instance = HttpPoolManager._();

  late final IOClient _client;
  late final Pool _pool;

  // GET deduplication: URL -> pending future
  final Map<String, Future<http.Response>> _pendingGets = {};

  HttpPoolManager._() {
    final httpClient = HttpClient()
      ..maxConnectionsPerHost = 15
      ..idleTimeout = const Duration(seconds: 15);

    _client = IOClient(httpClient);
    _pool = Pool(10, timeout: const Duration(seconds: 60));
  }

  /// Stamps a fresh X-Request-Start-Time on any outgoing request.
  /// Shared enforcement point: every pooled request flows through send() or
  /// sendStreaming(), and the deliberately unpooled upload path
  /// (makeMultipartApiCallUnpooled in shared.dart) calls this directly, so
  /// retries, pool-queued requests, and multipart uploads all get a current
  /// timestamp. (#6274)
  static void stampRequestTime(http.BaseRequest request) {
    request.headers['X-Request-Start-Time'] = (DateTime.now().millisecondsSinceEpoch / 1000).toString();
  }

  Future<http.Response> send(
    http.Request Function() requestBuilder, {
    Duration timeout = const Duration(seconds: 30),
    int retries = 1,
  }) async {
    final sample = requestBuilder();
    final isGet = sample.method == 'GET';
    final url = sample.url.toString();

    // Deduplicate GET requests
    if (isGet && _pendingGets.containsKey(url)) {
      return _pendingGets[url]!;
    }

    final future = _pool.withResource(() async {
      return _executeWithRetry(requestBuilder, timeout, retries);
    });

    if (isGet) {
      _pendingGets[url] = future;
      future.whenComplete(() => _pendingGets.remove(url));
    }

    return future;
  }

  Future<http.Response> _executeWithRetry(http.Request Function() requestBuilder, Duration timeout, int retries) async {
    http.Response? lastResponse;
    Object? lastError;

    for (var i = 0; i <= retries; i++) {
      try {
        final request = requestBuilder();
        stampRequestTime(request);
        // One deadline for the whole exchange, body included. The timeout used
        // to cover only the headers arriving: a body that stalled mid-stream
        // (a 365 KB conversation list on a flaky 5G link) never completed,
        // the stuck future stayed in _pendingGets for its URL, every later
        // fetch of that URL was handed the same stuck future, and the app
        // went blind on every screen until it was killed (2026-09-14).
        lastResponse = await (() async {
          final streamed = await _client.send(request);
          return http.Response.fromStream(streamed);
        })().timeout(timeout);

        if (lastResponse.statusCode < 500) {
          return lastResponse;
        }
        lastError = Exception('Server error: ${lastResponse.statusCode}');
      } on TimeoutException {
        lastError = TimeoutException('Request timeout');
      } on SocketException catch (e) {
        lastError = e;
      } on HandshakeException catch (e) {
        lastError = e;
      } on http.ClientException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
        rethrow;
      }

      if (i < retries) {
        await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }

    if (lastResponse != null) return lastResponse;
    throw lastError ?? Exception('Request failed with unknown error');
  }

  Future<http.StreamedResponse> sendStreaming(
    http.BaseRequest request, {
    Duration timeout = const Duration(minutes: 5),
  }) {
    stampRequestTime(request);
    return _client.send(request).timeout(timeout);
  }

  void dispose() {
    _pool.close();
    _client.close();
    _pendingGets.clear();
  }
}
