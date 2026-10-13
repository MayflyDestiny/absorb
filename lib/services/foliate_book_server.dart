import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

/// Tiny loopback HTTP server that serves the foliate reader shell plus the
/// book itself, which is read lazily through a [BookSource] (a cached file, an
/// exported plain path, or a held Android SAF descriptor read positionally with
/// no copy).
class FoliateBookServer {
  BookSource? _source;
  String _bookMime = 'application/octet-stream';
  HttpServer? _server;

  Future<int> start({
    required BookSource source,
    required String mime,
  }) async {
    _source = source;
    _bookMime = mime;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle);
    return server.port;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    final path = req.uri.path;
    try {
      if (path == '/' || path == '/reader.html' || path == '/index.html') {
        await _serveAsset(res, 'assets/foliate/reader.html', 'text/html; charset=utf-8');
      } else if (path == '/reader-app.js') {
        await _serveAsset(res, 'assets/foliate/reader-app.js', 'text/javascript; charset=utf-8');
      } else if (path.startsWith('/foliate-js/')) {
        final rel = path.substring('/foliate-js/'.length);
        // Guard against path traversal before touching the bundle.
        if (rel.contains('..')) {
          res.statusCode = HttpStatus.forbidden;
          await res.close();
          return;
        }
        await _serveAsset(res, 'assets/foliate/foliate-js/$rel', 'text/javascript; charset=utf-8');
      } else if (path.startsWith('/book/')) {
        await _serveBook(res, range: req.headers.value('range'));
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _serveAsset(HttpResponse res, String assetKey, String contentType) async {
    final data = await rootBundle.load(assetKey);
    res.headers.contentType = ContentType.parse(contentType);
    res.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    await res.close();
  }

  Future<void> _serveBook(HttpResponse res, {String? range}) async {
    final source = _source;
    if (source == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final length = await source.length();
    if (length <= 0) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers.contentType = ContentType.parse(_bookMime);
    res.headers.set('Accept-Ranges', 'bytes');
    // Always answer with a Content-Length (and honour a Range if the WebView
    // asks for one) so the client gets a sized body instead of a chunked
    // stream it can't turn into a Blob - a chunked response makes foliate-js's
    // `fetch(url)` hang or yield an empty file for MOBI/AZW3.
    final resolved = resolveByteRange(range, length);
    if (resolved == null) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await res.close();
      return;
    }
    final start = resolved.start;
    final end = resolved.end;
    if (resolved.partial) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('Content-Range', 'bytes $start-$end/$length');
    }
    res.contentLength = end - start + 1;
    // Stream the range in chunks, reading only what the client asks for.
    await streamBookRange(res, source, start, end);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _source = null;
  }
}
