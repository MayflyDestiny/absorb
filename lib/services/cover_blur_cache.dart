import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

/// Process-wide store for the pre-blurred cover bitmaps the listening cards
/// paint as their background.
///
/// Producing one costs three image round-trips - resolve the cover, draw it
/// through a blur filter, then read the top strip back for its brightness - so
/// a card that generated its own on first paint showed an unblurred, dimmed
/// cover for a beat before the blurred one snapped in. The bitmaps are tiny
/// (200px wide) and keyed by the same cache identity the covers use, so keeping
/// the handful a session actually visits means the card nearly always paints a
/// background that is already there. [warm] moves that work into the launch
/// preload, where nothing is competing for the raster thread.
///
/// The cache owns every [ui.Image] it holds. Callers take a [CoverBlurLease]
/// and release it when they drop the image; only unleased entries are eviction
/// candidates, so a bitmap a card is still painting can never be disposed from
/// under it.
///
/// 模糊结果同时写一份到 `<app-support>/cover_blur_v1`（200px PNG，上限 24
/// 张）。冷启动内存缓存为空时先读盘，命中就完全跳过封面解析和 toImage 模糊；
/// 写盘失败只影响下次启动的速度，不影响本次显示。
class CoverBlurCache {
  CoverBlurCache._();

  static final CoverBlurCache instance = CoverBlurCache._();

  /// How many blurred covers to keep. The listening screen shows one card at a
  /// time, so a couple of spares cover a swipe in either direction.
  static const _capacity = 6;

  static const _targetWidth = 200;
  static const _sigma = 30.0;

  // 模糊图也落盘：进程内存缓存冷启动即失效，每次重新解析封面 + 再做一次
  // toImage 模糊正是最重的一段。磁盘只存 200px 小图，数量有上限。
  static const _diskVersion = 1;
  static const _diskCapacity = 24;
  static Directory? _diskDirCache;

  /// Insertion order doubles as LRU: a hit re-inserts, eviction takes the head.
  final _entries = <String, _BlurEntry>{};
  final _inFlight = <String, Future<ui.Image?>>{};
  String? _latestItemKey;
  String? _latestIdentity;
  String? _playingItemKey;
  String? _playingIdentity;

  /// 启动时在 runApp 前把“上一次正在收听的那张模糊封面”读进内存。优先预加载
  /// now-playing 卡片的 item，其次才是最后浏览的卡片；绝不拿别的卡片的图来顶。
  Future<void> preloadLatest() async {
    final meta = await _readLatestMeta();
    if (meta == null) return;
    _latestItemKey = meta.last;
    _latestIdentity = meta.lastIdentity;
    _playingItemKey = meta.playing;
    _playingIdentity = meta.playingIdentity;
    final identities = <String>{
      if (_playingIdentity != null) _playingIdentity!,
      if (_latestIdentity != null) _latestIdentity!,
    };
    for (final identity in identities) {
      if (_entries.containsKey(identity)) continue;
      final image = await _loadFromDisk(identity);
      if (image != null) _storeIfAbsent(identity, image);
    }
  }

  /// 同步取 [preloadLatest] 留下的、且属于 [itemKey] 的那张模糊图。
  CoverBlurLease? cachedLatestLeaseFor(String itemKey) {
    String? identity;
    if (_playingItemKey == itemKey) {
      identity = _playingIdentity;
    } else if (_latestItemKey == itemKey) {
      identity = _latestIdentity;
    }
    if (identity == null) return null;
    return lease(identity);
  }

  /// 上一次为 [itemKey] 落盘的模糊封面。只使用这个 item 自己的 identity，绝不
  /// 拿别的卡片的图来顶；没有记录时返回 null，调用方回退到中性底色/当前封面。
  Future<CoverBlurLease?> latestLeaseFor(String itemKey) async {
    final meta = await _readLatestMeta();
    if (meta == null) return null;
    final identity = meta.items[itemKey] ??
        (meta.last == itemKey ? meta.lastIdentity : null);
    if (identity == null) return null;
    final held = lease(identity);
    if (held != null) return held;
    final image = await _loadFromDisk(identity);
    if (image == null) return null;
    _storeIfAbsent(identity, image);
    return lease(identity);
  }

  /// 记住这张模糊封面属于哪个 item，供下次冷启动做首帧底图。按 item 存一个
  /// 小映射，而不是只存全局最后一张，否则切换过卡片后首帧会拿错封面。
  Future<void> rememberLatest(
    String itemKey,
    String identity, {
    bool playing = false,
  }) async {
    _latestItemKey = itemKey;
    _latestIdentity = identity;
    if (playing) {
      _playingItemKey = itemKey;
      _playingIdentity = identity;
    }
    final meta = await _readLatestMeta();
    final items = <String, String>{...?meta?.items, itemKey: identity};
    while (items.length > 30) {
      items.remove(items.keys.first);
    }
    final file = await _metaFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'last': itemKey,
          'lastIdentity': identity,
          'playing': playing ? itemKey : (meta?.playing ?? _playingItemKey),
          'playingIdentity': playing
              ? identity
              : (meta?.playingIdentity ?? _playingIdentity),
          'items': items,
        }),
        flush: false,
      );
    } catch (_) {}
  }

  Future<File?> _metaFile() async {
    try {
      final dir = await _diskDir();
      return File('${dir.path}/last.json');
    } catch (_) {
      return null;
    }
  }

  Future<({String? last, String? lastIdentity, String? playing, String? playingIdentity, Map<String, String> items})?>
  _readLatestMeta() async {
    try {
      final file = await _metaFile();
      if (file == null || !await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final items = <String, String>{};
      final rawItems = decoded['items'];
      if (rawItems is Map) {
        for (final entry in rawItems.entries) {
          if (entry.key is String && entry.value is String) {
            items[entry.key as String] = entry.value as String;
          }
        }
      }
      // Backward compatibility with the one-item form written by the first
      // version of this metadata.
      final legacyItem = decoded['item'];
      final legacyIdentity = decoded['identity'];
      if (legacyItem is String && legacyIdentity is String) {
        items.putIfAbsent(legacyItem, () => legacyIdentity);
      }
      final last = decoded['last'] is String
          ? decoded['last'] as String
          : (legacyItem is String ? legacyItem : null);
      final lastIdentity = decoded['lastIdentity'] is String
          ? decoded['lastIdentity'] as String
          : (legacyIdentity is String ? legacyIdentity : null);
      final playing = decoded['playing'] is String
          ? decoded['playing'] as String
          : null;
      final playingIdentity = decoded['playingIdentity'] is String
          ? decoded['playingIdentity'] as String
          : null;
      return (
        last: last,
        lastIdentity: lastIdentity,
        playing: playing,
        playingIdentity: playingIdentity,
        items: items,
      );
    } catch (_) {
      return null;
    }
  }

  /// An extra lease on [identity]'s bitmap, or null when nothing is cached.
  CoverBlurLease? lease(String identity) {
    final entry = _entries.remove(identity);
    if (entry == null) return null;
    _entries[identity] = entry;
    entry.leases++;
    return CoverBlurLease._(this, entry);
  }

  /// Top-strip brightness of [identity]'s blur, when it has been measured.
  double? luminanceOf(String identity) => _entries[identity]?.luminance;

  /// Records the brightness measured by a lease holder, so the next holder of
  /// the same cover gets it without another read-back.
  void rememberLuminance(String identity, double luminance) {
    _entries[identity]?.luminance = luminance;
  }

  /// A leased bitmap for [identity], generating it on first use. Concurrent
  /// callers for the same cover share one generation.
  Future<CoverBlurLease?> acquire(
    ImageProvider provider,
    String identity,
  ) async {
    final held = lease(identity);
    if (held != null) return held;
    final image = await _inflight(provider, identity);
    if (image == null) return null;
    // Concurrent callers resolve to the same bitmap; the first to land is the
    // one that owns it and the rest simply take a lease on that entry, so no
    // caller ever disposes an image the cache is holding.
    _storeIfAbsent(identity, image);
    return lease(identity);
  }

  /// 取出（必要时生成并落盘）[identity] 的模糊图，但不持有 lease。启动预加载
  /// 用它把冷启动的工作提前；卡片随后会直接命中内存里的同一张图。
  Future<void> warm(ImageProvider provider, String identity) async {
    if (_entries.containsKey(identity)) return;
    final image = await _inflight(provider, identity);
    if (image == null) return;
    _storeIfAbsent(identity, image);
  }

  /// Drops every cached bitmap. Leased entries are disposed once their holders
  /// release them, so nothing a card still paints is freed here.
  void clear() {
    for (final entry in _entries.values) {
      entry.dropped = true;
      if (entry.leases == 0) entry.image.dispose();
    }
    _entries.clear();
  }

  void _release(_BlurEntry entry) {
    entry.leases--;
    if (entry.leases > 0) return;
    _trim();
    if (entry.dropped) entry.image.dispose();
  }

  void _storeIfAbsent(String identity, ui.Image image) {
    final existing = _entries[identity];
    if (existing != null) {
      // 同一个并发 future 会返回同一个 image；只有不同实例才需要释放。
      if (!identical(existing.image, image)) image.dispose();
      return;
    }
    _entries[identity] = _BlurEntry(image);
    _trim();
  }

  void _trim() {
    while (_entries.length > _capacity) {
      String? victim;
      for (final entry in _entries.entries) {
        if (entry.value.leases == 0) {
          victim = entry.key;
          break;
        }
      }
      // Everything left is on screen; growing beats dropping a live bitmap.
      if (victim == null) return;
      final entry = _entries.remove(victim)!;
      entry.dropped = true;
      entry.image.dispose();
    }
  }

  Future<Directory> _diskDir() async {
    final cached = _diskDirCache;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/cover_blur_v1');
    await dir.create(recursive: true);
    return _diskDirCache = dir;
  }

  Future<File?> _diskFile(String identity) async {
    try {
      final dir = await _diskDir();
      final digest = sha1.convert(
        utf8.encode('v$_diskVersion|$_targetWidth|$_sigma|$identity'),
      );
      return File('${dir.path}/$digest.png');
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image?> _loadFromDisk(String identity) async {
    final file = await _diskFile(identity);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToDisk(String identity, ui.Image image) async {
    final file = await _diskFile(identity);
    if (file == null) return;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: false);
      unawaited(_pruneDisk());
    } catch (_) {
      // 缓存写失败不影响本次显示。
    }
  }

  Future<void> _pruneDisk() async {
    try {
      final dir = await _diskDir();
      final files = <File>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.png')) files.add(entity);
      }
      if (files.length <= _diskCapacity) return;
      final stamped = <({File file, DateTime modified})>[];
      for (final file in files) {
        try {
          stamped.add((file: file, modified: (await file.stat()).modified));
        } catch (_) {}
      }
      stamped.sort((a, b) => a.modified.compareTo(b.modified));
      for (var i = 0; i < stamped.length - _diskCapacity; i++) {
        try {
          await stamped[i].file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 先读磁盘；命中就不再解析封面、也不再做 blur。未命中才渲染并回写。
  Future<ui.Image?> _loadOrRender(
    ImageProvider provider,
    String identity,
  ) async {
    final cached = await _loadFromDisk(identity);
    if (cached != null) return cached;
    final image = await _render(provider);
    if (image != null) unawaited(_saveToDisk(identity, image));
    return image;
  }

  Future<ui.Image?> _inflight(ImageProvider provider, String identity) {
    final pending = _inFlight[identity];
    if (pending != null) return pending;
    final future = _loadOrRender(provider, identity);
    _inFlight[identity] = future;
    future.whenComplete(() => _inFlight.remove(identity));
    return future;
  }

  Future<ui.Image?> _render(ImageProvider provider) async {
    try {
      final completer = Completer<ui.Image>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (e, _) {
          if (!completer.isCompleted) completer.completeError(e);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final source = await completer.future;
      return await blurToBitmap(source);
    } catch (_) {
      return null;
    }
  }

  /// Draws [source] scaled down and blurred to a small bitmap. The blur hides
  /// detail, so a 200px-wide target is enough and keeps the cost small.
  static Future<ui.Image> blurToBitmap(ui.Image source) async {
    final width = _targetWidth;
    final height = (width * (source.height / source.width)).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: _sigma,
        sigmaY: _sigma,
        tileMode: TileMode.decal,
      );
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );
    final picture = recorder.endRecording();
    final blurred = await picture.toImage(width, height);
    picture.dispose();
    return blurred;
  }
}

class _BlurEntry {
  _BlurEntry(this.image);

  final ui.Image image;
  double? luminance;
  int leases = 0;
  bool dropped = false;
}

/// A claim on a cached blurred bitmap.
///
/// The lease - not the [ui.Image] - is what callers hold. Releasing it lets the
/// cache evict and dispose the bitmap; double-releasing is a no-op.
class CoverBlurLease {
  CoverBlurLease._(this._cache, this._entry);

  final CoverBlurCache _cache;
  final _BlurEntry _entry;
  bool _released = false;

  ui.Image get image => _entry.image;

  void release() {
    if (_released) return;
    _released = true;
    _cache._release(_entry);
  }
}
