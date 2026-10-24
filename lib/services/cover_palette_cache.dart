import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 冷启动用的封面配色/亮度小缓存。
///
/// 卡片每次冷启动都要重新跑 `ColorScheme.fromImageProvider`（解码 + 量化），
/// 再另外读一次模糊图顶部亮度；这段时间正好和首帧、切换动画抢线程。这里把
/// 卡片实际用到的四个颜色角色和顶部亮度按 cover identity 落盘，启动时一次性
/// 读进内存，卡片第一帧就能拿到正确的配色，也能直接跳过调色板抽取。
///
/// 只缓存可见结果，不缓存原始图片；条目按 LRU 截断，文件是普通 JSON，损坏
/// 时直接忽略并回退到原来的抽取流程，不影响启动。
class CoverPaletteCache {
  CoverPaletteCache._();

  static final CoverPaletteCache instance = CoverPaletteCache._();

  static const _version = 1;
  static const _maxEntries = 300;
  static const _fileName = 'cover_palette_v1.json';
  static const _flushDelay = Duration(milliseconds: 500);

  final LinkedHashMap<String, CoverPaletteEntry> _entries = LinkedHashMap();
  File? _file;
  bool _loaded = false;
  Future<void>? _loading;
  Timer? _flushTimer;

  /// 在 runApp 之前 await 一次；失败就当空缓存。
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _resolveFile();
      if (file == null || !await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['v'] != _version) return;
      final entries = decoded['entries'];
      if (entries is! Map) return;
      entries.forEach((key, value) {
        if (key is String && value is Map) {
          final entry = CoverPaletteEntry.fromJson(value);
          if (entry != null) _entries[key] = entry;
        }
      });
      _trim();
    } catch (_) {
      // 缓存文件损坏/无权限：忽略，卡片会走原来的抽取流程。
    }
  }

  Future<File?> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    try {
      final dir = await getApplicationSupportDirectory();
      return _file = File('${dir.path}/$_fileName');
    } catch (_) {
      return null;
    }
  }

  CoverPaletteEntry? entry(String identity) => _entries[identity];

  /// 缓存命中且明暗模式一致时返回可直接绘制的 scheme。
  ColorScheme? schemeFor(String identity, Brightness brightness) {
    final entry = _entries[identity];
    if (entry == null || entry.brightness != brightness) return null;
    return entry.scheme;
  }

  double? luminanceFor(String identity) => _entries[identity]?.luminance;

  /// 封面的平均色（不是 Material 的 tonal primaryContainer）：冷启动第一帧
  /// 用它铺底，和封面本身的整体颜色一致，避免淡黄封面先闪成棕色。
  Color? averageColorFor(String identity) {
    final raw = _entries[identity]?.average;
    return raw == null ? null : Color(raw);
  }

  void storeAverageColor(String identity, Color color) {
    final old = _entries.remove(identity);
    _entries[identity] = CoverPaletteEntry(
      primary: old?.primary,
      primaryContainer: old?.primaryContainer,
      surface: old?.surface,
      onSurface: old?.onSurface,
      brightness: old?.brightness,
      luminance: old?.luminance,
      average: color.toARGB32(),
    );
    _trim();
    _markDirty();
  }

  void storeScheme(String identity, Brightness brightness, ColorScheme scheme) {
    final old = _entries.remove(identity);
    _entries[identity] = CoverPaletteEntry(
      primary: scheme.primary.toARGB32(),
      primaryContainer: scheme.primaryContainer.toARGB32(),
      surface: scheme.surface.toARGB32(),
      onSurface: scheme.onSurface.toARGB32(),
      brightness: brightness,
      luminance: old?.luminance,
      average: old?.average,
    );
    _trim();
    _markDirty();
  }

  void storeLuminance(String identity, double luminance) {
    final old = _entries.remove(identity);
    _entries[identity] = CoverPaletteEntry(
      primary: old?.primary,
      primaryContainer: old?.primaryContainer,
      surface: old?.surface,
      onSurface: old?.onSurface,
      brightness: old?.brightness,
      luminance: luminance,
      average: old?.average,
    );
    _trim();
    _markDirty();
  }

  void _trim() {
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void _markDirty() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () => unawaited(_flush()));
  }

  Future<void> _flush() async {
    final file = await _resolveFile();
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final payload = <String, dynamic>{
        'v': _version,
        'entries': {
          for (final entry in _entries.entries) entry.key: entry.value.toJson(),
        },
      };
      await file.writeAsString(jsonEncode(payload), flush: false);
    } catch (_) {
      // 写缓存失败不影响功能。
    }
  }
}

/// 一张封面缓存下来的可见配色 + 亮度。
class CoverPaletteEntry {
  CoverPaletteEntry({
    this.primary,
    this.primaryContainer,
    this.surface,
    this.onSurface,
    this.brightness,
    this.luminance,
    this.average,
  });

  final int? primary;
  final int? primaryContainer;
  final int? surface;
  final int? onSurface;
  final Brightness? brightness;
  final double? luminance;
  /// Mean cover colour; see [CoverPaletteCache.averageColorFor].
  final int? average;

  ColorScheme? _scheme;

  bool get hasScheme =>
      primary != null &&
      primaryContainer != null &&
      surface != null &&
      onSurface != null &&
      brightness != null;

  /// 卡片只用这四个角色；其余角色用 seed 方案补齐，保证首帧可绘制。
  ColorScheme? get scheme {
    if (!hasScheme) return null;
    return _scheme ??= ColorScheme.fromSeed(
      seedColor: Color(primary!),
      brightness: brightness!,
    ).copyWith(
      primary: Color(primary!),
      primaryContainer: Color(primaryContainer!),
      surface: Color(surface!),
      onSurface: Color(onSurface!),
    );
  }

  bool get isEmpty =>
      primary == null &&
      luminance == null &&
      brightness == null &&
      average == null;

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (primary != null) map['p'] = primary;
    if (primaryContainer != null) map['pc'] = primaryContainer;
    if (surface != null) map['s'] = surface;
    if (onSurface != null) map['o'] = onSurface;
    if (brightness != null) map['b'] = brightness!.name;
    if (luminance != null) map['l'] = luminance;
    if (average != null) map['a'] = average;
    return map;
  }

  static CoverPaletteEntry? fromJson(Map<dynamic, dynamic> json) {
    Brightness? brightness;
    final rawBrightness = json['b'];
    if (rawBrightness is String) {
      for (final value in Brightness.values) {
        if (value.name == rawBrightness) {
          brightness = value;
          break;
        }
      }
    }
    final entry = CoverPaletteEntry(
      primary: (json['p'] as num?)?.toInt(),
      primaryContainer: (json['pc'] as num?)?.toInt(),
      surface: (json['s'] as num?)?.toInt(),
      onSurface: (json['o'] as num?)?.toInt(),
      brightness: brightness,
      luminance: (json['l'] as num?)?.toDouble(),
      average: (json['a'] as num?)?.toInt(),
    );
    return entry.isEmpty ? null : entry;
  }
}
