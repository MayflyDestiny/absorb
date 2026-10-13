import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_epub_viewer/src/epub_data_loader.dart';
import 'package:flutter_epub_viewer/src/book_source.dart';


/// Epub file source
class EpubSource {
  final EpubDataLoader _loader;

  /// The random-access byte source the viewer serves to the page over loopback,
  /// reading only the bytes the page asks for. Present for both file sources and
  /// fd-backed sources (see [fromSource]).
  final BookSource? source;

  EpubSource._(this._loader, {this.source});

  Future<Uint8List> get epubData => _loader.loadData();

  ///Loading from a file
  factory EpubSource.fromFile(File file) =>
      EpubSource._(FileEpubLoader(file), source: FileBookSource(file));

  /// Loading from an arbitrary random-access byte source (e.g. an Android SAF
  /// file descriptor that never lands on disk). The viewer serves it over
  /// loopback, reading only the bytes the page requests.
  factory EpubSource.fromSource(BookSource source) =>
      EpubSource._(_SourceEpubLoader(source), source: source);

  ///load from a url with optional headers
  factory EpubSource.fromUrl(String url, {Map<String, String>? headers}) =>
      EpubSource._(UrlEpubLoader(url, headers: headers));

  ///load from assets
  factory EpubSource.fromAsset(String assetPath) =>
      EpubSource._(AssetEpubLoader(assetPath));
}

/// Reads the whole source into memory. Only used when a source has no loopback
/// path (the base64 fallback); file- and fd-backed sources use their server.
class _SourceEpubLoader implements EpubDataLoader {
  final BookSource source;

  _SourceEpubLoader(this.source);

  @override
  Future<Uint8List> loadData() async {
    final length = await source.length();
    return source.read(0, length);
  }
}
