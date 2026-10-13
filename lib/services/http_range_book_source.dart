import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:http/http.dart' as http;

/// Whether to print the probe/close Range summaries (`[HttpRange]`). Handy when
/// verifying streaming playback of a book; flip off to quiet the log.
bool httpRangeDebugLog = true;

/// Whether to also print every individual Range request. Off by default: a
/// single 160 MB open issues hundreds of reads, which drowns out everything
/// else. Turn on only to trace request-level behaviour.
bool httpRangeTraceLog = false;

/// A [BookSource] that reads an ebook straight off the server with HTTP Range
/// requests, fetching only the bytes the reader asks for. The zip server reads
/// the archive's central directory (the last ~64KB) and then each section on
/// demand, so a 160MB image-heavy book opens and pages without downloading it
/// whole. [open] returns null when the server doesn't honour Range, so the
/// caller can fall back to caching the file.
class HttpRangeBookSource implements BookSource {
  HttpRangeBookSource._(this._client, this._url, this._headers, this._length);

  final http.Client _client;
  final String _url;
  final Map<String, String> _headers;
  final int _length;

  int _bytes = 0;
  int _requests = 0;
  bool _closed = false;

  /// Probes [url] with a one-byte Range request. Returns a source when the
  /// server answers 206 with a `Content-Range` (Range supported), otherwise
  /// null (client closed).
  static Future<HttpRangeBookSource?> open(
    String url, {
    Map<String, String>? headers,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    final sw = Stopwatch()..start();
    try {
      final res = await c.get(
        Uri.parse(url),
        headers: {
          ...?headers,
          // Never let a proxy gzip the (already-compressed) archive: an
          // auto-decompressed body would corrupt the zip byte offsets.
          'Accept-Encoding': 'identity',
          'Range': 'bytes=0-0',
        },
      ).timeout(const Duration(seconds: 8));
      final cr = res.headers['content-range'];
      if (httpRangeDebugLog) {
        debugPrint('[HttpRange] probe status=${res.statusCode} '
            'content-range=$cr in ${sw.elapsedMilliseconds}ms');
      }
      if (res.statusCode != 206 || cr == null) {
        c.close();
        return null;
      }
      final total = int.tryParse(cr.split('/').last.trim());
      if (total == null || total <= 0) {
        c.close();
        return null;
      }
      if (httpRangeDebugLog) {
        debugPrint('[HttpRange] streaming ready bytes=$total url=${_redactQuery(url)}');
      }
      return HttpRangeBookSource._(c, url, headers ?? const {}, total);
    } catch (e) {
      if (httpRangeDebugLog) debugPrint('[HttpRange] probe failed: $e');
      c.close();
      return null;
    }
  }

  @override
  Future<int> length() async => _length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (_closed) return Uint8List(0);
    if (count <= 0 || offset < 0 || offset >= _length) return Uint8List(0);
    final end = (offset + count - 1).clamp(0, _length - 1);
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .get(
            Uri.parse(_url),
            headers: {
              ..._headers,
              'Accept-Encoding': 'identity',
              'Range': 'bytes=$offset-$end',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 206) {
        if (httpRangeDebugLog) {
          debugPrint('[HttpRange] read $offset-$end FAILED '
              'status=${res.statusCode} in ${sw.elapsedMilliseconds}ms');
        }
        return Uint8List(0);
      }
      // Guard against a server that ignores the Range (200/whole body) or
      // answers a different window: using it would place the bytes at the wrong
      // offset and silently corrupt the zip. Only a 206 starting at [offset] is
      // ours.
      final cr = res.headers['content-range'];
      final start = cr == null
          ? null
          : int.tryParse(cr.split(RegExp(r'[\s/-]')).elementAt(1));
      if (start != null && start != offset) {
        if (httpRangeDebugLog) {
          debugPrint('[HttpRange] read $offset-$end MISMATCH '
              'content-range=$cr in ${sw.elapsedMilliseconds}ms');
        }
        return Uint8List(0);
      }
      final body = res.bodyBytes;
      _bytes += body.length;
      _requests++;
      if (httpRangeTraceLog) {
        debugPrint('[HttpRange] read $offset-${offset + body.length - 1} '
            'got=${body.length}B in ${sw.elapsedMilliseconds}ms '
            '(total ${fmtBytes(_bytes)} / $_requests reqs)');
      }
      return body;
    } catch (e) {
      if (httpRangeDebugLog && !_closed) {
        debugPrint('[HttpRange] read $offset-$end error: $e');
      }
      return Uint8List(0);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (httpRangeDebugLog) {
      debugPrint('[HttpRange] closed: ${fmtBytes(_bytes)} over $_requests '
          'requests (file ${fmtBytes(_length)})');
    }
    _client.close();
  }
}

/// Human-readable byte size for the Range logs.
String fmtBytes(int n) {
  if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)}MB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
  return '${n}B';
}

/// Strips the `?token=...` query from [url] so it never lands in the log.
String _redactQuery(String url) {
  final i = url.indexOf('?');
  return i < 0 ? url : url.substring(0, i);
}
