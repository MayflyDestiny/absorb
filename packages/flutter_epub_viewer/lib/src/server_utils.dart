import 'dart:io';
import 'dart:math';

import 'book_source.dart';

/// A random 32-hex-char path segment that scopes a loopback server's URL so
/// nothing else on the device can guess it.
String randomHexToken() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// The byte window a response should serve, resolved from an optional
/// `Range: bytes=start-end` header.
class ResolvedByteRange {
  const ResolvedByteRange(this.start, this.end, {required this.partial});

  final int start;
  final int end;

  /// True when a `Range` header was honoured (answer 206); false for a full
  /// body (answer 200).
  final bool partial;
}

/// Resolves a `Range` header [value] for a body of [length] bytes, using the
/// same forgiving parsing the loopback servers rely on (WebViews only send
/// simple single-range requests). Returns null when the header asks for an
/// unsatisfiable window, in which case the caller should answer 416.
ResolvedByteRange? resolveByteRange(String? value, int length) {
  if (length <= 0) return null;
  var start = 0;
  var end = length - 1;
  if (value == null || !value.startsWith('bytes=')) {
    return ResolvedByteRange(start, end, partial: false);
  }
  final spec = value.substring('bytes='.length).trim();
  // WebViews send a single range; a multi-range (`a-b,c-d`) or malformed header
  // can't be answered with one window, so serve the whole body instead.
  if (spec.contains(',') || !spec.contains('-')) {
    return ResolvedByteRange(0, length - 1, partial: false);
  }
  final dash = spec.indexOf('-');
  final sRaw = spec.substring(0, dash).trim();
  final eRaw = spec.substring(dash + 1).trim();
  if (sRaw.isEmpty) {
    // Suffix range `bytes=-N`: the last N bytes of the body.
    final n = int.tryParse(eRaw);
    if (n == null || n <= 0) return null;
    start = n >= length ? 0 : length - n;
    end = length - 1;
  } else {
    final s = int.tryParse(sRaw);
    if (s == null) return ResolvedByteRange(0, length - 1, partial: false);
    start = s;
    final e = eRaw.isEmpty ? null : int.tryParse(eRaw);
    if (e != null && e < length) end = e;
  }
  if (start > end || start >= length) return null;
  return ResolvedByteRange(start, end, partial: true);
}

/// Streams the `[start, end]` byte window of [source] into [res] one chunk at a
/// time, so only what the client asked for is read, then closes the response.
Future<void> streamBookRange(
    HttpResponse res, BookSource source, int start, int end) async {
  const chunkSize = 1 << 20;
  var pos = start;
  while (pos <= end) {
    final want = min(chunkSize, end - pos + 1);
    final bytes = await source.read(pos, want);
    if (bytes.isEmpty) break;
    res.add(bytes);
    pos += bytes.length;
  }
  await res.close();
}
