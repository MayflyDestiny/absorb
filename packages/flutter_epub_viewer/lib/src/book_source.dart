import 'dart:io';
import 'dart:typed_data';

/// Random-access byte source a reader serves from. It decouples the loopback
/// servers (and the epub.js page they feed) from where the bytes actually live:
/// a regular file, the app's cache, or - on Android - a held SAF file
/// descriptor read positionally without ever copying the book to disk.
///
/// [read] is positional: it must not rely on any shared cursor, so calls may
/// overlap (the zip server answers a section and its images concurrently).
abstract class BookSource {
  /// Total size of the book in bytes.
  Future<int> length();

  /// Bytes in `[offset, offset + count)`. Shorter than [count] only at EOF.
  Future<Uint8List> read(int offset, int count);

  /// Releases any handle. Safe to call once, when the reader closes.
  Future<void> close();
}

/// A [BookSource] over a regular file on disk (a cache, a plain exported path,
/// or a transient copy).
class FileBookSource implements BookSource {
  FileBookSource(this.file);

  final File file;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0) return Uint8List(0);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(offset, offset + count)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> close() async {}
}
