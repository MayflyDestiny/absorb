import 'dart:async';

import 'package:flutter/foundation.dart';
import '../utils/fuzzy_search.dart';
import 'api_service.dart';
import 'json_file_cache.dart';
import 'scoped_prefs.dart';
import 'socket_service.dart';

/// A scored search result: the raw library item plus whether it matched on the
/// title (so callers can keep a "Books" section to title hits).
class BookSearchHit {
  final Map<String, dynamic> item;
  final double score;
  final bool titleMatch;
  const BookSearchHit(this.item, this.score, this.titleMatch);
}

class _Indexed {
  final Map<String, dynamic> item;
  final String normTitle;
  final List<String> titleTokens; // title + subtitle words
  final List<String> authorTokens;
  final List<String> seriesTokens;
  const _Indexed(this.item, this.normTitle, this.titleTokens, this.authorTokens,
      this.seriesTokens);
}

/// In-memory, per-library index of all book items, used for lenient client-side
/// search (out-of-order words, punctuation, typos) that the strict server
/// `/search` endpoint can't do. Built once per library per session, then kept
/// current by patching single entries from socket item events (edits, adds,
/// removals) - the payloads carry the full item, so no refetch is needed.
class BookSearchIndex {
  BookSearchIndex._() {
    SocketService()
      ..addItemUpdatedListener(_onItemUpdated)
      ..addItemRemovedListener(_onItemRemoved);
  }
  static final BookSearchIndex instance = BookSearchIndex._();
  factory BookSearchIndex() => instance;

  final Map<String, List<_Indexed>> _cache = {};
  final Map<String, Future<void>> _inFlight = {};
  // Libraries past the item cap are never indexed: the cap would cover a
  // sliver of them (4% of a 244k-book library) and fetching it is the heaviest
  // burst the app can put on a server. Search stays server-side for these.
  final Set<String> _serverOnly = {};
  // Libraries whose index is missing items because a page failed mid-build:
  // callers must merge the server's results in rather than replacing them, or
  // the missing books vanish from search for the session (GH #349 shape).
  final Set<String> _truncated = {};

  // ── 落盘 ──────────────────────────────────────────────
  // 索引只在内存里时，每次冷启动的第一次搜索都要重翻整个库（约 2000 条 /
  // 20 页 / 6 MB），这是搜索"刚打开就慢"的唯一原因。落盘后启动即用，与服务器
  // 的差异由几条通道收回：socket 的条目事件、回到前台时补拉最近更新的 50 条
  // （_lp_core 的 _catchUpAfterBackground）、总数核对，以及用户下拉刷新时的
  // 整库重建。

  /// 落盘格式版本。改了 [_indexItem] 的输入字段或存储结构就 +1，旧文件直接丢弃
  /// 重建，不做迁移。
  static const _persistVersion = 1;

  static String _persistKey(String libraryId) => 'search_index|$libraryId';

  /// 上次补了多少条也落盘：只放内存的话每次冷启动都是"没有历史"，第一次核对
  /// 又要从最小页探起，一批改动就要多绕一个请求。它是两个整数级别的字段，
  /// 不值得为它重写整份索引（MB 级），所以单独一个键。
  static String _changesKey(String libraryId) =>
      'search_index_changes|$libraryId';

  /// 服务器能力（是否按 updatedAt 排序）的落盘键。
  static String _capsKey(ApiService api) =>
      'search_incremental|${api.baseUrl}|${api.serverVersion ?? ''}';

  /// 每个库本次会话是否已经核对过一次。
  final Set<String> _revalidated = {};

  /// 本会话是否已经向服务器确认过"总数没变"。启动加载索引时的那次探针和
  /// "第一次搜索前"的那次共用它，同一会话不会重复发。
  final Set<String> _sessionProbed = {};

  /// 正在核对中的库，避免"自动核对"和"用户下拉刷新"同时翻同一批页。
  final Map<String, Future<void>> _revalidateFlight = {};

  /// 核对页的候选尺寸，从小到大。
  ///
  /// 每一页的尺寸按"还差多少才到上次的改动量"现算（见 [_pageSizeFor]），不是
  /// 整趟固定一个：什么都没变时只拉 25 条（实测 93 KB），改得多时才升到 50 / 100。
  static const _revalidatePageSizes = <int>[25, 50, 100];

  /// 一次核对最多扫这么多条。改动量再大就不按页追了——整库重建（约 6 MB）
  /// 比继续翻页更划算。
  static const _revalidateScanBudget = 500;

  /// 上次核对补了多少条，用来决定这次每页拉多大。
  final Map<String, int> _lastRevalidateChanges = {};

  /// 服务端是否真的按 `updatedAt` 倒序返回。
  ///
  /// 实测有实例直接忽略这个排序参数、回默认（文件系统）顺序——那种情况下
  /// "遇到旧条目就停"会漏掉后面真正改过的条目，等于索引永远不更新。所以先探
  /// 再用：拿到的第一页若不是按 updatedAt 非递增，就判它不支持。按
  /// `serverUrl|version` 记，一个服务器只探一次，结果落盘。
  final Map<String, bool> _incrementalSupported = {};

  /// 落盘索引里记下的条目总数，用来判断这次会话期间服务器是否增删过书。
  final Map<String, int> _persistedCount = {};

  void _onItemUpdated(Map<String, dynamic> item) => patchItem(item);

  /// Patch or insert a single item, e.g. from a socket event or the
  /// foreground catch-up sweep. No-op for libraries that aren't indexed yet -
  /// those build fresh on demand anyway.
  void patchItem(Map<String, dynamic> item) {
    final libId = item['libraryId'] as String?;
    final id = item['id'] as String?;
    if (libId == null || id == null) return;
    final idx = _cache[libId];
    if (idx == null) return;
    final entry = _indexItem(item);
    final i = idx.indexWhere((e) => e.item['id'] == id);
    if (i >= 0) {
      idx[i] = entry;
    } else {
      idx.add(entry);
    }
  }

  void _onItemRemoved(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    if (id == null) return;
    for (final idx in _cache.values) {
      idx.removeWhere((e) => e.item['id'] == id);
    }
  }

  /// Listeners told when an entry is dropped by [forgetItem] (open-and-heal),
  /// so a screen holding its own result list can filter it out live.
  final List<void Function(String itemId)> _forgottenListeners = [];

  void addForgottenListener(void Function(String itemId) cb) =>
      _forgottenListeners.add(cb);

  void removeForgottenListener(void Function(String itemId) cb) =>
      _forgottenListeners.remove(cb);

  /// 打开即自愈：用户点开了一条服务器上已经不存在的搜索结果。
  ///
  /// 从所有内存索引里剔除并通知监听者，让还挂在屏幕上的结果列表同步消失。
  /// 落盘索引**不动**——重写 MB 级文件只为一条幻影不值得，而且它对总数没有
  /// 影响；下一次下拉刷新（整库重建）自然会清掉。
  void forgetItem(String itemId) {
    var removed = false;
    for (final idx in _cache.values) {
      final before = idx.length;
      idx.removeWhere((e) => e.item['id'] == itemId);
      if (idx.length != before) removed = true;
    }
    if (!removed) return;
    debugPrint('[SearchIndex] dropped missing item $itemId (open-and-heal)');
    for (final cb in List.of(_forgottenListeners)) {
      cb(itemId);
    }
  }

  bool isReady(String libraryId) => _cache.containsKey(libraryId);

  /// True when the index is missing some of the library's items (a page failed
  /// to fetch while building), so results from it alone are incomplete.
  bool isTruncated(String libraryId) => _truncated.contains(libraryId);

  /// Drop everything (call on logout / account switch so a reused libraryId
  /// can't serve another account's items).
  void clear() {
    _cache.clear();
    _inFlight.clear();
    _serverOnly.clear();
    _truncated.clear();
    _lastRevalidateChanges.clear();
    _sessionProbed.clear();
  }

  /// Build the index for [libraryId] if not already cached. Concurrent callers
  /// share the same in-flight build. A failed fetch is not cached, so the next
  /// call retries. Libraries over the cap are remembered and never built, so
  /// this returns at once for them without a request.
  Future<void> ensureIndex(ApiService api, String libraryId) {
    if (_cache.containsKey(libraryId) || _serverOnly.contains(libraryId)) {
      return Future.value();
    }
    return _runOnce(libraryId, () => _loadOrBuild(api, libraryId));
  }

  /// One build per library at a time: a revalidation rebuild and a search that
  /// arrives in the middle of it must share the same pass, not fetch the whole
  /// library twice.
  Future<void> _runOnce(
    String libraryId,
    Future<void> Function() work,
  ) {
    final existing = _inFlight[libraryId];
    if (existing != null) return existing;
    final f = work();
    _inFlight[libraryId] = f;
    return f.whenComplete(() => _inFlight.remove(libraryId));
  }

  /// 落盘索引能用就用它（几乎立即可用），否则重建。命中磁盘时顺手在后台核对
  /// 一次总数，不阻塞调用方。
  Future<void> _loadOrBuild(ApiService api, String libraryId) async {
    if (await _loadPersisted(libraryId)) {
      unawaited(revalidate(api, libraryId));
      return;
    }
    await _build(api, libraryId);
  }

  Future<bool> _loadPersisted(String libraryId) async {
    if (_cache.containsKey(libraryId)) return true;
    final sw = Stopwatch()..start();
    try {
      // 不设年龄上限：落盘索引只有"结构变了"（版本号 / 条目为空 / 总数不符）
      // 或用户下拉刷新才作废，时间本身不构成理由。
      final data = await JsonFileCache.readMap(_persistKey(libraryId));
      if (data == null) return false;
      if ((data['v'] as num?)?.toInt() != _persistVersion) {
        debugPrint('[SearchIndex] $libraryId: stored index is an older '
            'format - rebuilding');
        return false;
      }
      final raw = data['items'];
      if (raw is! List || raw.isEmpty) return false;
      final items = <Map<String, dynamic>>[];
      for (final e in raw) {
        if (e is Map<String, dynamic> && e['id'] is String) items.add(e);
      }
      if (items.isEmpty) return false;
      _cache[libraryId] = items.map(_indexItem).toList();
      _persistedCount[libraryId] =
          (data['count'] as num?)?.toInt() ?? items.length;
      _truncated.remove(libraryId);
      // 上次的改动量，用来决定这次每页拉多大；拿不到就按最大页走。
      // 单独兜异常：读偏好失败不该把整个落盘索引判死、逼出一次整库重建。
      int? changes;
      try {
        changes = await ScopedPrefs.getInt(_changesKey(libraryId));
      } catch (e) {
        debugPrint('[SearchIndex] $libraryId: change count unreadable: $e');
      }
      if (changes != null) _lastRevalidateChanges[libraryId] = changes;
      debugPrint('[SearchIndex] $libraryId: ${items.length} items from disk '
          'in ${sw.elapsedMilliseconds}ms'
          '${changes == null ? '' : ', last check patched $changes'}');
      return true;
    } catch (e) {
      debugPrint('[SearchIndex] $libraryId: could not load the stored index: $e');
      return false;
    }
  }

  Future<void> _persist(String libraryId, int total) async {
    final items = _cache[libraryId]?.map((e) => e.item).toList();
    if (items == null || items.isEmpty) return;
    _persistedCount[libraryId] = total;
    try {
      await JsonFileCache.write(_persistKey(libraryId), {
        'v': _persistVersion,
        'count': total,
        'items': items,
      });
      debugPrint('[SearchIndex] $libraryId: stored ${items.length} items');
    } catch (e) {
      debugPrint('[SearchIndex] $libraryId: could not store the index: $e');
    }
  }

  /// 把索引与服务器对齐一次。用户主动刷新（下拉媒体库）时也走这里：会话内
  /// 的那一次核对只保证"这次启动之后对齐过"，而用户下拉时想看到的是"现在"。
  /// 同一书库同时只跑一趟，重复触发共用同一个 future。
  Future<void> revalidate(ApiService api, String libraryId) {
    final existing = _revalidateFlight[libraryId];
    if (existing != null) return existing;
    final f = _revalidateOnce(api, libraryId);
    _revalidateFlight[libraryId] = f;
    return f.whenComplete(() => _revalidateFlight.remove(libraryId));
  }

  Future<void> _revalidateOnce(ApiService api, String libraryId) async {
    if (_serverOnly.contains(libraryId)) return;
    if (!isReady(libraryId)) {
      // 还没有索引（首次安装 / 缓存被系统清掉）：建一次，它自己会核对。
      await ensureIndex(api, libraryId);
      return;
    }
    // 主动核对不看"本次会话已核对过"的标记。
    _revalidated.remove(libraryId);
    await _revalidate(api, libraryId);
  }

  /// 用户下拉刷新：**整库重新拉一遍并替换索引**，不是探针、不是增量。
  ///
  /// 这是唯一"保证现在就能搜到"的通道——改名、改标签、以及"删一本又加一本
  /// （总数不变）"这类探针和增量都看不见的改动，只有它能收回。代价是一次整库：
  /// 页数 = 条目数 / 100（94 本 1 页 313 KB，2000 本 20 页约 6 MB）。
  ///
  /// 失败不清空旧索引：[_build] 只在成功时替换缓存；期间搜索会走 [ensureIndex]
  /// 重试或回退服务端。
  Future<void> refresh(ApiService api, String libraryId) async {
    if (_serverOnly.contains(libraryId)) return;
    _cache.remove(libraryId);
    _truncated.remove(libraryId);
    _revalidated.remove(libraryId);
    debugPrint('[SearchIndex] $libraryId: pull-to-refresh - rebuilding');
    await _runOnce(libraryId, () => _build(api, libraryId));
  }

  /// 第一次搜索前确认一次：本会话还没探过就等这次探针结束再作答。
  ///
  /// 只有便宜的探针会被等（服务端不认 updatedAt 排序时约 250 ms）；认排序的
  /// 服务器增量在后台跑，不挡输入。已经探过（启动加载索引时那次）直接返回。
  Future<void> ensureFresh(ApiService api, String libraryId) async {
    if (_serverOnly.contains(libraryId)) return;
    if (!isReady(libraryId)) return;
    if (_sessionProbed.contains(libraryId)) return;
    final supported = await _readCaps(_capsKey(api));
    if (supported == true) {
      // 认 updatedAt 排序：增量核对在后台进行，不等它挡输入。
      return;
    }
    await probe(api, libraryId);
  }

  /// 只问一件事：服务器上的条目数还是不是我们建索引时那个数。
  ///
  /// 一致 → 什么都不做；不一致 → 整库重建（增删书之后逐条追没有意义）。同一库
  /// 同时只跑一趟，重复触发共用同一个 future。
  Future<void> probe(ApiService api, String libraryId) {
    if (_serverOnly.contains(libraryId)) return Future.value();
    final flight = _revalidateFlight[libraryId];
    if (flight != null) return flight;
    final f = _probeTotalOnce(api, libraryId);
    _revalidateFlight[libraryId] = f;
    return f.whenComplete(() => _revalidateFlight.remove(libraryId));
  }

  void _rememberChanges(String libraryId, int count) {
    _lastRevalidateChanges[libraryId] = count;
    unawaited(
      ScopedPrefs.setInt(_changesKey(libraryId), count).catchError((Object e) {
        debugPrint('[SearchIndex] $libraryId: could not store the change '
            'count: $e');
      }),
    );
  }

  /// 这一页拉多大。
  ///
  /// - 有上次的改动量 K：取「刚够盖到第 K+1 条」的最小尺寸，最后一页的零头
  ///   因此不超过 25 条。101 条是 `100 + 25`（125 条），不是 `100 + 100`。
  /// - 已经翻过 K（预估偏小）：取最大页推进，别在一条条 25 上磨。
  /// - 还没有任何记录（首次安装 / 偏好被清）：也取最大页——只多这一次，
  ///   和旧版持平；换成从 25 探起会让每次启动的第一次核对都多付一个来回。
  ///
  /// 尺寸必须在 {25, 50, 100} 里且能整除 [offset]：服务端的偏移严格等于
  /// `page × limit`（实测 page=1&limit=50 与 page=2&limit=25 指向同一条），
  /// 换尺寸时不能整除就会跳过一段。offset 一路都是 25 的倍数，所以退到 25 一定成立。
  int _pageSizeFor(int offset, int? expected, bool escalated) {
    var idx = _revalidatePageSizes.length - 1;
    if (!escalated && expected != null) {
      final want = expected - offset + 1;
      if (want > 0) {
        for (var i = 0; i < _revalidatePageSizes.length; i++) {
          if (_revalidatePageSizes[i] >= want) {
            idx = i;
            break;
          }
        }
      }
    }
    while (idx > 0 && offset % _revalidatePageSizes[idx] != 0) {
      idx--;
    }
    return _revalidatePageSizes[idx];
  }

  // ── 服务器能力 ──────────────────────────────────────

  Future<bool?> _readCaps(String key) async {
    final cached = _incrementalSupported[key];
    if (cached != null) return cached;
    try {
      final raw = await ScopedPrefs.getString(key);
      if (raw == '0' || raw == '1') {
        final value = raw == '1';
        _incrementalSupported[key] = value;
        return value;
      }
    } catch (e) {
      debugPrint('[SearchIndex] could not read server capability: $e');
    }
    return null;
  }

  void _rememberCaps(String key, bool supported) {
    _incrementalSupported[key] = supported;
    unawaited(
      ScopedPrefs.setString(key, supported ? '1' : '0').catchError((Object e) {
        debugPrint('[SearchIndex] could not store server capability: $e');
      }),
    );
  }

  /// 这一页是否按 `updatedAt` 非递增——用来验证服务端认不认 `sort=updatedAt`。
  bool _looksSortedByUpdatedAt(List<Map<String, dynamic>> items) {
    for (var i = 1; i < items.length; i++) {
      final prev = (items[i - 1]['updatedAt'] as num?)?.toInt() ?? 0;
      final cur = (items[i]['updatedAt'] as num?)?.toInt() ?? 0;
      if (prev < cur) return false;
    }
    return true;
  }

  Future<void> _rebuild(
      ApiService api, String libraryId, String reason) async {
    debugPrint('[SearchIndex] $libraryId: $reason - rebuilding');
    _cache.remove(libraryId);
    await _runOnce(libraryId, () => _build(api, libraryId));
  }

  /// 服务端不按 `updatedAt` 排序时的唯一通道：只取一条来核对 `total`
  /// （实测 7.2 KB / 约 250 ms，不是整页）。结构没变就什么都不做；结构变了或
  /// 索引截断才重建。
  ///
  /// 改名/改标签这类不改变总数的改动，靠 socket 事件收回，没有时间兜底。
  Future<void> _probeTotalOnce(
    ApiService api,
    String libraryId, {
    int? knownTotal,
  }) async {
    try {
      int? total = knownTotal;
      if (total == null) {
        final data = await api.getLibraryItems(libraryId,
            page: 0, limit: 1, sort: 'updatedAt', desc: 1);
        if (data == null) {
          // 失败不计入"本会话已探过"，下次还有机会；也绝不因此清空索引。
          debugPrint('[SearchIndex] $libraryId: probe skipped (no page)');
          return;
        }
        total = (data['total'] as num?)?.toInt();
      }
      _sessionProbed.add(libraryId);
      final known = _persistedCount[libraryId];
      if (total != null && known != null && total != known) {
        await _rebuild(api, libraryId, 'probe: $known -> $total items');
        return;
      }
      if (_truncated.contains(libraryId)) {
        await _rebuild(api, libraryId, 'index was truncated');
        return;
      }
      debugPrint('[SearchIndex] $libraryId: probe says $total items, '
          'index still in sync');
    } catch (e) {
      debugPrint('[SearchIndex] $libraryId: probe failed: $e');
    }
  }

  /// 把落盘以来服务器上的改动对齐进索引。
  ///
  /// 判据是条目自己的 `updatedAt`：索引里最新的那个时间戳就是水位线，比它新的
  /// 条目就是这期间被改过或新增的。服务端按 `updatedAt` 倒序分页，所以从第 0 页
  /// 往后翻，翻到出现同水位线或更旧的条目就可以停——需要补的只有那几条，不是
  /// 固定的一页。
  ///
  /// 这个前提不是所有服务器都成立（实测有实例忽略 `sort=updatedAt`），所以第一条
  /// 返回会顺手验证一次；不成立就永久降级到 [_probeTotalOnce]。
  Future<void> _revalidate(ApiService api, String libraryId) async {
    if (!_revalidated.add(libraryId)) return;
    final capsKey = _capsKey(api);
    final supported = await _readCaps(capsKey);
    if (supported == false) {
      await _probeTotalOnce(api, libraryId);
      return;
    }
    if (_truncated.contains(libraryId)) {
      // 上次构建有页失败，索引缺条目。增量补不回来，重建一次；重建成功后
      // 这个标记会自己清掉，不会每次都重建。
      await _rebuild(api, libraryId, 'index was truncated');
      return;
    }
    final watermark = _watermark(libraryId);
    final changed = <Map<String, dynamic>>[];
    final expected = _lastRevalidateChanges[libraryId];
    // 首探就整页全中，说明这次不是零星改动：后面直接按最大页推进。
    var escalated = false;
    var offset = 0;
    var fetched = 0;
    try {
      while (offset < _revalidateScanBudget) {
        final pageSize = _pageSizeFor(offset, expected, escalated);
        final data = await api.getLibraryItems(libraryId,
            page: offset ~/ pageSize,
            limit: pageSize,
            sort: 'updatedAt',
            desc: 1);
        if (data == null) {
          debugPrint('[SearchIndex] $libraryId: revalidate skipped (no page)');
          return;
        }
        int? pageTotal;
        if (offset == 0) {
          pageTotal = (data['total'] as num?)?.toInt();
          final known = _persistedCount[libraryId];
          if (pageTotal != null && known != null && pageTotal != known) {
            await _rebuild(api, libraryId, '$known -> $pageTotal items');
            return;
          }
        }
        final items = <Map<String, dynamic>>[];
        _collect(data, items);
        // 能力未知：用这一页顺手验证服务端有没有按 updatedAt 排序。不成立就
        // 立刻降级——这一页的顺序不可信，不能拿它判断边界，更不能 patch。
        if (offset == 0 && supported == null && items.length >= 2) {
          if (!_looksSortedByUpdatedAt(items)) {
            _rememberCaps(capsKey, false);
            debugPrint('[SearchIndex] $libraryId: server does not honour '
                'sort=updatedAt - incremental check disabled');
            await _probeTotalOnce(api, libraryId, knownTotal: pageTotal);
            return;
          }
          _rememberCaps(capsKey, true);
        }
        fetched += items.length;
        var older = 0;
        for (final item in items) {
          final ts = (item['updatedAt'] as num?)?.toInt();
          // 条目都没有时间戳时无从比较，退化成"这一页照单全收"——和以前按
          // 固定条数补的做法一致，只是不再假装知道哪些是新的。
          if (watermark == 0 || (ts != null && ts > watermark)) {
            changed.add(item);
          } else {
            older++;
          }
        }
        // 翻到了我们已经有的那一段：再往后只会更旧。
        if (watermark == 0 || items.length < pageSize || older > 0) {
          break;
        }
        // 探测页（比最大页小）都全中了：这次改动比预估多得多。别按
        // 25→25→50→100 一格格往上爬（offset=25 既整除不了 50 也整除不了 100，
        // 只能再走一次 25），直接从 0 重拉一页大的——前面那页会被它完整覆盖，
        // 丢掉即可，处理本身是幂等的，只是没必要重复计入。
        if (offset == 0 && pageSize < _revalidatePageSizes.last) {
          escalated = true;
          changed.clear();
          fetched = 0;
          continue;
        }
        offset += items.length;
      }
      if (offset >= _revalidateScanBudget) {
        // 整个窗口都是新的，说明这期间的改动比按页追还多，重建更划算。
        await _rebuild(api, libraryId, 'more than $offset items changed');
        return;
      }
      for (final item in changed) {
        patchItem(item);
      }
      _rememberChanges(libraryId, changed.length);
      debugPrint('[SearchIndex] $libraryId: revalidated - ${changed.length} '
          'changed items patched (scanned $fetched)');
    } catch (e) {
      debugPrint('[SearchIndex] $libraryId: revalidate failed: $e');
    }
  }

  /// 索引里最新的 `updatedAt`，即"我们已经同步到这里"的水位线。0 表示条目都
  /// 没有时间戳，那就只能整页照单全收（第一页之后按 `older > 0` 的规则停）。
  int _watermark(String libraryId) {
    var max = 0;
    for (final e in _cache[libraryId] ?? const <_Indexed>[]) {
      final ts = (e.item['updatedAt'] as num?)?.toInt();
      if (ts != null && ts > max) max = ts;
    }
    return max;
  }

  Future<void> _build(ApiService api, String libraryId) async {
    const pageSize = 100;
    const maxPages = 100; // ~10k items safety cap
    // Pages fetched at once. This used to fire every page in one go, which on
    // a 244k-book server queued a few hundred SQLite queries ahead of everything
    // else the app asked for (grid pages, the library list) until they all
    // timed out, and the server kept grinding through them after the phone
    // had given up.
    const concurrency = 3;

    final first =
        await api.getLibraryItems(libraryId, page: 0, limit: pageSize);
    if (first == null) return; // offline / error: leave uncached for retry
    final items = <Map<String, dynamic>>[];
    _collect(first, items);
    final total = (first['total'] as num?)?.toInt() ?? items.length;
    final pages = (total / pageSize).ceil();
    if (pages > maxPages) {
      _serverOnly.add(libraryId);
      debugPrint('[BookSearchIndex] $libraryId has $total items, over the '
          '${maxPages * pageSize} cap - not indexing, search stays server-side.');
      return;
    }

    final fetched = <int, Map<String, dynamic>>{};
    var failed = false;
    var next = 1;
    Future<void> worker() async {
      while (next < pages) {
        final p = next++;
        var pd = await api.getLibraryItems(libraryId, page: p, limit: pageSize);
        pd ??= await api.getLibraryItems(libraryId, page: p, limit: pageSize);
        if (pd == null) {
          failed = true;
        } else {
          fetched[p] = pd;
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    for (var p = 1; p < pages; p++) {
      final pd = fetched[p];
      if (pd != null) _collect(pd, items);
    }
    if (failed) {
      _truncated.add(libraryId);
      debugPrint('[BookSearchIndex] $libraryId: some pages failed, indexed '
          '${items.length} of $total. Callers merge server results.');
    } else {
      _truncated.remove(libraryId);
    }
    _cache[libraryId] = items.map(_indexItem).toList();
    // 整库刚重建过，"上次补了多少条"已经没有参考价值，下一趟从最小页开始。
    _rememberChanges(libraryId, 0);
    if (!_truncated.contains(libraryId)) {
      unawaited(_persist(libraryId, total));
    }
  }

  void _collect(Map<String, dynamic> page, List<Map<String, dynamic>> out) {
    final results = page['results'] as List<dynamic>? ?? [];
    for (final r in results) {
      final m = (r['libraryItem'] ?? r);
      if (m is Map<String, dynamic>) out.add(m);
    }
  }

  _Indexed _indexItem(Map<String, dynamic> item) {
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final md = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = md['title'] as String? ?? '';
    final subtitle = md['subtitle'] as String? ?? '';
    final author = md['authorName'] as String? ?? '';
    final series = md['seriesName'] as String? ?? '';
    final normTitle = normalizeForSearch(title);
    final titleTokens = tokenize(
        subtitle.isEmpty ? normTitle : '$normTitle ${normalizeForSearch(subtitle)}'.trim());
    return _Indexed(
      item,
      normTitle,
      titleTokens,
      tokenize(normalizeForSearch(author)),
      tokenize(normalizeForSearch(series)),
    );
  }

  /// Every item indexed so far this session, across libraries.
  Iterable<Map<String, dynamic>> get indexedItems =>
      _cache.values.expand((list) => list.map((e) => e.item));

  List<BookSearchHit> search(String libraryId, String query, {int limit = 40}) {
    final idx = _cache[libraryId];
    if (idx == null) return const [];
    final normQuery = normalizeForSearch(query);
    final qTokens = tokenize(normQuery);
    if (qTokens.isEmpty) return const [];
    final hits = <BookSearchHit>[];
    for (final e in idx) {
      final r = scoreTokens(
        qTokens: qTokens,
        normQuery: normQuery,
        normTitle: e.normTitle,
        titleTokens: e.titleTokens,
        authorTokens: e.authorTokens,
        seriesTokens: e.seriesTokens,
      );
      if (r != null) hits.add(BookSearchHit(e.item, r.score, r.titleMatch));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }
}
