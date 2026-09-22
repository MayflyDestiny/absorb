import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

/// App-wide image cache with real timeouts.
///
/// `flutter_cache_manager`'s default file service has no timeout at all, so a
/// cover request that stalls on a congested link hangs forever and keeps its
/// socket - and the data still trickling through it - alive. This manager
/// swaps in a [FileService] that owns the client per request and force-closes
/// it on a connect or read timeout, which is what actually stops the transfer.
///
/// [install] points [CachedNetworkImageProvider.defaultCacheManager] at it, so
/// every `CachedNetworkImage` / `CachedNetworkImageProvider` in the app picks
/// it up without touching each call site.
class CoverCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'absorbCoverCache';

  static final CoverCacheManager instance = CoverCacheManager._();

  CoverCacheManager._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 30),
            // A square tile renders the same cover twice (blur fill + main
            // decode share one disk object, but every grid cell is one object
            // and decks with thousands of covers churn a 200-entry LRU on
            // every pass - evicting yesterday's keys than re-downloading them
            // next session. 1000 stays comfortably under a 30-day stale
            // period's worth of disk if covers keep their keys stable.
            maxNrOfCacheObjects: 1000,
            fileService: _TimeoutHttpFileService(),
          ),
        );

  /// Route all cached network images through this manager.
  static void install() {
    CachedNetworkImageProvider.defaultCacheManager = instance;
  }

  /// Total size of the on-disk cover cache in bytes. Best-effort: unreadable
  /// entries are skipped rather than failing the whole total.
  Future<int> sizeBytes() async {
    try {
      final objects = await config.repo.getAllObjects();
      var total = 0;
      for (final object in objects) {
        try {
          final file = await config.fileSystem.createFile(object.relativePath);
          total += await file.length();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Drop the on-disk cover cache and the decoded images still held in memory.
  Future<void> clear() async {
    await emptyCache();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }
}

/// [HttpFileService] with connect and per-chunk read timeouts. The read timeout
/// is the important one: it catches a connection that opens but then stops
/// delivering data, which a connect timeout alone never would.
class _TimeoutHttpFileService extends FileService {
  _TimeoutHttpFileService();

  static const connectTimeout = Duration(seconds: 15);
  static const readTimeout = Duration(seconds: 20);

  @override
  Future<FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) request.headers.addAll(headers);
    try {
      final response = await client.send(request).timeout(connectTimeout);
      return _TimeoutResponse(
        HttpGetResponse(response),
        _abortableBody(response.stream, client),
      );
    } catch (_) {
      // Connect failed or timed out: drop the connection immediately.
      client.close();
      rethrow;
    }
  }

  /// Wrap [source] so that a gap longer than [readTimeout] errors the stream
  /// and force-closes [client], and so the client is closed once the body is
  /// fully read. Either way the socket does not outlive the download.
  Stream<List<int>> _abortableBody(Stream<List<int>> source, http.Client client) {
    StreamSubscription<List<int>>? sub;
    Timer? timer;
    var finished = false;
    late StreamController<List<int>> controller;

    void finish() {
      if (finished) return;
      finished = true;
      timer?.cancel();
      timer = null;
      sub?.cancel();
      client.close();
    }

    void arm() {
      timer?.cancel();
      timer = Timer(readTimeout, () {
        if (finished) return;
        controller.addError(
          TimeoutException('cover read exceeded $readTimeout'),
        );
        controller.close();
        finish();
      });
    }

    controller = StreamController<List<int>>(
      onListen: () {
        arm();
        sub = source.listen(
          (chunk) {
            if (finished) return;
            arm();
            controller.add(chunk);
          },
          onError: (Object e, StackTrace st) {
            if (finished) return;
            controller.addError(e, st);
            controller.close();
            finish();
          },
          onDone: () {
            if (finished) return;
            controller.close();
            finish();
          },
          cancelOnError: true,
        );
      },
      onCancel: finish,
    );
    return controller.stream;
  }
}

/// [FileServiceResponse] that serves the abortable body while delegating every
/// header-derived field to the raw response.
class _TimeoutResponse implements FileServiceResponse {
  _TimeoutResponse(this._delegate, this._content);

  final HttpGetResponse _delegate;
  final Stream<List<int>> _content;

  @override
  Stream<List<int>> get content => _content;

  @override
  int? get contentLength => _delegate.contentLength;

  @override
  int get statusCode => _delegate.statusCode;

  @override
  DateTime get validTill => _delegate.validTill;

  @override
  String? get eTag => _delegate.eTag;

  @override
  String get fileExtension => _delegate.fileExtension;
}
