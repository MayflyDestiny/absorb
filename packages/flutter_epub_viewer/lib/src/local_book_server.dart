import 'dart:io';

import 'book_source.dart';
import 'server_utils.dart';

/// Serves the whole book to the WebView over loopback, for when it isn't a zip
/// we can index as a directory (the page then fetches the file in ranges).
/// Reads go through [BookSource], so the bytes can come from a regular file or
/// an Android SAF file descriptor that never lands on disk.
class LocalBookServer {
  LocalBookServer(this.source);

  final BookSource source;
  final String _token = randomHexToken();
  HttpServer? _server;

  String? get url =>
      _server == null ? null : 'http://127.0.0.1:${_server!.port}/$_token/book.epub';

  Future<String> start() async {
    if (_server == null) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle, onError: (_) {});
      _server = server;
    }
    return url!;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final wanted = req.uri.path == '/$_token/book.epub' &&
          (req.method == 'GET' || req.method == 'HEAD');
      if (!wanted) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final length = await source.length();
      res.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/epub+zip');
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final resolved =
          resolveByteRange(req.headers.value(HttpHeaders.rangeHeader), length);
      if (resolved == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await res.close();
        return;
      }
      final start = resolved.start;
      final end = resolved.end;
      if (resolved.partial) {
        res.statusCode = HttpStatus.partialContent;
        res.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      res.contentLength = end - start + 1;
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      // Stream the range in chunks, reading only what the page asks for.
      await streamBookRange(res, source, start, end);
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}
