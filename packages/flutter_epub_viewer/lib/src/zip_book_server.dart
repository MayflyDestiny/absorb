import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_source.dart';
import 'server_utils.dart';

/// Serves the entries of a zip (an epub) to the WebView over loopback as if
/// they were files in an unzipped directory, reading and inflating each entry
/// from the original archive on demand.
///
/// This lets the viewer open the book in epub.js's directory mode, which fetches
/// only the container, the OPF and the current section, instead of pulling the
/// whole archive into the page and unpacking it in JavaScript - the slow path
/// that made a 161MB book take several seconds before the first page could even
/// start. Nothing is extracted to disk: only the zip's central directory is
/// read, into a small in-memory name -> offset index.
///
/// One random path per server, loopback only, closed with the viewer.
///
/// Set to true while developing to see which request paths fail to match.
bool zipServerDebugLog = false;

class ZipBookServer {
  ZipBookServer._(this.source, this._entries);

  final BookSource source;
  final Map<String, _ZipEntry> _entries;
  final String _token = randomHexToken();
  HttpServer? _server;

  /// Returns a server for [source], or null when it isn't a zip we can index
  /// (in which case the caller should fall back to serving the whole file).
  static Future<ZipBookServer?> create(BookSource source) async {
    final entries = await _readCentralDirectory(source);
    if (entries == null || entries.isEmpty) return null;
    return ZipBookServer._(source, entries);
  }

  /// A directory-style URL (trailing slash, no file extension) so the page
  /// treats it as an unarchived epub and requests entries one by one.
  String? get url =>
      _server == null ? null : 'http://127.0.0.1:${_server!.port}/$_token/';

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
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }
      final prefix = '/$_token/';
      final rawPath = req.uri.path;
      if (!rawPath.startsWith(prefix)) {
        if (zipServerDebugLog) {
          stderr.writeln('[zipbook] $rawPath - not under $prefix');
        }
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      var path = Uri.decodeComponent(rawPath.substring(prefix.length));
      while (path.startsWith('/')) {
        path = path.substring(1);
      }
      final entry = _entries[path];
      if (entry == null) {
        if (zipServerDebugLog) {
          final candidates = _entries.keys
              .where((k) => k.length == path.length)
              .toList();
          stderr.writeln(
              '[zipbook] MISS "$path" (${_entries.length} entries, e.g. $candidates)');
        }
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final bytes = await _readEntry(entry);
      res.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
      res.headers.set(HttpHeaders.contentTypeHeader, _contentType(path));
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      res.contentLength = bytes.length;
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      res.add(bytes);
      await res.close();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<Uint8List> _readEntry(_ZipEntry entry) async {
    // Reads are positional, so concurrent fetches (a section plus its images
    // and css can resolve in parallel) never interleave.
    // The local file header's name/extra lengths can differ from the central
    // directory's, so read them from the local header to find the data offset.
    final header = await source.read(entry.localHeaderOffset, 30);
    if (header.length < 30) return Uint8List(0);
    final nameLen = header[26] | (header[27] << 8);
    final extraLen = header[28] | (header[29] << 8);
    final dataOffset = entry.localHeaderOffset + 30 + nameLen + extraLen;
    final compressed = await source.read(dataOffset, entry.compressedSize);
    if (entry.compressionMethod == 0 || compressed.isEmpty) {
      return compressed;
    }
    if (entry.compressionMethod == 8) {
      return const ZLibDecoder().decodeBytes(compressed, raw: true);
    }
    // Unsupported methods (bzip2/lzma/encrypted): hand back the raw bytes.
    return compressed;
  }

  static String _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'xhtml':
        return 'application/xhtml+xml';
      case 'html':
      case 'htm':
        return 'text/html';
      case 'xml':
        return 'application/xml';
      case 'opf':
        return 'application/oebps-package+xml';
      case 'ncx':
        return 'application/x-dtbncx+xml';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
      case 'json':
        return 'application/json';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'svg':
        return 'image/svg+xml';
      case 'bmp':
        return 'image/bmp';
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'mp4':
        return 'video/mp4';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  /// Reads the zip's central directory into a name -> entry index. Only the
  /// directory bytes (a few KB to a few hundred KB) are read, never the entry
  /// contents, so a large book is indexed in milliseconds.
  static Future<Map<String, _ZipEntry>?> _readCentralDirectory(
      BookSource source) async {
    try {
      final length = await source.length();
      if (length < 22) return null;

      // The end-of-central-directory record sits in the last 22 bytes plus up
      // to 64KB of archive comment.
      final tailLen = min(length, 22 + 0xFFFF);
      final tail = await source.read(length - tailLen, tailLen);
      final eocd = _findFromEnd(tail, 0x06054b50);
      if (eocd < 0) return null;

      var cdOffset = _u32(tail, eocd + 16);
      var cdSize = _u32(tail, eocd + 12);
      var count = _u16(tail, eocd + 10);

      // Zip64: the 32-bit fields become their max value and the real values
      // live in the zip64 EOCD record pointed at by a locator just before the
      // EOCD record.
      if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF || count == 0xFFFF) {
        final locPos = eocd - 20;
        if (locPos >= 0 && _u32(tail, locPos) == 0x07064b50) {
          final z64 = _u64(tail, locPos + 8);
          final rec = await source.read(z64, 56);
          if (rec.length >= 56 && _u32(rec, 0) == 0x06064b50) {
            count = _u64(rec, 32);
            cdSize = _u64(rec, 40);
            cdOffset = _u64(rec, 48);
          }
        }
      }

      if (cdSize <= 0 || cdOffset < 0 || cdOffset + cdSize > length) {
        return null;
      }
      final cd = await source.read(cdOffset, cdSize);

      final entries = <String, _ZipEntry>{};
      var pos = 0;
      for (var i = 0; i < count && pos + 46 <= cd.length; i++) {
        if (_u32(cd, pos) != 0x02014b50) break;
        var method = _u16(cd, pos + 10);
        var compressedSize = _u32(cd, pos + 20);
        var uncompressedSize = _u32(cd, pos + 24);
        final nameLen = _u16(cd, pos + 28);
        final extraLen = _u16(cd, pos + 30);
        final commentLen = _u16(cd, pos + 32);
        final diskStart = _u16(cd, pos + 34);
        var localOffset = _u32(cd, pos + 42);
        final nameStart = pos + 46;
        if (nameStart + nameLen > cd.length) break;
        // .NET's Compress-Archive writes entry names with backslashes; real
        // epubs use forward slashes. Normalize so both index and match.
        final name = utf8
            .decode(cd.sublist(nameStart, nameStart + nameLen),
                allowMalformed: true)
            .replaceAll('\\', '/');

        // Zip64 extended info: any field set to its max value carries its real
        // value in an extra field (id 0x0001), in a fixed order.
        if (uncompressedSize == 0xFFFFFFFF ||
            compressedSize == 0xFFFFFFFF ||
            localOffset == 0xFFFFFFFF ||
            diskStart == 0xFFFF) {
          final extraStart = nameStart + nameLen;
          var p = extraStart;
          final extraEnd = extraStart + extraLen;
          while (p + 4 <= extraEnd && p + 4 <= cd.length) {
            final id = _u16(cd, p);
            final size = _u16(cd, p + 2);
            var q = p + 4;
            if (id == 0x0001) {
              if (uncompressedSize == 0xFFFFFFFF && q + 8 <= cd.length) {
                uncompressedSize = _u64(cd, q);
                q += 8;
              }
              if (compressedSize == 0xFFFFFFFF && q + 8 <= cd.length) {
                compressedSize = _u64(cd, q);
                q += 8;
              }
              if (localOffset == 0xFFFFFFFF && q + 8 <= cd.length) {
                localOffset = _u64(cd, q);
                q += 8;
              }
            }
            p += 4 + size;
          }
        }

        if (!name.endsWith('/')) {
          entries[name] = _ZipEntry(
            localOffset,
            compressedSize,
            method,
          );
        }
        pos = nameStart + nameLen + extraLen + commentLen;
      }
      return entries;
    } catch (_) {
      return null;
    }
  }

  static int _findFromEnd(Uint8List bytes, int signature) {
    for (var i = bytes.length - 4; i >= 0; i--) {
      if (bytes[i] == (signature & 0xFF) &&
          bytes[i + 1] == ((signature >> 8) & 0xFF) &&
          bytes[i + 2] == ((signature >> 16) & 0xFF) &&
          bytes[i + 3] == ((signature >> 24) & 0xFF)) {
        return i;
      }
    }
    return -1;
  }

  static int _u16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

  static int _u32(Uint8List b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  static int _u64(Uint8List b, int i) {
    final lo = _u32(b, i);
    final hi = _u32(b, i + 4);
    return (hi << 32) | lo;
  }
}

class _ZipEntry {
  const _ZipEntry(
    this.localHeaderOffset,
    this.compressedSize,
    this.compressionMethod,
  );

  final int localHeaderOffset;
  final int compressedSize;
  final int compressionMethod;
}
