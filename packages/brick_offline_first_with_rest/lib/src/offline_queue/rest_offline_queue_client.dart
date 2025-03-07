import 'package:brick_offline_first/offline_queue.dart';
import 'package:brick_offline_first_with_rest/src/offline_queue/rest_request_sqlite_cache.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Stores all requests in a SQLite database
class RestOfflineQueueClient extends http.BaseClient {
  /// A normal HTTP client, treated like a manual `super`
  /// as detailed by [the Dart team](https://github.com/dart-lang/http/blob/378179845420caafbf7a34d47b9c22104753182a/README.md#using)
  final http.Client _inner;

  final RequestSqliteCacheManager<http.Request> requestManager;

  /// If the response returned from the client is one of these error codes, the request
  /// **will not** be removed from the queue. For example, if the result of a request produces a
  /// 404 status code response (such as in a Tunnel not found exception), the request will
  /// be reattempted.
  ///
  /// Defaults to `[404, 501, 502, 503, 504]`.
  final List<int> reattemptForStatusCodes;

  final Logger _logger;

  /// Describes the type of policy that came from the request, stringified
  /// from the [OfflineFirstPolicy] enum. The property will be removed before
  /// forwarding the request to [_inner].
  static const policyHeader = 'X-Brick-OfflineFirstPolicy';

  RestOfflineQueueClient(
    this._inner,
    this.requestManager, {
    List<int>? reattemptForStatusCodes,
  })  : _logger = Logger('OfflineQueueHttpClient#${requestManager.databaseName}'),
        reattemptForStatusCodes = reattemptForStatusCodes ?? [404, 501, 502, 503, 504];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cachePolicy = (request as http.Request).headers.remove(policyHeader);
    final skipCache = cachePolicy == 'requireRemote';
    final cacheItem = RestRequestSqliteCache(request);
    _logger.finest('sending: ${cacheItem.toSqlite()}');

    // Process the request immediately and forward any warnings to the caller
    if (skipCache) return await _inner.send(request);

    // "Pull" requests are ignored. See documentation of `RequestSqliteCache#requestIsPush`.
    if (cacheItem.requestIsPush) {
      final db = await requestManager.getDb();
      // Log immediately before we make the request
      await cacheItem.insertOrUpdate(db, logger: _logger);
    }

    /// When the request is null or an error has occurred, an error-like
    /// response is required because null is unacceptable in [BaseClient]
    final _genericErrorResponse = http.StreamedResponse(
      Stream.fromFuture(Future.value('unknown internal error'.codeUnits)),
      501,
    );

    try {
      // Attempt to make HTTP Request
      final resp = await _inner.send(request);

      if (cacheItem.requestIsPush && !reattemptForStatusCodes.contains(resp.statusCode)) {
        final db = await requestManager.getDb();
        // request was successfully sent and can be removed
        _logger.finest('removing from queue: ${cacheItem.toSqlite()}');
        await cacheItem.delete(db);
      }

      return resp;
    } catch (e) {
      _logger.warning('#send: $e');
    } finally {
      final db = await requestManager.getDb();
      await cacheItem.unlock(db);
    }

    return _genericErrorResponse;
  }

  /// Parse the returned response and determine if it needs to be removed from the queue.
  /// As a device with connectivity will still return a response if the endpoint is unreachable,
  /// false positives need to be filtered after the [response] is available.
  static bool isATunnelNotFoundResponse(http.Response response) {
    return response.statusCode == 404 &&
        response.body.startsWith('Tunnel') &&
        response.body.endsWith('not found');
  }
}
