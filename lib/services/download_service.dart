import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../l10n/app_localizations.dart';
import '../main.dart' show rootNavigatorKey;
import 'api_service.dart';
import 'audio_player_service.dart';
import 'ebook_cache.dart';
import 'offline_source.dart';

enum DownloadStatus { none, downloading, downloaded, error, paused }

class DownloadInfo {
  final String itemId;
  final DownloadStatus status;
  final double progress;
  final List<String> localPaths;
  final String? sessionData;
  // Metadata for offline display
  final String? title;
  final String? author;
  final String? coverUrl;
  final String? localCoverPath;
  final String? localDirPath;
  final String? libraryId;

  DownloadInfo({
    required this.itemId,
    this.status = DownloadStatus.none,
    this.progress = 0,
    this.localPaths = const [],
    this.sessionData,
    this.title,
    this.author,
    this.coverUrl,
    this.localCoverPath,
    this.localDirPath,
    this.libraryId,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'status': status.index,
        'localPaths': localPaths,
        'sessionData': sessionData,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'localCoverPath': localCoverPath,
        if (localDirPath != null) 'localDirPath': localDirPath,
        if (libraryId != null) 'libraryId': libraryId,
      };

  factory DownloadInfo.fromJson(Map<String, dynamic> json) {
    String? title = json['title'] as String?;
    String? author = json['author'] as String?;
    String? coverUrl = json['coverUrl'] as String?;

    // Fallback: extract metadata from cached sessionData for old downloads
    if ((title == null || title.isEmpty) && json['sessionData'] != null) {
      try {
        final session = jsonDecode(json['sessionData'] as String) as Map<String, dynamic>;
        // Try session-level metadata first
        final sessionMeta = session['mediaMetadata'] as Map<String, dynamic>?;
        if (sessionMeta != null) {
          title ??= sessionMeta['title'] as String?;
          author ??= sessionMeta['authorName'] as String?;
        }
        // Try libraryItem path
        if (title == null || title.isEmpty) {
          final libItem = session['libraryItem'] as Map<String, dynamic>? ?? {};
          final media = libItem['media'] as Map<String, dynamic>? ?? {};
          final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
          title ??= metadata['title'] as String?;
          author ??= metadata['authorName'] as String?;
        }
        // Try direct displayTitle/displayAuthor
        title ??= session['displayTitle'] as String?;
        author ??= session['displayAuthor'] as String?;
      } catch (_) {}
    }

    return DownloadInfo(
      itemId: json['itemId'] as String,
      status: DownloadStatus.values[json['status'] as int? ?? 0],
      localPaths: (json['localPaths'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      sessionData: _stripLibraryItem(json['sessionData'] as String?),
      title: title,
      author: author,
      coverUrl: coverUrl,
      localCoverPath: json['localCoverPath'] as String?,
      localDirPath: json['localDirPath'] as String?,
      libraryId: json['libraryId'] as String?,
    );
  }
}

class _QueuedDownload {
  final ApiService api;
  final String itemId;
  final String title;
  final String? author;
  final String? coverUrl;
  final String? episodeId;
  final String? libraryId;
  /// Chapter indices the user picked, or null for the whole item.
  final List<int>? selectedChapters;

  _QueuedDownload({
    required this.api,
    required this.itemId,
    required this.title,
    this.author,
    this.coverUrl,
    this.episodeId,
    this.libraryId,
    this.selectedChapters,
  });
}

/// An in-flight multi-file download. The static fields (persisted to
/// SharedPreferences) carry everything needed to finalize the book even if the
/// app is killed and relaunched while the OS finishes the transfer. The runtime
/// maps are rebuilt from the background_downloader task database on relaunch.
class _PendingBook {
  final String itemId;        // composite key used in _downloads
  final String apiItemId;     // real library item id for API calls
  final String? episodeId;
  final String title;
  final String? author;
  final String? coverUrl;
  final String? localCoverPath;
  final String? libraryId;
  final String bookDir;
  final int trackCount;
  final List<String> expectedPaths; // index-aligned final file paths
  final String? slimSessionJson;
  /// When set, this book downloads to internal storage first, then its files
  /// are moved into the user's SAF folder ([safTreeUri]) under [safSubfolder]
  /// (e.g. "Author/Title") on completion. Null for internal / iOS downloads.
  final String? safTreeUri;
  final String? safSubfolder;

  /// Chapter indices the user picked when this download started, or null for
  /// the whole item. Kept so a resume that has to restart from scratch keeps
  /// the original (partial) selection.
  final List<int>? selectedChapters;

  /// True once the user cancels, so terminal handling cleans up instead of
  /// surfacing an error.
  bool cancelled = false;

  /// True when the user pauses this download. Track tasks get cancelled but
  /// their partial files are kept, the slot is released, and the item is
  /// surfaced in the Downloads screen's paused section until resumed.
  bool paused = false;

  /// Set synchronously the moment a terminal handler (success/fail/cancel) is
  /// chosen, so a burst of terminal updates can't finalize the book twice.
  bool finalizing = false;

  /// A hard track failure aborts the whole book; remember why for the message.
  bool failing = false;
  TaskException? failException;
  int? failCode;

  final Map<int, double> trackProgress = {};
  final Map<int, TaskStatus> trackStatus = {};
  DateTime lastUi = DateTime.fromMillisecondsSinceEpoch(0);
  /// Throttle state for the byte-accurate notification overlay.
  int notifPct = -1;
  int notifDone = -1;
  DateTime notifPost = DateTime.fromMillisecondsSinceEpoch(0);
  /// Last time any track update arrived, so the slot-leak reconciler can spot a
  /// book whose terminal updates were missed.
  DateTime lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// True when this book's files get moved into a SAF folder on completion.
  bool get isSaf => safTreeUri != null;

  _PendingBook({
    required this.itemId,
    required this.apiItemId,
    required this.title,
    required this.bookDir,
    required this.trackCount,
    required this.expectedPaths,
    this.episodeId,
    this.author,
    this.coverUrl,
    this.localCoverPath,
    this.libraryId,
    this.slimSessionJson,
    this.safTreeUri,
    this.safSubfolder,
    this.selectedChapters,
  }) {
    // Start the no-progress watchdog clock at creation (fresh or restored).
    lastUpdate = DateTime.now();
  }

  double get overallProgress {
    if (trackCount == 0) return 0;
    var sum = 0.0;
    for (int i = 0; i < trackCount; i++) {
      sum += trackProgress[i] ?? 0.0;
    }
    return (sum / trackCount).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'apiItemId': apiItemId,
        'episodeId': episodeId,
        'title': title,
        'author': author,
        'coverUrl': coverUrl,
        'localCoverPath': localCoverPath,
        'libraryId': libraryId,
        'bookDir': bookDir,
        'trackCount': trackCount,
        'expectedPaths': expectedPaths,
        'slimSessionJson': slimSessionJson,
        if (safTreeUri != null) 'safTreeUri': safTreeUri,
        if (safSubfolder != null) 'safSubfolder': safSubfolder,
        if (selectedChapters != null) 'selectedChapters': selectedChapters,
        'paused': paused,
      };

  factory _PendingBook.fromJson(Map<String, dynamic> j) => _PendingBook(
        itemId: j['itemId'] as String,
        apiItemId: j['apiItemId'] as String,
        episodeId: j['episodeId'] as String?,
        title: j['title'] as String? ?? '',
        author: j['author'] as String?,
        coverUrl: j['coverUrl'] as String?,
        localCoverPath: j['localCoverPath'] as String?,
        libraryId: j['libraryId'] as String?,
        bookDir: j['bookDir'] as String,
        trackCount: j['trackCount'] as int? ?? 0,
        expectedPaths: (j['expectedPaths'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
        slimSessionJson: j['slimSessionJson'] as String?,
        safTreeUri: j['safTreeUri'] as String?,
        safSubfolder: j['safSubfolder'] as String?,
        selectedChapters: (j['selectedChapters'] as List<dynamic>?)
            ?.map((e) => (e as num).toInt())
            .toList(),
      )
        ..paused = j['paused'] as bool? ?? false;
}

/// One audio file belonging to a downloaded item, surfaced by
/// [DownloadService.getLocalTracks] for per-track management (view size,
/// delete individual episodes).
class LocalTrackInfo {
  const LocalTrackInfo({
    required this.index,
    required this.path,
    required this.title,
    required this.sizeBytes,
    required this.exists,
    this.durationSeconds = 0,
    this.absoluteStart = 0,
    this.downloadedAt,
  });

  /// Aligned with [DownloadInfo.localPaths], `audioTracks`, and the encoded
  /// track order used for offline playback.
  final int index;
  final String path;
  final String title;
  final int sizeBytes;
  final bool exists;

  /// Length of this file, or 0 when the metadata isn't available.
  final double durationSeconds;

  /// Where this file starts on the full-book timeline. Equals the cumulative
  /// length of the preceding files for contiguous downloads, and the stored
  /// `trackStartOffsets` value for partial ones (so gaps are preserved).
  final double absoluteStart;

  /// File's last-modified time, used as a stand-in for when it was downloaded.
  /// Null for SAF (content URI) files, whose timestamp isn't readable.
  final DateTime? downloadedAt;

  bool get isSaf => isContentUri(path);
}

/// Trim the bulky parts of the persisted `libraryItem` while keeping the bits
/// offline features need. Drops `media.episodes` (a podcast's full episode list
/// is hundreds of KB) and `media.audioFiles` (the server file list, unused for
/// local playback), but KEEPS `media.metadata` (so offline series auto-advance
/// still knows the book's series + sequence), `duration`, and `chapters` (so the
/// now-playing UI is correct).
String? _stripLibraryItem(String? sessionJson) {
  if (sessionJson == null) return null;
  try {
    final session = jsonDecode(sessionJson) as Map<String, dynamic>;
    final libItem = session['libraryItem'] as Map<String, dynamic>?;
    if (libItem == null) return sessionJson;
    final media = libItem['media'] as Map<String, dynamic>?;
    if (media != null) {
      media.remove('episodes');
      media.remove('audioFiles');
    }
    return jsonEncode(session);
  } catch (_) {}
  return sessionJson;
}

/// Compact a persisted session down to the fields offline playback actually
/// reads, so the `.absorb` marker stays tiny: per track only index/duration/
/// title/mimeType and the original filename survive; server-only URL fields and
/// the bulky track objects are dropped.
String? _compactMarkerSession(String? sessionJson) {
  if (sessionJson == null) return null;
  try {
    final session = jsonDecode(sessionJson) as Map<String, dynamic>;
    final tracks = (session['audioTracks'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];
    if (tracks.isEmpty) return sessionJson;
    session['audioTracks'] = [
      for (final t in tracks)
        () {
          final trimmed = <String, dynamic>{
            'index': t['index'],
            'duration': t['duration'],
            'title': t['title'],
          };
          if (t['mimeType'] != null) trimmed['mimeType'] = t['mimeType'];
          final trackMeta = t['metadata'];
          if (trackMeta is Map && trackMeta['filename'] != null) {
            trimmed['metadata'] = {'filename': trackMeta['filename']};
          }
          return trimmed;
        }(),
    ];
    return jsonEncode(session);
  } catch (_) {
    return sessionJson;
  }
}

/// Encode a marker payload so it stays small and ASCII-safe on disk:
/// gzip + base64 with a `gz1:` prefix (old plain-JSON markers remain parseable).
String _encodeMarker(String json) =>
    'gz1:${base64Encode(gzip.encode(utf8.encode(json)))}';

/// Decode a marker written by [_encodeMarker], falling back to plain JSON for
/// legacy markers. Returns null when a gzipped marker fails to decode.
String? _decodeMarker(String content) {
  if (content.startsWith('gz1:')) {
    try {
      return utf8.decode(gzip.decode(base64Decode(content.substring(4))));
    } catch (_) {
      return null;
    }
  }
  return content;
}

/// Sanitize a string for use as a filesystem directory/file name.
String _sanitizePath(String name) {
  // Replace filesystem-illegal characters with underscore
  var s = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  // Collapse multiple underscores/spaces
  s = s.replaceAll(RegExp(r'[_\s]+'), ' ').trim();
  // Fallback for empty result
  if (s.isEmpty) s = 'Unknown';
  // Limit length to avoid filesystem issues
  if (s.length > 100) s = s.substring(0, 100).trim();
  return s;
}

/// Check whether [dirUri] (a SAF document URI for a nested folder) lies inside
/// the tree granted by [treeUri]. Both share the same authority and the
/// decoded document id either equals the tree id or starts with it plus a
/// separator (the id encodes `/` as `%2F`, so compare after decoding).
bool _sameSafTree(String treeUri, String dirUri) {
  if (dirUri.isEmpty) return false;
  Uri? tree;
  Uri? dir;
  try {
    tree = Uri.parse(treeUri);
    dir = Uri.parse(dirUri);
  } catch (_) {
    return false;
  }
  if (tree.authority != dir.authority) return false;
  String? treeId;
  String? docId;
  final tSegs = tree.pathSegments;
  final dSegs = dir.pathSegments;
  for (var i = 0; i < tSegs.length - 1; i++) {
    if (tSegs[i] == 'tree') {
      treeId = Uri.decodeComponent(tSegs[i + 1]);
      break;
    }
  }
  for (var i = 0; i < dSegs.length - 1; i++) {
    if (dSegs[i] == 'document') {
      docId = Uri.decodeComponent(dSegs[i + 1]);
      break;
    }
  }
  if (treeId == null || docId == null) return false;
  return docId == treeId || docId.startsWith('$treeId/');
}

class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._()
      : _initializeOverride = null,
        _cancelTasksOverride = null,
        _deleteTaskRecordOverride = null;

  @visibleForTesting
  DownloadService.forTesting({
    required Future<void> Function() initialize,
    Future<void> Function(List<String>)? cancelTasks,
    Future<void> Function(String)? deleteTaskRecord,
  })  : _initializeOverride = initialize,
        _cancelTasksOverride = cancelTasks,
        _deleteTaskRecordOverride = deleteTaskRecord;

  final Future<void> Function()? _initializeOverride;
  final Future<void> Function(List<String>)? _cancelTasksOverride;
  final Future<void> Function(String)? _deleteTaskRecordOverride;
  Future<void>? _initFuture;
  Future<void>? _iosAudioMigrationFuture;
  bool _initialized = false;

  /// Set to true (before init) by short-lived background isolates like the
  /// episode-notification job. Downloads then run as plain background tasks
  /// instead of in the foreground service: Android 15+ kills a dataSync
  /// foreground service started while the app is in the background almost
  /// immediately ("FGS (dataSync) timed out"), leaving the task stuck at 0%.
  static bool backgroundIsolateMode = false;

  final Map<String, DownloadInfo> _downloads = {};

  // Cached saved/total chapter counts per downloaded item, keyed by the source
  // session string so a re-download (new session) recomputes. Avoids JSON
  // parsing + file I/O on every library grid build.
  final Map<String, ({String? src, int saved, int total})> _chapterCountCache = {};

  // Cached downloaded-chapter index sets per item, keyed the same way (source
  // session string). The overlap scan is O(chapters × tracks) over a full
  // session JSON decode — far too heavy to re-run on every hot card/menu build
  // while a multi-hundred-chapter book is loaded, so memoize it.
  final Map<String, ({String? src, Set<int> indices})> _chapterIndicesCache = {};

  // Items whose stored cover was already checked (and upgraded if it was an
  // old 400px thumbnail) this session - see enrichMetadata.
  final Set<String> _coverUpgradeChecked = {};
  final Set<String> _activeDownloadIds = {};
  final Set<String> _cancelledIds = {};
  /// SAF tree URI (content://) for the Android custom download folder, or null
  /// to use internal storage. This is the only custom-location mechanism now;
  /// the old raw-path approach (MANAGE_EXTERNAL_STORAGE) is gone.
  String? _customDownloadUri;
  /// Downloaded items still pointing at raw external paths from before the SAF
  /// switch. Unreadable without the dropped storage permission, so they're kept
  /// listed for the user to re-download rather than silently deleted.
  final Set<String> _legacyExternalIds = {};

  /// All `background_downloader` tasks share this group for update routing.
  /// Notifications are configured per task at enqueue time (one notification
  /// per book); the group-level config is only a fallback.
  static const String _dlGroup = 'absorb_downloads';

  /// In-flight books keyed by itemId. Holds everything needed to aggregate
  /// per-track progress and finalize the book, including after an app relaunch.
  final Map<String, _PendingBook> _pending = {};

  StreamSubscription<TaskUpdate>? _updatesSub;
  bool _downloaderConfigured = false;

  /// Periodically reconverges in-flight books with the package task DB so a
  /// missed terminal update can't leave a slot leaked and wedge the queue.
  Timer? _reconcileTimer;

  /// Queue of pending download requests.
  final List<_QueuedDownload> _queue = [];

  // Items the user deleted by hand. Every auto-download planner (rolling
  // series and show, queue window, playlist and collection, new subscribed
  // episodes) funnels through [downloadItem] with automatic: true and skips
  // these, so a half-finished book that was deleted stops coming back on the
  // next launch. Global like the downloads themselves, not per account.
  final Set<String> _autoDownloadBlocked = {};

  /// True when the user deleted this download, so an automatic download of it
  /// would be skipped. Callers that count or announce downloads need to know
  /// before they call, or they announce work that never happens.
  bool isAutoDownloadBlocked(String itemId) =>
      _autoDownloadBlocked.contains(itemId);
  static const _autoDownloadBlockedKey = 'auto_download_blocked';

  /// The current Android SAF folder URI (content://), or null if using default.
  String? get customDownloadUri => _customDownloadUri;

  /// Items left pointing at unreadable raw external paths from before SAF.
  List<DownloadInfo> get legacyExternalDownloads =>
      _legacyExternalIds.map((id) => _downloads[id]).whereType<DownloadInfo>().toList();

  /// Get the effective default (non-custom) download base directory.
  ///
  /// Android custom folders no longer use a filesystem base path - they go
  /// through SAF ([_customDownloadUri]) in the task builder. This getter now
  /// only resolves the built-in location: the iOS app group container (so the
  /// widget extension and native player core can read it; falls back to
  /// Documents/ if the app group lookup fails) or Android internal storage.
  Future<String> get downloadBasePath async {
    if (Platform.isIOS) {
      final groupPath = await _iosAppGroupAudioBase();
      if (groupPath != null) return groupPath;
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/downloads';
  }

  /// Always returns the internal app directory for cover caching.
  /// Covers are stored here even when audio uses a custom external path,
  /// because external storage may have permission restrictions.
  Future<String> get _internalBasePath async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/downloads';
  }

  /// Set the Android SAF custom download folder. Pass null to revert to default.
  Future<void> setCustomDownloadUri(Uri? uri) async {
    _customDownloadUri = uri?.toString();
    final prefs = await SharedPreferences.getInstance();
    if (_customDownloadUri != null && _customDownloadUri!.isNotEmpty) {
      await prefs.setString('custom_download_uri', _customDownloadUri!);
    } else {
      await prefs.remove('custom_download_uri');
    }
    notifyListeners();
  }

  /// Whether the one-time "pick a public download folder" first-run prompt
  /// should show: Android only, never set a custom folder, and not dismissed
  /// before. The prompt guides new users out of the app-private storage where
  /// clearing app data deletes their downloads.
  static const _locationPromptSeenKey = 'download_location_prompt_seen';

  Future<bool> shouldShowFirstRunLocationPrompt() async {
    if (!Platform.isAndroid) return false;
    if (_customDownloadUri != null && _customDownloadUri!.isNotEmpty) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_locationPromptSeenKey) != true;
  }

  /// Persist that the first-run location prompt was shown/dismissed.
  Future<void> markFirstRunLocationPromptSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_locationPromptSeenKey, true);
  }

  /// Move every completed download to a new location.
  ///
  /// [treeUri] non-null: files move into that SAF folder under
  /// "Author/Title" (matching where new downloads land). [treeUri] null: files
  /// move back to the internal default storage. Sources may be internal file
  /// paths or existing content:// URIs, so internal→SAF, SAF→SAF and SAF→
  /// internal migrations all work. Returns how many downloads were moved.
  Future<int> migrateAllDownloads({String? treeUri}) async {
    if (!Platform.isAndroid) return 0;
    var migrated = 0;
    final items =
        _downloads.values.where((d) => d.status == DownloadStatus.downloaded).toList();
    for (final info in items) {
      if (info.localPaths.isEmpty) continue;
      if (await _migrateOneDownload(info, treeUri)) migrated++;
    }
    if (migrated > 0) notifyListeners();
    return migrated;
  }

  /// Scan a SAF download folder for previously downloaded books and register
  /// those the app recognizes (via the `.absorb` marker written at download /
  /// migrate time) back into the downloads registry, so they show as downloaded
  /// and stay playable offline. Folders with audio files but no marker are only
  /// counted, never registered. A one-off, dependency-free walk: the native side
  /// reads only the small marker files, never the audio bytes, and it only runs
  /// when the user picks a folder. Returns how many books were recognized and
  /// how many audio-bearing folders had no marker.
  Future<({int recognized, int unknown})> scanAndRegisterExistingDownloads(
      String treeUri) async {
    if (!Platform.isAndroid) return (recognized: 0, unknown: 0);
    Map? res;
    try {
      res = await _storageChannel.invokeMethod<Map>('scanSafDirectory', {
        'treeUri': treeUri,
      });
    } catch (e) {
      debugPrint('[Download] scanSafDirectory failed: $e');
      return (recognized: 0, unknown: 0);
    }
    final known = (res?['known'] as List<dynamic>?) ?? const <dynamic>[];
    var recognized = 0;
    final alreadySeen = <String>{};
    for (final entry in known.cast<Map>()) {
      final dirUri = entry['dirUri'] as String?;
      final marker = entry['marker'] as String?;
      final fileUris = (entry['fileUris'] as List<dynamic>?)?.cast<String>() ?? const [];
      if (dirUri == null || marker == null || marker.isEmpty || fileUris.isEmpty) {
        continue;
      }
      try {
        final decoded = _decodeMarker(marker);
        if (decoded == null) continue;
        final m = jsonDecode(decoded) as Map<String, dynamic>;
        final itemId = m['itemId'] as String?;
        if (itemId == null || itemId.isEmpty) continue;
        // Prefer the marker's title/author/session; use the current registry
        // entry when this book is already known (fresh download metadata).
        final existing = _downloads[itemId];
        final session = (m['session'] as String?) ?? existing?.sessionData;
        final title = (m['title'] as String?) ?? existing?.title;
        final author = (m['author'] as String?) ?? existing?.author;
        if (alreadySeen.contains(itemId)) continue;
        alreadySeen.add(itemId);
        _downloads[itemId] = DownloadInfo(
          itemId: itemId,
          status: DownloadStatus.downloaded,
          localPaths: fileUris,
          sessionData: session,
          title: title,
          author: author,
          coverUrl: m['coverUrl'] as String? ?? existing?.coverUrl,
          localCoverPath: existing?.localCoverPath,
          localDirPath: dirUri,
          libraryId: m['libraryId'] as String? ?? existing?.libraryId,
        );
        recognized++;
      } catch (e) {
        debugPrint('[Download] scan entry failed: $e');
      }
    }
    if (recognized > 0) {
      await _save();
      notifyListeners();
    }
    final unknown = (res?['unknownCount'] as num?)?.toInt() ?? 0;
    return (recognized: recognized, unknown: unknown);
  }

  Future<bool> _migrateOneDownload(DownloadInfo info, String? treeUri) async {
    final sources = info.localPaths;

    // Skip items that already live at the destination: internal downloads when
    // reverting to default, and SAF downloads already inside the target tree
    // (moving a folder onto itself would delete the files).
    if (treeUri == null) {
      if (sources.every((s) => !isContentUri(s))) return true;
    } else if (sources.every(isContentUri) &&
        _sameSafTree(treeUri, info.localDirPath ?? '')) {
      return true;
    }

    // Nested target folder, using the same layout the downloader produces.
    final title = info.title ?? info.itemId;
    final nestedName = (info.author != null && info.author!.isNotEmpty)
        ? '${_sanitizePath(info.author!)}/${_sanitizePath(title)}'
        : _sanitizePath(title);

    // Filename fallbacks. Internal paths keep their basename; the native side
    // prefers the real display name from content URIs, so these only matter if
    // that lookup fails.
    final filenames = <String>[];
    for (var i = 0; i < sources.length; i++) {
      if (!isContentUri(sources[i])) {
        filenames.add(sources[i].split(RegExp(r'[\\/]')).last);
      } else {
        filenames.add(_migrationFallbackName(info, i));
      }
    }

    final String? targetDir;
    if (treeUri == null) {
      final base = await downloadBasePath;
      targetDir = '$base/$nestedName';
    } else {
      targetDir = null;
    }

    try {
      // Carry a marker into a SAF destination so a later scan still recognizes
      // the moved book; internal destinations don't need one. The marker
      // includes the persisted session so a scan can restore the book offline.
      final marker = treeUri != null
          ? _encodeMarker(jsonEncode({
              'itemId': info.itemId,
              'title': info.title ?? info.itemId,
              'author': info.author,
              'libraryId': info.libraryId,
              'coverUrl': info.coverUrl,
              'session': _compactMarkerSession(info.sessionData),
            }))
          : null;
      final res = await _storageChannel.invokeMethod<Map>('migrateBook', {
        'sources': sources,
        'filenames': filenames,
        'subfolder': nestedName,
        'treeUri': treeUri,
        'targetDir': targetDir,
        if (marker != null) 'marker': marker,
      });
      final newPaths = treeUri != null
          ? (res?['fileUris'] as List?)?.map((e) => e as String).toList()
          : (res?['filePaths'] as List?)?.map((e) => e as String).toList();
      final newDir = treeUri != null
          ? (res?['dirUri'] as String?)
          : (res?['dirPath'] as String?);
      if (newPaths == null || newPaths.length != sources.length || newDir == null) {
        debugPrint('[Download] migrate "$title": result missing files, keeping source');
        return false;
      }

      _downloads[info.itemId] = DownloadInfo(
        itemId: info.itemId,
        status: DownloadStatus.downloaded,
        localPaths: newPaths,
        sessionData: info.sessionData,
        title: info.title,
        author: info.author,
        coverUrl: info.coverUrl,
        localCoverPath: info.localCoverPath,
        localDirPath: newDir,
        libraryId: info.libraryId,
      );
      await _save();
      debugPrint('[Download] migrated "$title" (${sources.length} files)');
      return true;
    } catch (e) {
      debugPrint('[Download] migrate "$title" failed: $e');
      return false;
    }
  }

  /// Best-effort filename for a content:// source when the native display-name
  /// lookup fails. Uses the track's original filename when stored, else a
  /// generic per-track name.
  String _migrationFallbackName(DownloadInfo info, int i) {
    if (info.sessionData != null) {
      try {
        final s = jsonDecode(info.sessionData!) as Map<String, dynamic>;
        final tracks = (s['audioTracks'] as List<dynamic>?) ?? const [];
        if (i < tracks.length && tracks[i] is Map<String, dynamic>) {
          return _trackFileName(tracks[i] as Map<String, dynamic>, i);
        }
      } catch (_) {}
    }
    return 'track_${i.toString().padLeft(3, '0')}.mp3';
  }

  /// Get a human-readable label for the current download location.
  Future<String> get downloadLocationLabel async {
    final uri = _customDownloadUri;
    if (uri != null && uri.isNotEmpty) return _friendlySafLabel(uri);
    return 'App Internal Storage (Default)';
  }

  /// Turn a SAF tree URI into a friendly folder name. Tree URIs encode the
  /// location in their last path segment, e.g.
  /// `.../tree/primary%3ADownload%2FAudiobooks` -> `Download/Audiobooks`.
  String _friendlySafLabel(String uriString) {
    try {
      final uri = Uri.parse(uriString);
      var docId =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uriString;
      docId = Uri.decodeComponent(docId);
      final colon = docId.indexOf(':');
      final rel = colon >= 0 ? docId.substring(colon + 1) : docId;
      return rel.isEmpty ? docId : rel;
    } catch (_) {
      return uriString;
    }
  }

  /// Calculate total size of all downloaded files.
  Future<int> get totalDownloadSize async {
    await hydrateEbookCacheDir();
    int total = 0;
    for (final info in _downloads.values) {
      if (info.status == DownloadStatus.downloaded) {
        for (final path in info.localPaths) {
          if (isContentUri(path)) continue; // SAF audio not counted in the tally
          try {
            final file = File(path);
            if (file.existsSync()) {
              total += file.lengthSync();
            }
          } catch (_) {}
        }
        total += cachedEbookBytesSync(info.itemId);
      }
    }
    return total;
  }

  /// Calculate total file size for a single download item.
  int getItemFileSize(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return 0;
    int total = 0;
    for (final path in info.localPaths) {
      if (isContentUri(path)) continue; // SAF audio not counted in the tally
      try {
        final file = File(path);
        if (file.existsSync()) {
          total += file.lengthSync();
        }
      } catch (_) {}
    }
    return total + cachedEbookBytesSync(itemId);
  }

  static const _storageChannel = MethodChannel('com.absorb.storage');
  static const _widgetChannel = MethodChannel('com.absorb.widget');

  /// Cached iOS app group container path. Populated lazily by
  /// [_iosAppGroupAudioBase] and cleared if the lookup fails so we retry
  /// (the app group entitlement may roll in mid-session).
  String? _iosAppGroupContainerPath;

  /// Stops iCloud from backing up an audio file. Audiobooks are large and
  /// re-downloadable from the user's ABS server, so eating their iCloud
  /// quota would only cause problems (system backup breaks once quota is
  /// hit). iOS-only no-op elsewhere.
  Future<void> _excludeFromBackup(String path) async {
    if (!Platform.isIOS) return;
    try {
      await _widgetChannel.invokeMethod<bool>(
        'excludeFromBackup',
        {'path': path},
      );
    } catch (e) {
      debugPrint('[Download] excludeFromBackup failed for $path: $e');
    }
  }

  /// Returns the iOS app group's audio directory (`<group>/audio/downloads`),
  /// or null on Android / when the app group entitlement isn't available.
  /// Audio downloads live here so the native player core can read them
  /// from the widget extension (the widget can't reach Documents/).
  Future<String?> _iosAppGroupAudioBase() async {
    if (!Platform.isIOS) return null;
    var groupPath = _iosAppGroupContainerPath;
    if (groupPath == null) {
      try {
        groupPath = await _widgetChannel.invokeMethod<String>('getGroupContainerPath');
      } catch (e) {
        debugPrint('[Download] getGroupContainerPath failed: $e');
        return null;
      }
      if (groupPath == null || groupPath.isEmpty) return null;
      _iosAppGroupContainerPath = groupPath;
    }
    final dir = Directory('$groupPath/audio/downloads');
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (e) {
        debugPrint('[Download] create app group audio dir failed: $e');
        return null;
      }
    }
    return dir.path;
  }

  /// Get device storage info: {totalBytes, availableBytes}. Returns null on failure.
  static Future<Map<String, int>?> getDeviceStorage() async {
    try {
      final result = await _storageChannel.invokeMethod('getDeviceStorage');
      if (result is Map) {
        return {
          'totalBytes': (result['totalBytes'] as num).toInt(),
          'availableBytes': (result['availableBytes'] as num).toInt(),
        };
      }
    } catch (e) {
      debugPrint('[Download] getDeviceStorage error: $e');
    }
    return null;
  }

  DownloadInfo getInfo(String itemId) =>
      _downloads[itemId] ?? DownloadInfo(itemId: itemId);

  bool isDownloaded(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.downloaded;

  /// Registers an ebook-only book as a completed download so it shows in the
  /// offline library and its detail sheet loads offline. There's no audio, so
  /// localPaths is empty - the book opens in the reader, never the player. The
  /// ebook bytes live in the reader's persistent cache (fetchEbookToCache).
  /// Fetches a full copy of the item so the offline sheet has the cover,
  /// description, and ebookFile - not just the title.
  Future<void> registerEbookDownload({
    required ApiService api,
    required String itemId,
    Map<String, dynamic>? item,
    String? libraryId,
  }) async {
    Map<String, dynamic>? fullItem;
    try {
      fullItem = await api.getLibraryItem(itemId);
    } catch (_) {}
    final stored = fullItem ?? item ?? {'id': itemId};
    final media = stored['media'] as Map<String, dynamic>?;
    final metadata = media?['metadata'] as Map<String, dynamic>?;
    final title = metadata?['title'] as String?;
    final author = metadata?['authorName'] as String?;

    final localCoverPath = await _cacheCover(api, itemId, api.getCoverUrl(itemId, width: 800));
    final sessionJson = jsonEncode({
      'libraryItem': stored,
      'mediaMetadata': metadata,
      'duration': 0,
      'chapters': const <dynamic>[],
    });
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloaded,
      localPaths: const [],
      sessionData: sessionJson,
      title: title,
      author: author,
      localCoverPath: localCoverPath,
      libraryId: libraryId ?? stored['libraryId'] as String?,
    );
    await _save();
    notifyListeners();
  }

  bool isDownloading(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.downloading;

  bool isPaused(String itemId) =>
      _downloads[itemId]?.status == DownloadStatus.paused;

  double downloadProgress(String itemId) =>
      _downloads[itemId]?.progress ?? 0;

  /// Get all downloaded items (for home screen display).
  List<DownloadInfo> get downloadedItems =>
      _downloads.values
          .where((d) => d.status == DownloadStatus.downloaded)
          .toList();

  /// Get actively downloading items (in progress right now).
  List<DownloadInfo> get activeDownloads =>
      _downloads.values
          .where((d) => d.status == DownloadStatus.downloading && _activeDownloadIds.contains(d.itemId))
          .toList();

  /// Get queued items (waiting for a download slot).
  List<DownloadInfo> get queuedDownloads =>
      _queue.map((q) => _downloads[q.itemId]).whereType<DownloadInfo>().toList();

  Future<void> init() {
    if (_initialized) return Future.value();
    final inFlight = _initFuture;
    if (inFlight != null) return inFlight;

    final completer = Completer<void>();
    _initFuture = completer.future;
    final initialize = _initializeOverride ?? _initialize;
    Future.sync(initialize).then<void>(
      (_) {
        _initialized = true;
        completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        _initFuture = null;
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _customDownloadUri = prefs.getString('custom_download_uri');
    // Legacy raw-path custom folders can't be converted to a SAF content URI
    // without a fresh user pick, and we no longer hold the storage permission
    // to write them. Drop the old setting so new downloads use SAF or internal.
    if (prefs.getString('custom_download_path') != null) {
      await prefs.remove('custom_download_path');
    }
    final json = prefs.getString('downloads');
    if (json != null) {
      try {
        final map = jsonDecode(json) as Map<String, dynamic>;
        for (final entry in map.entries) {
          final info =
              DownloadInfo.fromJson(entry.value as Map<String, dynamic>);
          debugPrint('[Download] Loaded: ${entry.key} '
              'title="${info.title}" author="${info.author}" '
              'cover=${info.coverUrl != null ? "yes" : "null"} '
              'sessionData=${info.sessionData != null ? "${info.sessionData!.length} chars" : "null"}');
          if (info.status == DownloadStatus.downloaded) {
            _downloads[entry.key] = info;
          } else {
            debugPrint('[Download] Skipping stale ${info.status} entry: ${entry.key}');
          }
        }
      } catch (e) {
        debugPrint('[Download] Init error: $e');
      }
    }
    // On iOS, remap paths when the app container UUID changes after updates
    await _migrateIOSPaths();

    // On Android, flag downloads still pointing at raw external paths from
    // before the SAF switch so the UI can offer a re-download.
    await _detectLegacyExternal();

    // On iOS, move existing audio downloads from Documents/ into the app
    // group container so the widget / native player core can read them.
    // Runs in background so it doesn't block init() if the user has many
    // gigabytes of downloaded books to relocate.
    if (Platform.isIOS) {
      _iosAudioMigrationFuture ??= _runIOSAudioMigration();
      unawaited(_iosAudioMigrationFuture!);
    }

    // Re-save to persist any metadata extracted from sessionData
    if (_downloads.isNotEmpty) await _save();

    // Wire up native background downloads: configure the grouped notification,
    // start tracking tasks (so they persist across launches), listen for
    // updates, then rehydrate any download that was in flight when we were last
    // killed and ask the OS to redeliver completions that landed while dead.
    await _configureDownloader();
    _updatesSub ??= FileDownloader().updates.listen(_onTaskUpdate);
    await FileDownloader().trackTasks();
    await _loadPending();
    await _loadAutoDownloadBlocks();
    await _rehydratePending();
    await FileDownloader().resumeFromBackground();
    _startReconciler();

    notifyListeners();

    // Validate files and clean up orphans in background after startup
    validateDownloads();
  }

  void _startReconciler() {
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer.periodic(
        const Duration(minutes: 2), (_) => unawaited(_reconcilePending()));
  }

  /// Reconcile in-flight books against the package task DB. Two jobs:
  /// 1. If a book's terminal updates were missed (e.g. an OEM ROM killed our
  ///    callback), finalize / fail it from the DB so its slot frees.
  /// 2. If a book has made no progress and gone silent for a while, it's a dead
  ///    or zombie record (e.g. left over after an app update) holding a slot -
  ///    fail it so the queue can move on. Healthy or wifi-waiting downloads keep
  ///    emitting updates, so their lastUpdate stays fresh and they're left be.
  Future<void> _reconcilePending() async {
    if (_pending.isEmpty) return;
    List<TaskRecord> records;
    try {
      records = await FileDownloader().database.allRecords();
    } catch (_) {
      return;
    }
    final byItem = <String, Map<int, TaskStatus>>{};
    for (final r in records) {
      final meta = _decodeMeta(r.task.metaData);
      if (meta == null) continue;
      if (!_pending.containsKey(meta.$1)) continue;
      (byItem[meta.$1] ??= {})[meta.$2] = r.status;
    }
    for (final itemId in _pending.keys.toList()) {
      final p = _pending[itemId];
      if (p == null || p.finalizing) continue;
      final statuses = byItem[itemId];
      if (statuses != null && statuses.length >= p.trackCount) {
        statuses.forEach((i, s) => p.trackStatus[i] = s);
        bool allComplete = p.trackCount > 0;
        bool allTerminal = true;
        for (int i = 0; i < p.trackCount; i++) {
          final s = p.trackStatus[i];
          if (s != TaskStatus.complete) allComplete = false;
          if (s == null || !_terminal.contains(s)) allTerminal = false;
        }
        if (allComplete) {
          debugPrint('[Download] Reconciler finalizing missed-complete $itemId');
          p.finalizing = true;
          await _finalizeSuccess(itemId);
          continue;
        }
        if (allTerminal) {
          debugPrint('[Download] Reconciler failing stalled $itemId');
          // Don't pre-set p.finalizing: _failBook bails when it's already
          // true, which turned this whole cleanup into a no-op AND made the
          // zombie immortal (reconciler and cancel both skip finalizing
          // items, and the pending entry stays persisted across restarts).
          await _failBook(itemId, cause: 'Interrupted download');
          continue;
        }
      }
      // No updates for a while: a dead/zombie slot. Zero-progress books get a
      // short leash; ones with partial progress get a longer one - they can be
      // zombies too (rehydrated from DB records whose WorkManager jobs are
      // gone, so they hold a slot with e.g. 40% forever). A healthy transfer
      // emits updates constantly, so real downloads never sit silent this long
      // while the app is running.
      final silence = DateTime.now().difference(p.lastUpdate);
      if ((p.overallProgress == 0 && silence > const Duration(minutes: 3)) ||
          silence > const Duration(minutes: 10)) {
        debugPrint('[Download] Reconciler failing stale $itemId '
            '(progress=${p.overallProgress}, silent ${silence.inMinutes}m)');
        await _failBook(itemId, cause: 'Interrupted download');
      }
    }
  }

  /// Configure the downloader transport plus a fallback notification config
  /// for the shared group. The real notifications are configured per task in
  /// [_executeDownload] (one per book); this fallback only catches a task that
  /// somehow missed its per-task config. The package runs a background
  /// URLSession on iOS and a foreground service on Android, so downloads
  /// continue when backgrounded, locked, or killed.
  Future<void> _configureDownloader() async {
    if (_downloaderConfigured) return;
    // Run downloads in the Android foreground service. Without this, smaller
    // books can run as background WorkManager jobs that some OEM ROMs throttle
    // or kill, leaving downloads stuck. Exception: background isolates must NOT
    // use the foreground service (see backgroundIsolateMode) - the app's next
    // real start reconfigures back to always.
    if (Platform.isAndroid) {
      try {
        await FileDownloader().configure(androidConfig: [
          (
            Config.runInForeground,
            backgroundIsolateMode ? Config.never : Config.always,
          ),
        ]);
      } catch (e) {
        debugPrint('[Download] androidConfig failed: $e');
      }
    }
    final l = _l();
    // NOTE: for group notifications, the count tokens ({numFinished}/{numTotal})
    // only substitute in the TITLE - in the body they print literally. {progress}
    // is valid anywhere. We keep it simple: "Downloading" + a progress bar/%.
    FileDownloader().configureNotificationForGroup(
      _dlGroup,
      running: TaskNotification(
        l?.downloadNotifDownloadingTitle ?? 'Downloading',
        '{progress}',
      ),
      complete: TaskNotification(
        l?.downloadNotifCompleteTitle ?? 'Downloads complete',
        '',
      ),
      error: TaskNotification(
        l?.downloadNotifFailedTitle ?? 'Download failed',
        '',
      ),
      progressBar: true,
    );
    _downloaderConfigured = true;
  }

  AppLocalizations? _l() {
    final ctx = rootNavigatorKey.currentContext;
    return ctx != null ? AppLocalizations.of(ctx) : null;
  }

  /// On iOS, the app container UUID changes on every update, which breaks
  /// stored absolute paths. Detect stale prefixes and remap to the current
  /// container path so downloads survive TestFlight / App Store updates.
  Future<void> _migrateIOSPaths() async {
    if (!Platform.isIOS || _downloads.isEmpty) return;

    final appDir = await getApplicationDocumentsDirectory();
    final currentPrefix = appDir.path; // .../Documents
    // Audio lives in the App Group container - stable across updates in practice
    // (unlike Documents), but resolve it so we can remap audio paths too if the
    // container ever shifts. Belt and suspenders so downloads survive an update.
    final groupAudioBase = await _iosAppGroupAudioBase();

    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);

    for (final entry in entries.entries) {
      final info = entry.value;
      bool needsUpdate = false;

      // Remap localPaths (audio sits under the App Group; legacy audio under
      // Documents). Apply both: each is a no-op for paths it doesn't own.
      final newPaths = <String>[];
      for (final path in info.localPaths) {
        final remapped =
            _remapAppGroupPath(_remapIOSPath(path, currentPrefix), groupAudioBase);
        newPaths.add(remapped);
        if (remapped != path) needsUpdate = true;
      }

      // Covers always live in Documents, so only that prefix can go stale.
      final newCoverPath = info.localCoverPath != null
          ? _remapIOSPath(info.localCoverPath!, currentPrefix)
          : null;
      if (newCoverPath != info.localCoverPath) needsUpdate = true;

      final newDirPath = info.localDirPath != null
          ? _remapAppGroupPath(
              _remapIOSPath(info.localDirPath!, currentPrefix), groupAudioBase)
          : null;
      if (newDirPath != info.localDirPath) needsUpdate = true;

      if (needsUpdate) {
        _downloads[entry.key] = DownloadInfo(
          itemId: info.itemId,
          status: info.status,
          localPaths: newPaths,
          sessionData: info.sessionData,
          title: info.title,
          author: info.author,
          coverUrl: info.coverUrl,
          localCoverPath: newCoverPath,
          localDirPath: newDirPath,
          libraryId: info.libraryId,
        );
        changed = true;
      }
    }

    if (changed) {
      debugPrint('[Download] Migrated iOS paths to current container');
      await _save();
    }
  }

  /// Move existing audio files from Documents/ to the iOS app group container
  /// so the widget extension / native player core can read them. Files that
  /// fail to move stay in Documents/ where they continue to play through
  /// Flutter; we'll retry on the next launch. Atomic per-file via
  /// `File.rename()` (works because both directories are on APFS).
  Future<void> _migrateIOSAudioToAppGroup() async {
    if (!Platform.isIOS || _downloads.isEmpty) return;

    final groupBase = await _iosAppGroupAudioBase();
    if (groupBase == null) {
      debugPrint('[Download] App group not available, skipping audio migration');
      return;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final docsBase = '${appDir.path}/downloads';

    int moved = 0;
    int failed = 0;
    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);

    for (final entry in entries.entries) {
      final info = entry.value;
      if (info.status != DownloadStatus.downloaded) continue;

      final newPaths = <String>[];
      bool needsUpdate = false;
      for (final oldPath in info.localPaths) {
        // Already in app group? Keep as-is.
        if (oldPath.startsWith(groupBase)) {
          newPaths.add(oldPath);
          continue;
        }
        // Not under Documents/downloads/? Leave alone (custom path or odd).
        if (!oldPath.startsWith(docsBase)) {
          newPaths.add(oldPath);
          continue;
        }
        // Build the parallel path under the app group.
        final relative = oldPath.substring(docsBase.length);
        final newPath = '$groupBase$relative';
        try {
          final oldFile = File(oldPath);
          if (!oldFile.existsSync()) {
            // Old file gone; leave the path untouched and let the validator
            // mark it broken later.
            newPaths.add(oldPath);
            continue;
          }
          // Make sure parent dirs exist on the destination side.
          final parent = Directory(newPath.substring(0, newPath.lastIndexOf('/')));
          if (!parent.existsSync()) parent.createSync(recursive: true);
          // If dest exists already (partial prior run), remove it first.
          final newFile = File(newPath);
          if (newFile.existsSync()) {
            try { newFile.deleteSync(); } catch (_) {}
          }
          await oldFile.rename(newPath);
          await _excludeFromBackup(newPath);
          newPaths.add(newPath);
          needsUpdate = true;
          moved++;
        } catch (e) {
          debugPrint('[Download] Audio migration failed for $oldPath: $e');
          newPaths.add(oldPath);
          failed++;
        }
      }

      if (needsUpdate) {
        _downloads[entry.key] = DownloadInfo(
          itemId: info.itemId,
          status: info.status,
          progress: info.progress,
          localPaths: newPaths,
          sessionData: info.sessionData,
          title: info.title,
          author: info.author,
          coverUrl: info.coverUrl,
          localCoverPath: info.localCoverPath,
          localDirPath: info.localDirPath,
          libraryId: info.libraryId,
        );
        changed = true;
      }
    }

    if (changed) {
      debugPrint('[Download] App group audio migration: moved=$moved failed=$failed');
      await _save();
      notifyListeners();
    }
  }

  Future<void> _runIOSAudioMigration() async {
    try {
      await _migrateIOSAudioToAppGroup();
    } catch (e) {
      debugPrint('[Download] App group audio migration failed: $e');
    }
  }

  /// Replace a stale iOS container prefix with the current one.
  /// Paths contain `.../Documents/...` and we split on `/Documents/` then
  /// rejoin with the current prefix.
  String _remapIOSPath(String path, String currentPrefix) {
    if (path.startsWith(currentPrefix)) return path;
    final marker = '/Documents/';
    final idx = path.indexOf(marker);
    if (idx < 0) return path;
    return '$currentPrefix/${path.substring(idx + marker.length)}';
  }

  /// Replace a stale App Group container prefix with the current one. Audio is
  /// stored at `<group>/audio/downloads/...`; if the container path ever shifts
  /// across an update, rejoin the stable `/audio/downloads` tail onto the freshly
  /// resolved base so previously-downloaded books keep playing. No-op when the
  /// path is already current (the usual case) or for non-audio paths.
  String _remapAppGroupPath(String path, String? groupAudioBase) {
    if (groupAudioBase == null || path.startsWith(groupAudioBase)) return path;
    const marker = '/audio/downloads';
    final idx = path.indexOf(marker);
    if (idx < 0) return path;
    return '$groupAudioBase${path.substring(idx + marker.length)}';
  }

  /// Flag downloaded items whose files sit at a raw external path from before
  /// the SAF switch (not a content URI, not under internal storage). Without
  /// the dropped storage permission these can't be read, so they're kept listed
  /// for re-download instead of being silently dropped by the validator.
  Future<void> _detectLegacyExternal() async {
    if (!Platform.isAndroid || _downloads.isEmpty) return;
    final appDir = await getApplicationDocumentsDirectory();
    final internalPrefix = appDir.path;
    for (final entry in _downloads.entries) {
      final info = entry.value;
      if (info.status != DownloadStatus.downloaded || info.localPaths.isEmpty) {
        continue;
      }
      final first = info.localPaths.first;
      if (isContentUri(first) || first.startsWith(internalPrefix)) continue;
      _legacyExternalIds.add(entry.key);
    }
    if (_legacyExternalIds.isNotEmpty) {
      debugPrint('[Download] ${_legacyExternalIds.length} legacy external download(s) need re-download');
    }
  }

  /// Drop a legacy external entry (its files are orphaned on storage we can no
  /// longer reach) and re-enqueue it from stored metadata so it lands in the
  /// current location (SAF folder or internal).
  Future<void> redownloadLegacy(ApiService api, String itemId) async {
    final info = _downloads[itemId];
    if (info == null) return;
    _downloads.remove(itemId);
    _legacyExternalIds.remove(itemId);
    await _save();
    notifyListeners();
    final episodeId = itemId.length > 36 ? itemId.substring(37) : null;
    await downloadItem(
      api: api,
      itemId: itemId,
      title: info.title ?? '',
      author: info.author,
      coverUrl: info.coverUrl,
      episodeId: episodeId,
      libraryId: info.libraryId,
    );
  }

  /// Re-download every flagged legacy external item.
  Future<void> redownloadAllLegacy(ApiService api) async {
    for (final id in _legacyExternalIds.toList()) {
      await redownloadLegacy(api, id);
    }
  }

  /// Forget the legacy external entries without re-downloading (user dismissed).
  Future<void> dismissLegacyDownloads() async {
    if (_legacyExternalIds.isEmpty) return;
    for (final id in _legacyExternalIds) {
      _downloads.remove(id);
    }
    _legacyExternalIds.clear();
    await _save();
    notifyListeners();
  }

  /// Validate that downloaded files still exist on disk and clean up orphans.
  /// Runs in background so it doesn't block app startup. Also probes SAF
  /// content:// URIs through the native side (Dart can't stat them) in batched
  /// calls, so files deleted externally disappear from the downloads registry.
  /// Re-entrant calls coalesce onto the in-flight run instead of duplicating it.
  Future<void>? _runningValidate;
  Future<void> validateDownloads() {
    return _runningValidate ??= _validateDownloadsNow().whenComplete(() {
      _runningValidate = null;
    });
  }

  Future<void> _validateDownloadsNow() async {
    try {
      final entries = Map<String, DownloadInfo>.from(_downloads);
      // Collect every content:// URI across all entries so the native probe
      // is a single channel call instead of one per file/track.
      final safByItem = <String, List<String>>{};
      for (final entry in entries.entries) {
        if (entry.value.status != DownloadStatus.downloaded) continue;
        if (_legacyExternalIds.contains(entry.key)) continue;
        final uris = entry.value.localPaths.where(isContentUri).toList();
        if (uris.isNotEmpty) safByItem[entry.key] = uris;
      }
      final safExists = <String, bool>{};
      if (safByItem.isNotEmpty) {
        final all = {
          for (final uris in safByItem.values) ...uris,
        }.toList();
        // Probe in chunks so a huge registry (many books x tracks) stays within
        // a comfortable channel-batch size instead of one giant call; the native
        // side walks each chunk serially anyway. Failures fall back to keeping
        // every entry scanned in that chunk, never wiping the registry.
        const chunkSize = 400;
        var ok = true;
        for (var start = 0;
            start < all.length && ok;
            start += chunkSize) {
          final end = (start + chunkSize).clamp(0, all.length);
          final chunk = all.sublist(start, end);
          try {
            final res = await _storageChannel
                .invokeMethod<Map>('checkSafFiles', {'uris': chunk})
                .timeout(const Duration(seconds: 8));
            if (res != null) {
              for (final e in res.entries) {
                safExists[e.key as String] = e.value == true;
              }
            }
          } catch (e) {
            // SAF probe failed (permission revoked etc.) - be conservative and
            // keep everything rather than wiping the registry.
            ok = false;
            debugPrint('[Download] SAF existence probe incomplete: $e');
          }
        }
      }

      final orphanIds = <String>[];
      for (final entry in entries.entries) {
        if (entry.value.status != DownloadStatus.downloaded) continue;
        // Legacy external entries are kept for re-download, not validated away.
        if (_legacyExternalIds.contains(entry.key)) continue;
        bool allExist = true;
        for (final path in entry.value.localPaths) {
          if (isContentUri(path)) {
            // Existence decided by the native probe above. If it has no answer
            // (scan was skipped/failed) treat as present and move on.
            final exists = safExists[path];
            if (exists == false) {
              allExist = false;
              break;
            }
          } else {
            try {
              final exists = await File(path).exists()
                  .timeout(const Duration(seconds: 3));
              if (!exists) {
                allExist = false;
                break;
              }
            } catch (_) {
              // Timeout or permission error — treat as missing
              allExist = false;
              break;
            }
          }
        }
        if (!allExist) {
          debugPrint('[Download] Files missing for ${entry.key}, removing');
          _downloads.remove(entry.key);
          orphanIds.add(entry.key);
        }
      }
      if (orphanIds.isNotEmpty) {
        await _save();
        notifyListeners();
        // Clean up partial/orphaned files on disk
        final basePath = await downloadBasePath;
        final internalBase = await _internalBasePath;
        for (final id in orphanIds) {
          debugPrint('[Download] Cleaning up orphaned entry: $id');
          try {
            final dir = Directory('$basePath/$id');
            if (await dir.exists()) await dir.delete(recursive: true);
          } catch (_) {}
          try {
            final coverDir = Directory('$internalBase/$id');
            if (await coverDir.exists()) await coverDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[Download] Validation error: $e');
    }
  }

  /// Try to fill in missing metadata from the API (for old downloads).
  Future<void> enrichMetadata(ApiService api) async {
    bool changed = false;
    final entries = Map<String, DownloadInfo>.from(_downloads);
    for (final entry in entries.entries) {
      final info = entry.value;
      if (info.status != DownloadStatus.downloaded) continue;

      bool needsUpdate = false;
      String? title = info.title;
      String? author = info.author;
      String? coverUrl = info.coverUrl;
      String? localCoverPath = info.localCoverPath;

      // For podcast episodes, the itemId is a composite "showUUID-episodeId".
      // Extract the library item ID (first 36 chars = UUID) for API calls.
      final apiItemId = info.itemId.length > 36
          ? info.itemId.substring(0, 36)
          : info.itemId;

      // Enrich missing title/author from server
      if (title == null || title.isEmpty) {
        try {
          final item = await api.getLibraryItem(apiItemId);
          if (item != null) {
            final media = item['media'] as Map<String, dynamic>? ?? {};
            final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
            title = metadata['title'] as String? ?? title;
            author = metadata['authorName'] as String? ?? author;
            coverUrl = api.getCoverUrl(apiItemId, width: 1200);
            needsUpdate = true;
            debugPrint('[Download] Enriched metadata for ${info.itemId}: $title');
          }
        } catch (e) {
          debugPrint('[Download] Enrich failed for ${info.itemId}: $e');
        }
      }

      // Cache cover in internal storage if not already cached
      if (localCoverPath == null || !File(localCoverPath).existsSync()) {
        final internalBase = await _internalBasePath;
        final existingCover = File('$internalBase/${info.itemId}/cover.jpg');
        if (existingCover.existsSync()) {
          // Already on disk from a previous download, just not tracked
          localCoverPath = existingCover.path;
          needsUpdate = true;
        } else {
          // Also check the custom download path (old downloads may have cover there)
          final basePath = await downloadBasePath;
          final oldCover = File('$basePath/${info.itemId}/cover.jpg');
          if (oldCover.existsSync()) {
            localCoverPath = oldCover.path;
            needsUpdate = true;
          } else {
            // Download from server into internal storage
            final url = _hiResCoverUrl(coverUrl ?? api.getCoverUrl(apiItemId, width: 1200));
            try {
              final resp = await http.get(Uri.parse(url), headers: api.mediaHeaders)
                  .timeout(const Duration(seconds: 10));
              if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
                final dir = Directory('$internalBase/${info.itemId}');
                if (!dir.existsSync()) dir.createSync(recursive: true);
                final coverFile = File('${dir.path}/cover.jpg');
                await coverFile.writeAsBytes(resp.bodyBytes);
                final evicted = PaintingBinding.instance.imageCache
                    .evict(FileImage(coverFile));
                localCoverPath = coverFile.path;
                needsUpdate = true;
                debugPrint('[Download] Cached cover for ${info.itemId} '
                    '(${resp.bodyBytes.length} bytes, evict=$evicted)');
              }
            } catch (e) {
              debugPrint('[Download] Cover cache failed for ${info.itemId}: $e');
            }
          }
        }
      } else if (_coverUpgradeChecked.add(info.itemId)) {
        // Covers saved before the 1200px fetch were 400px thumbnails, which
        // look blurry now that the card and full screen player render them at
        // near screen width. Replace them in place, once per item per
        // session (a book whose original cover really is small would
        // otherwise refetch forever).
        final width = await _imageFileWidth(localCoverPath);
        if (width != null && width < 800) {
          final url = _hiResCoverUrl(coverUrl ?? api.getCoverUrl(apiItemId, width: 1200));
          try {
            final resp = await http.get(Uri.parse(url), headers: api.mediaHeaders)
                .timeout(const Duration(seconds: 10));
            if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
              final coverFile = File(localCoverPath);
              await coverFile.writeAsBytes(resp.bodyBytes);
              PaintingBinding.instance.imageCache.evict(FileImage(coverFile));
              debugPrint('[Download] Upgraded ${width}px cover for ${info.itemId} '
                  '(${resp.bodyBytes.length} bytes)');
            }
          } catch (e) {
            debugPrint('[Download] Cover upgrade failed for ${info.itemId}: $e');
          }
        }
      }

      if (needsUpdate) {
        _downloads[entry.key] = DownloadInfo(
          itemId: info.itemId,
          status: info.status,
          localPaths: info.localPaths,
          sessionData: info.sessionData,
          title: title ?? info.title,
          author: author ?? info.author,
          coverUrl: coverUrl ?? info.coverUrl,
          localCoverPath: localCoverPath,
          libraryId: info.libraryId,
        );
        changed = true;
      }
    }
    if (changed) {
      await _save();
      notifyListeners();
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final entry in _downloads.entries) {
      if (entry.value.status == DownloadStatus.downloaded) {
        map[entry.key] = entry.value.toJson();
      }
    }
    await prefs.setString('downloads', jsonEncode(map));
  }

  List<String>? getLocalPaths(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return null;
    return info.localPaths;
  }

  String? getCachedSessionData(String itemId) {
    return _downloads[itemId]?.sessionData;
  }

  /// Get the local cover file path for a downloaded item.
  /// Checks the persisted path first, then probes internal and download dirs.
  Future<String?> getLocalCoverPath(String itemId) async {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return null;

    // Check persisted path
    if (info.localCoverPath != null && File(info.localCoverPath!).existsSync()) {
      return info.localCoverPath;
    }

    // Check internal storage (where covers are now cached)
    final internalBase = await _internalBasePath;
    final internalCover = File('$internalBase/$itemId/cover.jpg');
    if (internalCover.existsSync()) return internalCover.path;

    // Check custom download path (old downloads may have cover there)
    final basePath = await downloadBasePath;
    if (basePath != internalBase) {
      final customCover = File('$basePath/$itemId/cover.jpg');
      if (customCover.existsSync()) return customCover.path;
    }

    return null;
  }

  /// Returns null on success, error message string on failure.
  /// For podcast episodes, pass [episodeId] so the correct API endpoint is used.
  /// [shouldStart] lets a caller invalidate the request while setup is waiting.
  ///
  /// With [replaceExisting] a completed download of [itemId] is re-downloaded
  /// instead of being blocked by the "already downloaded" guard. Files land at
  /// the same deterministic per-track names, so already-present files are kept
  /// and the final record replaces the old one - exactly right for adding more
  /// chapters to a partially downloaded book. Callers should pass the union of
  /// what is already downloaded and the newly selected chapters.
  Future<String?> downloadItem({
    required ApiService api,
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
    String? episodeId,
    String? libraryId,
    // Chapter indices to download, or null/empty for the whole item.
    List<int>? selectedChapters,
    bool Function()? shouldStart,
    // Set by the auto-download planners. An item the user deleted by hand is
    // skipped when automatic; a manual (or download-on-stream) call clears
    // that block, since the user asked for it back.
    bool automatic = false,
    // Bypass the "already downloaded" guard so a completed download can be
    // re-downloaded in place. Files land at the same deterministic per-track
    // names, so already-present files are kept and only the newly selected
    // chapters are fetched; the final record is the union of the two.
    bool replaceExisting = false,
  }) async {
    if (shouldStart?.call() == false) return null;
    try {
      await init().timeout(const Duration(seconds: 8));
    } on TimeoutException catch (e) {
      debugPrint('[Download] Downloader initialization still in progress: $e');
      return 'Downloads are still starting. Please try again in a moment.';
    } catch (e) {
      debugPrint('[Download] Downloader initialization failed: $e');
      return 'Downloads could not start. Please try again.';
    }
    if (shouldStart?.call() == false) return null;

    if (automatic && _autoDownloadBlocked.contains(itemId)) {
      debugPrint(
          '[Download] skipped auto-download of "$title" ($itemId): the user deleted it. A manual download, or playing it with download-on-stream on, brings it back');
      return null;
    }
    if (!automatic && _autoDownloadBlocked.remove(itemId)) {
      await _saveAutoDownloadBlocks();
    }

    if (_activeDownloadIds.contains(itemId)) return null;
    if (isDownloaded(itemId) && !replaceExisting) return null;
    // Already queued — don't duplicate
    if (_queue.any((q) => q.itemId == itemId)) return null;
    // Already in flight or paused — a paused book must be resumed, not restarted
    // (restarting would enqueue tasks that collide with the paused ones).
    if (_pending.containsKey(itemId)) return null;

    // Check wifi-only setting
    final wifiOnly = await PlayerSettings.getWifiOnlyDownloads();
    if (shouldStart?.call() == false) return null;
    if (wifiOnly) {
      final connectivity = await Connectivity().checkConnectivity();
      if (shouldStart?.call() == false) return null;
      if (!connectivity.contains(ConnectivityResult.wifi)) {
        return 'Downloads are set to Wi-Fi only. Connect to Wi-Fi or change this in Settings.';
      }
    }

    final maxConcurrent = await PlayerSettings.getMaxConcurrentDownloads();
    if (shouldStart?.call() == false) return null;

    // The checks above ran before settings were loaded, so another tap may
    // have started or queued this item in the meantime.
    if (_activeDownloadIds.contains(itemId) ||
        (isDownloaded(itemId) && !replaceExisting) ||
        _queue.any((q) => q.itemId == itemId) ||
        _pending.containsKey(itemId)) {
      return null;
    }

    // If at capacity, queue this one
    if (_activeDownloadIds.length >= maxConcurrent) {
      if (shouldStart?.call() == false) return null;
      debugPrint('[Download] Queued "$title" ($itemId); slots ${_activeDownloadIds.length}/$maxConcurrent full, ${_queue.length} waiting');
      _queue.add(_QueuedDownload(
        api: api,
        itemId: itemId,
        title: title,
        author: author,
        coverUrl: coverUrl,
        episodeId: episodeId,
        libraryId: libraryId,
        selectedChapters: selectedChapters,
      ));
      _downloads[itemId] = DownloadInfo(
        itemId: itemId,
        status: DownloadStatus.downloading,
        progress: 0,
        title: title,
        author: author,
        coverUrl: coverUrl,
        libraryId: libraryId,
      );
      notifyListeners();
      return null;
    }

    // Launch immediately (fire-and-forget so caller doesn't block)
    if (shouldStart?.call() == false) return null;
    unawaited(_executeDownload(
      api: api,
      itemId: itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      episodeId: episodeId,
      libraryId: libraryId,
      selectedChapters: selectedChapters,
    ));
    return null;
  }

  /// Download entry point for short-lived background isolates (the episode
  /// notification job). Same guards as [downloadItem], but awaits the enqueue
  /// (the isolate dies as soon as the task returns, which would cut off a
  /// fire-and-forget mid-flight) and skips the in-memory concurrency queue
  /// (queued entries would die with the isolate; background_downloader
  /// schedules the handed-over tasks natively either way).
  Future<void> enqueueBackgroundDownload({
    required ApiService api,
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
    String? episodeId,
    String? libraryId,
  }) async {
    await init();

    if (_activeDownloadIds.contains(itemId)) return;
    if (isDownloaded(itemId)) return;
    if (_queue.any((q) => q.itemId == itemId)) return;
    final wifiOnly = await PlayerSettings.getWifiOnlyDownloads();
    if (wifiOnly) {
      final connectivity = await Connectivity().checkConnectivity();
      // Not on WiFi: skip silently - the in-app catch-up still sees the
      // episode as new and downloads it on the next open.
      if (!connectivity.contains(ConnectivityResult.wifi)) return;
    }
    await _executeDownload(
      api: api,
      itemId: itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      episodeId: episodeId,
      libraryId: libraryId,
    );
  }

  /// Fill free download slots from the queue.
  Future<void> _processQueue() async {
    final maxConcurrent = await PlayerSettings.getMaxConcurrentDownloads();
    while (_queue.isNotEmpty && _activeDownloadIds.length < maxConcurrent) {
      final next = _queue.removeAt(0);
      // Skip if cancelled/removed while waiting
      if (isDownloaded(next.itemId)) continue;
      if (_activeDownloadIds.contains(next.itemId)) continue;
      unawaited(_executeDownload(
        api: next.api, itemId: next.itemId, title: next.title,
        author: next.author, coverUrl: next.coverUrl, episodeId: next.episodeId,
        libraryId: next.libraryId, selectedChapters: next.selectedChapters,
      ));
    }
  }

  static String _taskId(String itemId, int trackIndex) => '$itemId::$trackIndex';

  /// Statuses from which a task will never progress further.
  static const Set<TaskStatus> _terminal = {
    TaskStatus.complete,
    TaskStatus.failed,
    TaskStatus.notFound,
    TaskStatus.canceled,
  };

  /// Best-effort download of a book's ebook into the persistent reader cache so
  /// it reads offline. Swallows errors - the audio download is what matters.
  Future<void> _cacheEbookForOffline(
      ApiService api, String itemId, Map<String, dynamic> ebookFile, String title) async {
    try {
      final f = await fetchEbookToCache(api, itemId, ebookFile, title);
      await _excludeFromBackup(f.path);
      debugPrint('[Download] cached ebook for offline: $itemId');
    } catch (e) {
      debugPrint('[Download] ebook offline cache failed for $itemId: $e');
    }
  }

  /// Re-fetch any companion ebooks whose fire-and-forget download never landed
  /// (killed mid-transfer, offline at the time). Called when the app comes up
  /// with a working connection; cheap when everything is already cached.
  Future<void> catchUpEbookCaches(ApiService api) async {
    for (final info in _downloads.values.toList()) {
      if (info.status != DownloadStatus.downloaded) continue;
      if (info.sessionData == null) continue;
      try {
        final session = jsonDecode(info.sessionData!) as Map<String, dynamic>;
        final ebookFile =
            resolveEbookFile(session['libraryItem'] as Map<String, dynamic>?);
        if (ebookFile == null) continue;
        final apiItemId = session['libraryItemId'] as String? ?? info.itemId;
        if (await isEbookCached(apiItemId, ebookFile)) continue;
        await _cacheEbookForOffline(
            api, apiItemId, ebookFile, info.title ?? apiItemId);
      } catch (_) {}
    }
  }

  /// Resolve a book/episode to durable per-file download tasks and enqueue them.
  /// Returns once the tasks are handed to `background_downloader`; progress and
  /// completion are driven asynchronously by [_onTaskUpdate] / [_finalizeSuccess]
  /// (which also fire after an app relaunch).
  Future<void> _executeDownload({
    required ApiService api,
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
    String? episodeId,
    String? libraryId,
    List<int>? selectedChapters,
  }) async {
    _activeDownloadIds.add(itemId);
    _cancelledIds.remove(itemId);
    debugPrint('[Download] Starting "$title" ($itemId)');

    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloading,
      progress: 0,
      title: title,
      author: author,
      coverUrl: coverUrl,
      libraryId: libraryId,
    );
    notifyListeners();

    // SAF custom folder (Android only): files go to a flat per-book folder
    // under the user-granted tree via content URIs, no storage permission.
    final useSaf = Platform.isAndroid &&
        _customDownloadUri != null &&
        _customDownloadUri!.isNotEmpty;
    String? bookDirRef; // filesystem path or content:// URI, for cleanup
    Directory? bookDir; // filesystem branches only
    try {
      // For episodes, itemId is a composite key like 'podcastId-episodeId'.
      // Extract the real library item ID for the API call.
      final apiItemId = episodeId != null
          ? itemId.substring(0, itemId.length - episodeId.length - 1)
          : itemId;

      // The forced direct-play session provides both offline metadata and the
      // authoritative /file/:ino path for every included track.
      final sessionData = episodeId != null
          ? await api.startEpisodePlaybackSession(apiItemId, episodeId)
          : await api.startPlaybackSession(apiItemId);
      if (sessionData == null) throw Exception('Failed to start session');

      final allTracks = sessionData['audioTracks'] as List<dynamic>?;
      if (allTracks == null || allTracks.isEmpty) {
        throw Exception('No audio tracks');
      }

      // Narrow to the files covering the user's chapter selection (whole item
      // when nothing was selected). `trackStarts` are absolute offsets in the
      // full book so offline playback can keep the true timeline.
      final resolved =
          _resolveSelectedTracks(allTracks, sessionData, selectedChapters);
      final audioTracks = resolved.tracks;
      final trackStarts = resolved.starts;

      final files = _resolveDurableFiles(api, apiItemId, audioTracks);

      // Pull the companion ebook into the offline cache too, so a downloaded
      // book is fully readable offline. Fire-and-forget - never blocks or fails
      // the audio download.
      final ebookFile =
          resolveEbookFile(sessionData['libraryItem'] as Map<String, dynamic>?);
      if (ebookFile != null) {
        unawaited(_cacheEbookForOffline(api, apiItemId, ebookFile, title));
      }

      // Per-book destination. Android downloads to internal storage first - for
      // both the internal default AND SAF custom folders. SAF books are then
      // moved into the user's chosen folder under "Author/Title" on completion
      // (a direct SAF write can't nest subfolders). iOS downloads into the app
      // group container.
      final nestedName = (author != null && author.isNotEmpty)
          ? '${_sanitizePath(author)}/${_sanitizePath(title)}'
          : _sanitizePath(title);
      String? relDir; // Android: relative to applicationDocuments
      if (Platform.isIOS) {
        final basePath = await downloadBasePath;
        bookDir = Directory('$basePath/$nestedName');
      } else {
        final appDir = await getApplicationDocumentsDirectory();
        relDir = 'downloads/$nestedName';
        bookDir = Directory('${appDir.path}/$relDir');
      }
      if (!bookDir.existsSync()) bookDir.createSync(recursive: true);
      bookDirRef = bookDir.path;
      debugPrint('[Download] "$title" location=${useSaf ? 'SAF' : 'default'} dir=${bookDir.path} tracks=${files.length}');

      final localCoverPath = await _cacheCover(api, itemId, coverUrl);

      // Keep a trimmed libraryItem in the persisted session: metadata, chapters
      // and the ebook info survive for offline Read, while the bulky episode
      // and audio file lists are dropped (mirrors _stripLibraryItem).
      // libraryFiles shrinks to just the resolved ebook entry, which covers
      // audiobooks-only libraries where every ebook is supplementary and
      // media.ebookFile is never set.
      final slimSession = Map<String, dynamic>.from(sessionData);
      // Persist only the downloaded files plus each one's absolute start in the
      // full-book timeline, so offline playback keeps the real chapter
      // positions even when some files were skipped.
      slimSession['audioTracks'] = audioTracks;
      slimSession['trackStartOffsets'] = trackStarts;
      final fullItem = sessionData['libraryItem'] as Map<String, dynamic>?;
      if (fullItem == null) {
        slimSession.remove('libraryItem');
      } else {
        final slimItem = Map<String, dynamic>.from(fullItem);
        final media = slimItem['media'] as Map<String, dynamic>?;
        if (media != null) {
          slimItem['media'] = Map<String, dynamic>.from(media)
            ..remove('episodes')
            ..remove('audioFiles');
        }
        slimItem['libraryFiles'] = [if (ebookFile != null) ebookFile];
        slimSession['libraryItem'] = slimItem;
      }
      final sessionId = sessionData['id'] as String?;
      if (sessionId != null) unawaited(api.closePlaybackSession(sessionId));

      // Cancelled while we were resolving? Bail before enqueueing anything.
      if (_cancelledIds.remove(itemId)) {
        await _cleanupBookDir(bookDirRef);
        _activeDownloadIds.remove(itemId);
        _downloads.remove(itemId);
        notifyListeners();
        unawaited(_processQueue());
        return;
      }

      final expectedPaths = [for (final f in files) '${bookDir.path}/${f.filename}'];
      final wifiOnly = await PlayerSettings.getWifiOnlyDownloads();

      final pending = _PendingBook(
        itemId: itemId,
        apiItemId: apiItemId,
        episodeId: episodeId,
        title: title,
        author: author,
        coverUrl: coverUrl,
        localCoverPath: localCoverPath,
        libraryId: libraryId,
        bookDir: bookDirRef,
        trackCount: files.length,
        expectedPaths: expectedPaths,
        slimSessionJson: jsonEncode(slimSession),
        safTreeUri: useSaf ? _customDownloadUri : null,
        safSubfolder: useSaf ? nestedName : null,
        selectedChapters: selectedChapters,
      );
      _pending[itemId] = pending;
      await _persistPending();

      if (pending.paused) {
        // Paused while we were resolving / between enqueues: don't launch a
        // fresh batch of tasks, just leave the item paused.
        _activeDownloadIds.remove(itemId);
        notifyListeners();
        return;
      }

      // One notification per book instead of one per file task. Multi-file
      // books group their tasks under a per-book group notification (the
      // package's group progress is finished-files / total, so the bar steps
      // per file); single-file books keep the byte-accurate per-task progress.
      // The title is baked into the strings because task tokens aren't
      // substituted in group notifications.
      final l = _l();
      final multiFile = files.length > 1;
      final runningNotif = Platform.isIOS
          // Static text on iOS: iOS can't update a notification in place, so
          // dynamic tokens would re-issue it on every change.
          ? TaskNotification(title, l?.downloadNotifDownloadingTitle ?? 'Downloading')
          : TaskNotification(title, multiFile ? '{numFinished} / {numTotal}' : '{progress}');
      final completeNotif = TaskNotification(
        l?.downloadNotifCompleteTitle ?? 'Download Complete',
        l?.downloadNotifCompleteBody(title) ?? '$title is ready to listen offline',
      );
      final errorNotif = TaskNotification(
        l?.downloadNotifFailedTitle ?? 'Download Failed',
        title,
      );

      for (int i = 0; i < files.length; i++) {
        final meta = jsonEncode({'itemId': itemId, 'i': i, 'n': files.length});
        final Task task;
        if (Platform.isIOS) {
          task = DownloadTask(
            taskId: _taskId(itemId, i),
            url: files[i].url,
            headers: api.mediaHeaders,
            filename: files[i].filename,
            baseDirectory: BaseDirectory.root,
            directory: bookDir.path,
            group: _dlGroup,
            metaData: meta,
            updates: Updates.statusAndProgress,
            requiresWiFi: wifiOnly,
            retries: 3,
            allowPause: true,
          );
        } else {
          task = DownloadTask(
            taskId: _taskId(itemId, i),
            url: files[i].url,
            headers: api.mediaHeaders,
            filename: files[i].filename,
            baseDirectory: BaseDirectory.applicationDocuments,
            directory: relDir!,
            group: _dlGroup,
            metaData: meta,
            updates: Updates.statusAndProgress,
            requiresWiFi: wifiOnly,
            retries: 3,
            allowPause: true,
          );
        }
        // Must be registered before enqueue - the config is serialized into
        // the native task, so it survives app kills along with the task.
        FileDownloader().configureNotificationForTask(
          task,
          running: runningNotif,
          complete: completeNotif,
          error: errorNotif,
          progressBar: true,
          groupNotificationId: multiFile ? itemId : '',
        );
        final ok = await FileDownloader().enqueue(task);
        debugPrint('[Download] enqueue ${i + 1}/${files.length} ok=$ok file=${files[i].filename}');
        if (!ok) throw Exception('Failed to enqueue track ${i + 1}');
      }
      debugPrint('[Download] Enqueued ${files.length} task(s) for "$title"');
    } catch (e) {
      await _failBook(itemId,
          cause: e, bookDirRef: bookDirRef, title: title, author: author, coverUrl: coverUrl);
    }
  }

  /// Rebuild forced-direct-play track URLs against the current server/token so
  /// native tasks can outlive the playback session that supplied the metadata.
  List<({String url, String filename})> _resolveDurableFiles(
      ApiService api, String apiItemId, List<dynamic> audioTracks) {
    final out = <({String url, String filename})>[];
    for (int i = 0; i < audioTracks.length; i++) {
      final track = audioTracks[i] as Map<String, dynamic>;
      final contentUrl = track['contentUrl'] as String? ?? '';
      final uri = Uri.tryParse(contentUrl);
      if (uri == null) {
        throw Exception('Invalid direct file URL for track ${i + 1}');
      }
      if (uri.hasScheme || uri.hasAuthority) {
        final serverUri = Uri.parse(api.cleanBaseUrl);
        if (!uri.hasScheme ||
            !uri.hasAuthority ||
            (uri.scheme != 'http' && uri.scheme != 'https') ||
            uri.origin != serverUri.origin) {
          throw Exception('Track ${i + 1} points to a different server');
        }
      }
      final segments = uri.pathSegments;
      String? ino;
      for (int segment = 0; segment + 4 < segments.length; segment++) {
        if (segments[segment] != 'api' ||
            segments[segment + 1] != 'items' ||
            segments[segment + 3] != 'file' ||
            segment + 5 != segments.length) {
          continue;
        }
        if (segments[segment + 2] != apiItemId) {
          throw Exception('Track ${i + 1} belongs to a different library item');
        }
        ino = segments[segment + 4];
        break;
      }
      if (ino == null ||
          ino.isEmpty ||
          ino.contains('/') ||
          ino.contains('?') ||
          ino.contains('#')) {
        throw Exception('Missing direct file URL for track ${i + 1}');
      }
      out.add((url: api.buildFileUrl(apiItemId, ino), filename: _trackFileName(track, i)));
    }
    return out;
  }

  /// Picks which audio files to download for [chapterSelection].
  ///
  /// Chapters are timed markers, not files, so a selection maps to the set of
  /// audio files whose time range the chapters overlap (a file may hold several
  /// embedded chapters). Returns every track when the selection is null/empty
  /// or can't be resolved. `starts` are each chosen file's absolute offset in
  /// the full book, letting offline playback keep the true timeline.
  ({List<dynamic> tracks, List<double> starts}) _resolveSelectedTracks(
    List<dynamic> allTracks,
    Map<String, dynamic> sessionData,
    List<int>? chapterSelection,
  ) {
    final durations = <double>[
      for (final t in allTracks)
        ((t as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0,
    ];
    final starts = <double>[];
    double acc = 0;
    for (final d in durations) {
      starts.add(acc);
      acc += d;
    }

    if (chapterSelection == null || chapterSelection.isEmpty) {
      return (tracks: allTracks, starts: starts);
    }

    // The picker is built from the *playing item's* chapter list: for a podcast
    // episode that is the episode's chapters, not the show's. The play session
    // exposes exactly that as `chapters` (the player uses it for the now-playing
    // chapter UI), so prefer it and only fall back to the library item's list.
    final sessionChapters = sessionData['chapters'] as List<dynamic>?;
    final chapters = (sessionChapters != null && sessionChapters.isNotEmpty)
        ? sessionChapters
        : (((sessionData['libraryItem'] as Map<String, dynamic>?)?['media']
                as Map<String, dynamic>?)?['chapters'] as List<dynamic>?);
    if (chapters == null || chapters.isEmpty) {
      return (tracks: allTracks, starts: starts);
    }

    final picked = <int>{};
    for (final ci in chapterSelection) {
      if (ci < 0 || ci >= chapters.length) continue;
      final ch = chapters[ci] as Map<String, dynamic>;
      final chStart = (ch['start'] as num?)?.toDouble() ?? 0;
      // Some servers omit `end`; fall back to the next chapter's start (and, for
      // the last chapter, to open-ended) so it is never treated as empty.
      var chEnd = (ch['end'] as num?)?.toDouble() ?? 0;
      if (chEnd <= chStart) {
        chEnd = ci + 1 < chapters.length
            ? (((chapters[ci + 1] as Map<String, dynamic>)['start'] as num?)
                    ?.toDouble() ??
                double.infinity)
            : double.infinity;
      }
      for (int i = 0; i < allTracks.length; i++) {
        if (durations[i] <= 0) continue;
        final fileStart = starts[i];
        final fileEnd = fileStart + durations[i];
        if (chStart < fileEnd && chEnd > fileStart) picked.add(i);
      }
    }
    if (picked.isEmpty) return (tracks: allTracks, starts: starts);

    final ordered = picked.toList()..sort();
    return (
      tracks: [for (final i in ordered) allTracks[i]],
      starts: [for (final i in ordered) starts[i]],
    );
  }

  /// Derive the on-disk filename for a track, preferring its original name so
  /// the layout matches what older (http-based) downloads produced.
  String _trackFileName(Map<String, dynamic> track, int i) {
    final contentUrl = track['contentUrl'] as String? ?? '';
    final trackMeta = track['metadata'] as Map<String, dynamic>?;
    var originalName = trackMeta?['filename'] as String? ?? '';
    if (originalName.isEmpty) {
      final contentPath = Uri.tryParse(contentUrl)?.path ?? contentUrl;
      originalName = Uri.decodeComponent(contentPath.split('/').last);
      if (originalName.contains('?')) originalName = originalName.split('?').first;
    }
    if (originalName.isNotEmpty && originalName.contains('.')) {
      return _sanitizePath(originalName.replaceAll(RegExp(r'\.[^.]+$'), '')) +
          originalName.substring(originalName.lastIndexOf('.'));
    }
    final mimeType = track['mimeType'] as String? ?? 'audio/mpeg';
    final ext = mimeType.contains('mp4')
        ? 'm4a'
        : mimeType.contains('flac')
            ? 'flac'
            : mimeType.contains('ogg')
                ? 'ogg'
                : 'mp3';
    return 'track_${i.toString().padLeft(3, '0')}.$ext';
  }

  /// The player card and full screen player render the downloaded cover at
  /// near screen width, so the stored copy has to be sharper than the 400px
  /// thumbnail URL most callers hold. Leaves local paths and widthless URLs
  /// alone.
  static String _hiResCoverUrl(String url) =>
      url.replaceAllMapped(RegExp(r'width=\d+'), (_) => 'width=1200');

  /// Pixel width of an image file without fully decoding it. Returns null
  /// when the file can't be read as an image.
  static Future<int?> _imageFileWidth(String path) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      descriptor.dispose();
      buffer.dispose();
      return w;
    } catch (_) {
      return null;
    }
  }

  /// Cache the cover into INTERNAL storage (lockscreen / Android Auto / offline).
  /// Always internal, since a custom external audio path may lack write access.
  Future<String?> _cacheCover(ApiService api, String itemId, String? coverUrl) async {
    if (coverUrl == null || coverUrl.isEmpty) return null;
    try {
      final coverResp = await http.get(Uri.parse(_hiResCoverUrl(coverUrl)), headers: api.mediaHeaders)
          .timeout(const Duration(seconds: 10));
      if (coverResp.statusCode == 200 && coverResp.bodyBytes.isNotEmpty) {
        final internalBase = await _internalBasePath;
        final coverDir = Directory('$internalBase/$itemId');
        if (!coverDir.existsSync()) coverDir.createSync(recursive: true);
        final coverFile = File('${coverDir.path}/cover.jpg');
        await coverFile.writeAsBytes(coverResp.bodyBytes);
        debugPrint('[Download] Cached cover image: ${coverFile.path}');
        return coverFile.path;
      }
    } catch (e) {
      debugPrint('[Download] Cover cache failed (non-fatal): $e');
    }
    return null;
  }

  // ── background_downloader update handling ──

  (String, int)? _decodeMeta(String metaData) {
    if (metaData.isEmpty) return null;
    try {
      final m = jsonDecode(metaData) as Map<String, dynamic>;
      final itemId = m['itemId'] as String?;
      final i = m['i'] as int?;
      if (itemId == null || i == null) return null;
      return (itemId, i);
    } catch (_) {
      return null;
    }
  }

  void _onTaskUpdate(TaskUpdate update) {
    final meta = _decodeMeta(update.task.metaData);
    if (meta == null) return;
    final itemId = meta.$1;
    final i = meta.$2;
    final p = _pending[itemId];
    if (p == null) return;
    p.lastUpdate = DateTime.now();

    if (update is TaskProgressUpdate) {
      final prog = update.progress;
      if (prog >= 0 && prog <= 1) {
        p.trackProgress[i] = prog;
        _emitBookProgress(itemId, p);
      }
    } else if (update is TaskStatusUpdate) {
      unawaited(
        _handleTaskStatus(
          itemId: itemId,
          trackIndex: i,
          status: update.status,
          exception: update.exception,
          responseCode: update.responseStatusCode,
        ),
      );
    }
  }

  Future<void> _handleTaskStatus({
    required String itemId,
    required int trackIndex,
    required TaskStatus status,
    TaskException? exception,
    int? responseCode,
  }) async {
    final p = _pending[itemId];
    if (p == null) return;
    p.lastUpdate = DateTime.now();
    p.trackStatus[trackIndex] = status;
    debugPrint(
      '[Download] task $itemId #$trackIndex status=${status.name}'
      '${exception != null ? ' ex=$exception' : ''}'
      '${responseCode != null ? ' code=$responseCode' : ''}',
    );
    if (status == TaskStatus.complete) p.trackProgress[trackIndex] = 1.0;

    // A hard failure aborts the whole book so it does not wait forever for
    // sibling tracks that will never finish on their own.
    if ((status == TaskStatus.failed || status == TaskStatus.notFound) &&
        !p.cancelled &&
        !p.failing) {
      p.failing = true;
      p.failException = exception;
      p.failCode = responseCode;
      // While paused we only remember the failure; routing waits for the
      // resume so an intentional pause can't tear the book down.
      if (!p.paused) unawaited(_cancelSiblings(itemId, p));
    }
    await _checkBookTerminal(itemId, p);
  }

  void _emitBookProgress(String itemId, _PendingBook p) {
    if (p.paused) return; // a late progress update must not un-pause the UI
    final now = DateTime.now();
    if (now.difference(p.lastUi).inMilliseconds < 250) return;
    p.lastUi = now;
    unawaited(_updateBookNotification(itemId, p, now));
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloading,
      progress: p.overallProgress,
      title: p.title,
      author: p.author,
      coverUrl: p.coverUrl,
      libraryId: p.libraryId,
    );
    notifyListeners();
  }

  /// Once every track of a book is terminal, route to success / fail / cancel.
  Future<void> _checkBookTerminal(String itemId, _PendingBook p) async {
    if (p.finalizing) return;
    if (p.paused) return; // pause cancelled sibling tasks; keep the book alive
    for (int i = 0; i < p.trackCount; i++) {
      final s = p.trackStatus[i];
      if (s == null || !_terminal.contains(s)) return;
    }
    if (p.trackStatus.values.every((s) => s == TaskStatus.complete)) {
      p.finalizing = true;
      await _finalizeSuccess(itemId);
    } else if (p.failing) {
      await _failBook(
        itemId,
        taskException: p.failException,
        responseCode: p.failCode,
      );
    } else {
      p.finalizing = true;
      await _handleCanceled(itemId);
    }
  }

  @visibleForTesting
  Future<void> debugSeedPendingDownload({
    required String itemId,
    required int trackCount,
  }) async {
    final bookDir = '${Directory.systemTemp.path}/absorb_download_service_test/$itemId';
    _pending[itemId] = _PendingBook(
      itemId: itemId,
      apiItemId: itemId,
      title: 'Test download',
      bookDir: bookDir,
      trackCount: trackCount,
      expectedPaths: List.generate(
        trackCount,
        (index) => '$bookDir/$index.mp3',
      ),
    );
    _activeDownloadIds.add(itemId);
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloading,
      title: 'Test download',
    );
    await _persistPending();
  }

  @visibleForTesting
  Future<void> debugHandleTaskStatus({
    required String itemId,
    required int trackIndex,
    required TaskStatus status,
    int? responseCode,
  }) =>
      _handleTaskStatus(
        itemId: itemId,
        trackIndex: trackIndex,
        status: status,
        responseCode: responseCode,
      );

  @visibleForTesting
  List<({String url, String filename})> debugResolveDurableFiles({
    required ApiService api,
    required String itemId,
    required List<dynamic> audioTracks,
  }) =>
      _resolveDurableFiles(api, itemId, audioTracks);

  @visibleForTesting
  Future<void> debugReset() async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    await _updatesSub?.cancel();
    _updatesSub = null;
    _downloads.clear();
    _activeDownloadIds.clear();
    _cancelledIds.clear();
    _pending.clear();
    _queue.clear();
    _downloaderConfigured = false;
    _initFuture = null;
    _iosAudioMigrationFuture = null;
    _initialized = false;
    backgroundIsolateMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pending_downloads');
  }

  /// Move a completed book's internal files into the SAF folder [treeUri] under
  /// [subfolder] (e.g. "Author/Title"), via the native DocumentFile helper.
  /// Returns the created folder URI and the per-file content URIs, or null if
  /// the move failed. [markerJson] (a JSON string identifying the book) is
  /// written into the SAF folder as a small marker file so a later folder scan
  /// can recognize the book without opening any audio bytes.
  Future<({String dirUri, List<String> fileUris})?> _moveBookToSaf(
      String treeUri, String subfolder, List<String> filenames, List<String> tempPaths,
      [String? markerJson]) async {
    try {
      final res = await _storageChannel.invokeMethod<Map>('moveBookToSaf', {
        'treeUri': treeUri,
        'subfolder': subfolder,
        'filenames': filenames,
        'tempPaths': tempPaths,
        if (markerJson != null) 'marker': markerJson,
      });
      final dirUri = res?['dirUri'] as String?;
      final fileUris = (res?['fileUris'] as List?)?.map((e) => e as String).toList();
      if (dirUri == null || fileUris == null || fileUris.length != filenames.length) {
        return null;
      }
      return (dirUri: dirUri, fileUris: fileUris);
    } catch (e) {
      debugPrint('[Download] moveBookToSaf failed: $e');
      return null;
    }
  }

  Future<void> _finalizeSuccess(String itemId) async {
    final p = _pending[itemId];
    if (p == null) return;

    // Files always land in internal storage first.
    final localPaths = p.expectedPaths.where((path) => File(path).existsSync()).toList();
    if (localPaths.length != p.trackCount) {
      debugPrint('[Download] Finalize "$itemId": only ${localPaths.length}/${p.trackCount} '
          'files present, treating as failure');
      p.finalizing = false; // let _failBook proceed
      await _failBook(itemId, cause: 'Missing files after download');
      return;
    }

    var finalPaths = localPaths;
    String? finalDirPath = p.bookDir;

    // SAF: move the downloaded files into the user's chosen folder under
    // "Author/Title" and play/delete via the returned content URIs. If the move
    // fails the book stays usable from its internal copy. A tiny marker file is
    // written into the SAF folder so a later scan can recognize this book.
    if (p.isSaf) {
      final filenames = [for (final path in localPaths) path.split('/').last];
      // A tiny marker file is written into the SAF folder so a later scan can
      // recognize this book and restore it fully offline. It carries the slim
      // session (the same JSON this download persists) so playback metadata
      // survives without the network; only the audio bytes are re-scanned.
      final marker = _encodeMarker(jsonEncode({
        'itemId': p.itemId,
        'apiItemId': p.apiItemId,
        'episodeId': p.episodeId,
        'title': p.title,
        'author': p.author,
        'libraryId': p.libraryId,
        'coverUrl': p.coverUrl,
        'session': _compactMarkerSession(p.slimSessionJson),
      }));
      final moved = await _moveBookToSaf(
          p.safTreeUri!, p.safSubfolder ?? '', filenames, localPaths, marker);
      if (moved != null) {
        finalPaths = moved.fileUris;
        finalDirPath = moved.dirUri;
        await _cleanupBookDir(p.bookDir); // drop the now-empty internal temp dir
      } else {
        debugPrint('[Download] SAF move failed for "$itemId", keeping internal copy');
      }
    } else if (Platform.isIOS) {
      for (final path in localPaths) {
        await _excludeFromBackup(path);
      }
    }

    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloaded,
      localPaths: finalPaths,
      sessionData: p.slimSessionJson,
      title: p.title,
      author: p.author,
      coverUrl: p.coverUrl,
      localCoverPath: p.localCoverPath,
      localDirPath: finalDirPath,
      libraryId: p.libraryId,
    );
    await _save();
    _activeDownloadIds.remove(itemId);
    _pending.remove(itemId);
    await _persistPending();
    await _deleteDbRecords(itemId, p.trackCount);
    notifyListeners();

    // Hot-swap if this book is currently streaming. switchToLocal reads the
    // live position, so it's safe even when this fires from a background update.
    try {
      final player = AudioPlayerService();
      if (player.hasBook) {
        await player.switchToLocal(itemId);
      }
    } catch (_) {}

    debugPrint('[Download] Complete: ${p.title} (${localPaths.length} files)');
    unawaited(_processQueue());
  }

  Future<void> _failBook(
    String itemId, {
    Object? cause,
    TaskException? taskException,
    int? responseCode,
    String? title,
    String? author,
    String? coverUrl,
    String? bookDirRef,
  }) async {
    final p = _pending[itemId];
    if (p != null) {
      if (p.finalizing) return;
      p.finalizing = true;
    }
    final t = title ?? p?.title ?? '';
    final a = author ?? p?.author;
    final c = coverUrl ?? p?.coverUrl;
    final dir = bookDirRef ?? p?.bookDir;

    if (p != null) await _cancelSiblings(itemId, p, force: true);
    // Stall/zombie fails have no errored task, so the canceled siblings end
    // the group notification as "complete" - dismiss it. When a task really
    // failed the group correctly shows the error notification; leave that.
    if (p != null && !p.failing && p.trackCount > 1) {
      _dismissGroupNotification(itemId);
    }
    await _cleanupBookDir(dir);

    final msg = _mapError(cause, taskException, responseCode);
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.error,
      title: t,
      author: a,
      coverUrl: c,
    );
    _activeDownloadIds.remove(itemId);
    _pending.remove(itemId);
    await _persistPending();
    await _deleteDbRecords(itemId, p?.trackCount ?? 0);
    _cancelledIds.remove(itemId);
    debugPrint('[Download] Failed "$t": $msg (${cause ?? taskException?.description})');
    notifyListeners();
    unawaited(_processQueue());
  }

  Future<void> _handleCanceled(String itemId) async {
    final p = _pending[itemId];
    // A canceled book still ends its group notification as "complete" (the
    // package counts canceled tasks as finished, not failed), which would
    // leave a lingering "Download Complete" for a book the user just
    // canceled - dismiss it.
    if ((p?.trackCount ?? 0) > 1) _dismissGroupNotification(itemId);
    await _cleanupBookDir(p?.bookDir);
    _downloads.remove(itemId);
    _activeDownloadIds.remove(itemId);
    _pending.remove(itemId);
    await _persistPending();
    await _deleteDbRecords(itemId, p?.trackCount ?? 0);
    _cancelledIds.remove(itemId);
    debugPrint('[Download] Cancelled: ${p?.title ?? itemId}');
    notifyListeners();
    unawaited(_processQueue());
  }

  /// Dismiss a book's group download notification. The package posts the
  /// terminal group notification from native workers slightly after the last
  /// task ends, so sweep twice. Android only: on iOS the package posts under
  /// string identifiers flutter_local_notifications can't target, and there a
  /// stray "complete" only sits silently in the notification center.
  void _dismissGroupNotification(String itemId) {
    if (!Platform.isAndroid) return;
    final id = _groupNotifId(itemId);
    for (final delay in const [Duration(seconds: 1), Duration(seconds: 4)]) {
      Future.delayed(delay, () async {
        try {
          await FlutterLocalNotificationsPlugin().cancel(id);
        } catch (e) {
          debugPrint('[Download] dismiss group notification failed: $e');
        }
      });
    }
  }

  /// The package derives its group notification id on the Kotlin side as
  /// "groupNotification$name".hashCode() - reproduce Java's string hash so we
  /// can address the same notification.
  int _groupNotifId(String itemId) {
    var h = 0;
    for (final u in 'groupNotification$itemId'.codeUnits) {
      h = (h * 31 + u) & 0xFFFFFFFF;
    }
    return h >= 0x80000000 ? h - 0x100000000 : h;
  }

  /// Byte-accurate progress for a multi-file book's notification (Android).
  /// The package's group notification only counts finished files, so with
  /// parallel per-file tasks the bar sits at 0 until files start completing
  /// (a half-downloaded book reads "0 / 5"). We already aggregate the real
  /// byte progress for the in-app UI, so post it onto the same notification
  /// id the package uses. The package only re-posts on task state changes
  /// (enqueue/start/finish), so between those moments this owns the
  /// notification, and the package's terminal complete/error post still
  /// lands last.
  Future<void> _updateBookNotification(String itemId, _PendingBook p, DateTime now) async {
    if (!Platform.isAndroid || p.trackCount <= 1) return;
    if (p.finalizing || p.cancelled) return;
    final done = p.trackStatus.values.where((s) => s == TaskStatus.complete).length;
    if (done >= p.trackCount) return; // the terminal post owns it from here
    final pct = (p.overallProgress * 100).clamp(0.0, 100.0).round();
    if (pct == p.notifPct && done == p.notifDone) return;
    if (now.difference(p.notifPost).inMilliseconds < 1000) return;
    p.notifPct = pct;
    p.notifDone = done;
    p.notifPost = now;
    try {
      await FlutterLocalNotificationsPlugin().show(
        _groupNotifId(itemId),
        p.title,
        '$done / ${p.trackCount}',
        NotificationDetails(
          // Same channel the package posts on, so no second channel shows up
          // in the app's notification settings.
          android: AndroidNotificationDetails(
            'background_downloader',
            'Downloads',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: 100,
            progress: pct,
            // The package's own download icon (kept alive by its Kotlin R
            // reference), so the icon doesn't flick when the package posts.
            icon: 'outline_file_download_24',
          ),
        ),
      );
    } catch (e) {
      debugPrint('[Download] progress notification failed: $e');
    }
  }

  Future<void> _cancelSiblings(
    String itemId,
    _PendingBook p, {
    bool force = false,
  }) async {
    final ids = <String>[];
    for (int i = 0; i < p.trackCount; i++) {
      final s = p.trackStatus[i];
      if (force || s == null || !_terminal.contains(s)) ids.add(_taskId(itemId, i));
    }
    if (ids.isNotEmpty) {
      try {
        final cancelTasks = _cancelTasksOverride;
        if (cancelTasks != null) {
          await cancelTasks(ids);
        } else {
          await FileDownloader().cancelTasksWithIds(ids);
        }
      } catch (_) {}
    }
  }

  /// Remove a book's download folder. [bookDir] is a filesystem path. SAF
  /// downloads share the user's granted folder, so there's no per-book folder
  /// to remove (cleanup of SAF files is per-file via [deleteDownload]).
  Future<void> _cleanupBookDir(String? bookDir) async {
    if (bookDir == null || isContentUri(bookDir)) return;
    final dir = Directory(bookDir);
    try {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        final parent = dir.parent;
        if (parent.existsSync() && parent.listSync().isEmpty) parent.deleteSync();
      }
    } catch (_) {}
  }

  String _mapError(Object? cause, TaskException? te, int? code) {
    final s = '${cause ?? ''} ${te?.description ?? ''}'.toLowerCase();
    if (s.contains('no space') || s.contains('enospc')) return 'Not enough storage space';
    if (s.contains('permission') || s.contains('not permitted') || code == 403) {
      return 'Permission denied - check download location in Settings';
    }
    return 'Download failed';
  }

  Future<void> _deleteDbRecords(String itemId, int trackCount) async {
    for (int i = 0; i < trackCount; i++) {
      try {
        final taskId = _taskId(itemId, i);
        final deleteTaskRecord = _deleteTaskRecordOverride;
        if (deleteTaskRecord != null) {
          await deleteTaskRecord(taskId);
        } else {
          await FileDownloader().database.deleteRecordWithId(taskId);
        }
      } catch (_) {}
    }
  }

  // ── Resume-after-kill persistence ──

  Future<void> _persistPending() async {
    final prefs = await SharedPreferences.getInstance();
    if (_pending.isEmpty) {
      await prefs.remove('pending_downloads');
      return;
    }
    final map = {for (final e in _pending.entries) e.key: e.value.toJson()};
    await prefs.setString('pending_downloads', jsonEncode(map));
  }

  Future<void> _loadPending() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('pending_downloads');
    if (json == null) return;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      for (final e in map.entries) {
        final p = _PendingBook.fromJson(e.value as Map<String, dynamic>);
        _pending[e.key] = p;
        if (p.paused) {
          // Stay paused across relaunches: don't hold the download slot.
          _markPaused(e.key, p);
          continue;
        }
        _activeDownloadIds.add(e.key);
        _downloads[e.key] = DownloadInfo(
          itemId: e.key,
          status: DownloadStatus.downloading,
          progress: 0,
          title: p.title,
          author: p.author,
          coverUrl: p.coverUrl,
          libraryId: p.libraryId,
        );
      }
    } catch (e) {
      debugPrint('[Download] loadPending error: $e');
    }
  }

  Future<void> _loadAutoDownloadBlocks() async {
    final prefs = await SharedPreferences.getInstance();
    _autoDownloadBlocked
      ..clear()
      ..addAll(prefs.getStringList(_autoDownloadBlockedKey) ?? const []);
  }

  Future<void> _saveAutoDownloadBlocks() async {
    final prefs = await SharedPreferences.getInstance();
    if (_autoDownloadBlocked.isEmpty) {
      await prefs.remove(_autoDownloadBlockedKey);
    } else {
      await prefs.setStringList(
          _autoDownloadBlockedKey, _autoDownloadBlocked.toList());
    }
  }

  /// Rebuild in-flight progress from the package task DB after a relaunch, then
  /// finalize books that finished while we were dead and drop ones whose tasks
  /// are gone. Tasks still in flight keep running; their updates (plus
  /// resumeFromBackground) drive them to terminal.
  Future<void> _rehydratePending() async {
    if (_pending.isEmpty) return;
    List<TaskRecord> records;
    try {
      records = await FileDownloader().database.allRecords();
    } catch (_) {
      records = const [];
    }

    final tracked = <String, Set<int>>{};
    for (final r in records) {
      final meta = _decodeMeta(r.task.metaData);
      if (meta == null) continue;
      final p = _pending[meta.$1];
      if (p == null) continue;
      final i = meta.$2;
      p.trackStatus[i] = r.status;
      p.trackProgress[i] = r.status == TaskStatus.complete
          ? 1.0
          : (r.progress >= 0 && r.progress <= 1 ? r.progress : 0.0);
      (tracked[meta.$1] ??= {}).add(i);
    }

    for (final itemId in _pending.keys.toList()) {
      final p = _pending[itemId]!;
      if (p.paused) {
        // Paused items normally have no live tasks, but a pause that raced an
        // app kill can leave them running: pause any that are still live so
        // nothing keeps downloading in the background.
        final live = await _itemTasks(itemId, {
          TaskStatus.running,
          TaskStatus.enqueued,
          TaskStatus.waitingToRetry,
        });
        if (live.isNotEmpty) {
          try {
            await FileDownloader().pauseAll(tasks: live);
          } catch (_) {}
        }
        _markPaused(itemId, p);
        continue;
      }

      // Desync guard: a resume that was persisted moments before the app was
      // killed can leave `paused=false` while the package tasks are still
      // paused. Keep the item paused instead of showing a frozen "downloading".
      final trackedIdx = tracked[itemId];
      if (trackedIdx != null &&
          trackedIdx.any((i) => p.trackStatus[i] == TaskStatus.paused)) {
        p.paused = true;
        await _persistPending();
        _markPaused(itemId, p);
        continue;
      }

      bool allComplete = p.trackCount > 0;
      bool allTerminal = true;
      for (int i = 0; i < p.trackCount; i++) {
        final s = p.trackStatus[i];
        if (s != TaskStatus.complete) allComplete = false;
        if (s == null || !_terminal.contains(s)) allTerminal = false;
      }

      if (allComplete) {
        p.finalizing = true;
        await _finalizeSuccess(itemId);
      } else if (allTerminal) {
        // No p.finalizing pre-set here or below: _failBook refuses to run
        // when it's already true (see the reconciler note).
        await _failBook(itemId, cause: 'Interrupted download');
      } else if ((tracked[itemId]?.isEmpty ?? true)) {
        // The package has no record of these tasks (DB wiped) and we can't
        // rebuild durable URLs here, so surface as failed for a manual retry.
        await _failBook(itemId, cause: 'Interrupted download');
      } else {
        // Still in flight: leave it; updates + resumeFromBackground finish it.
        _emitBookProgress(itemId, p);
      }
    }
  }

  /// [byUser] marks a deliberate removal: the auto-download planners then
  /// leave this item alone until a manual download, or a play with
  /// download-on-stream on, brings it back - see [downloadItem].
  Future<void> deleteDownload(
    String itemId, {
    bool skipStopCheck = false,
    bool byUser = false,
  }) async {
    if (byUser && _autoDownloadBlocked.add(itemId)) {
      debugPrint(
          '[Download] $itemId removed by the user - auto-download leaves it alone from now on');
      await _saveAutoDownloadBlocks();
    }
    // If this is still downloading or waiting for a slot, cancel it (which
    // cleans up partial files and the background tasks) rather than deleting.
    if (_pending.containsKey(itemId) || _queue.any((q) => q.itemId == itemId)) {
      cancelDownload(itemId);
      return;
    }

    final info = _downloads[itemId];
    if (info == null) return;

    // Stop playback if this item is currently playing to avoid crashes. An
    // episode key has to match the playing episode, not just its show:
    // matching on the show alone stopped whatever was playing whenever
    // another episode of the same podcast was deleted.
    if (!skipStopCheck) {
      final player = AudioPlayerService();
      final playingId = player.currentItemId;
      final playingKey = playingId == null
          ? null
          : player.currentEpisodeId == null
              ? playingId
              : '$playingId-${player.currentEpisodeId}';
      if (playingKey == itemId) {
        await player.stop();
      }
    }

    for (final path in info.localPaths) {
      try {
        if (isContentUri(path)) {
          await FileDownloader().uri.deleteFile(Uri.parse(path));
        } else {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        }
      } catch (_) {}
    }

    // Remove the download directory (new-style path from DownloadInfo, or legacy UUID path)
    try {
      final dirPath = info.localDirPath;
      if (dirPath != null && isContentUri(dirPath)) {
        // SAF book folder: best-effort delete (harmless if already emptied).
        try {
          await FileDownloader().uri.deleteFile(Uri.parse(dirPath));
        } catch (_) {}
      } else if (dirPath != null && Directory(dirPath).existsSync()) {
        Directory(dirPath).deleteSync(recursive: true);
        // Clean up empty parent (Author folder) if it's now empty
        final parent = Directory(dirPath).parent;
        if (parent.existsSync() && parent.listSync().isEmpty) {
          parent.deleteSync();
        }
      } else {
        // Legacy fallback: UUID-based directory
        final basePath = await downloadBasePath;
        final bookDir = Directory('$basePath/$itemId');
        if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
      }
    } catch (_) {}

    try {
      final internalBase = await _internalBasePath;
      final coverDir = Directory('$internalBase/$itemId');
      final coverFile = File('$internalBase/$itemId/cover.jpg');
      // FileImage caches by path; evict so a re-download at the same path renders fresh.
      if (coverFile.existsSync()) {
        final evicted = PaintingBinding.instance.imageCache
            .evict(FileImage(coverFile));
        debugPrint('[Download] evict cover ${coverFile.path} -> $evicted');
      }
      if (coverDir.existsSync()) coverDir.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('[Download] cover cleanup failed: $e');
    }

    // Drop the offline ebook copy too, if any.
    await deleteCachedEbook(itemId);

    _downloads.remove(itemId);
    await _save();
    notifyListeners();
  }

  void cancelDownload(String itemId) {
    // Drop it from the waiting queue if it never started.
    _queue.removeWhere((q) => q.itemId == itemId);

    // Flag so an in-flight _executeDownload bails before enqueueing, and so a
    // book mid-resolution doesn't leak an active slot.
    _cancelledIds.add(itemId);

    final p = _pending[itemId];
    if (p != null && !p.finalizing) {
      p.cancelled = true;
      // Ask the package to cancel any live tasks, then clean up ourselves. We do
      // NOT wait for the package's `canceled` update: it never fires for tasks
      // the package no longer tracks (e.g. records left over after an app
      // update), which would leak the slot and wedge the whole queue.
      final ids = [for (int i = 0; i < p.trackCount; i++) _taskId(itemId, i)];
      unawaited(FileDownloader().cancelTasksWithIds(ids));
      unawaited(_handleCanceled(itemId)); // frees the slot + processes the queue
    } else {
      _activeDownloadIds.remove(itemId);
    }

    // Drop a companion ebook the fire-and-forget fetch may have already
    // landed, so a cancelled download doesn't orphan it.
    unawaited(deleteCachedEbook(itemId));

    // Instant UI feedback (cleanup paths also notify).
    _downloads.remove(itemId);
    notifyListeners();
  }

  // ── Pause / resume ──

  /// Surfaces [itemId] as paused: frees its download slot and updates the
  /// Downloads screen entry.
  void _markPaused(String itemId, _PendingBook p) {
    _activeDownloadIds.remove(itemId);
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.paused,
      progress: p.overallProgress,
      title: p.title,
      author: p.author,
      coverUrl: p.coverUrl,
      libraryId: p.libraryId,
    );
  }

  /// Returns the package's task objects for [itemId], filtered to [statuses].
  /// Used to pause/resume exactly the tracks of one book instead of the whole
  /// downloader.
  Future<List<DownloadTask>> _itemTasks(
    String itemId,
    Set<TaskStatus> statuses,
  ) async {
    final result = <DownloadTask>[];
    try {
      final records = await FileDownloader().database.allRecords();
      for (final r in records) {
        final meta = _decodeMeta(r.task.metaData);
        if (meta == null || meta.$1 != itemId) continue;
        if (!statuses.contains(r.status)) continue;
        final task = r.task;
        if (task is DownloadTask) result.add(task);
      }
    } catch (_) {}
    return result;
  }

  /// Pauses a running download natively: the package keeps every partial file
  /// and the task record, so [resumeDownload] continues from the same byte
  /// range without re-downloading tracks that already finished. Releases the
  /// download slot and surfaces the item in [pausedDownloads].
  Future<void> pauseDownload(String itemId) async {
    final p = _pending[itemId];
    if (p == null || p.finalizing || p.paused) return;
    p.paused = true;
    await _persistPending();

    final tasks = await _itemTasks(itemId, {
      TaskStatus.running,
      TaskStatus.enqueued,
      TaskStatus.waitingToRetry,
    });
    if (tasks.isNotEmpty) {
      try {
        await FileDownloader().pauseAll(tasks: tasks);
      } catch (_) {}
    } else {
      // Nothing live to pause (e.g. paused between enqueues): cancel any
      // leftovers so the slot frees; resume falls back to a normal download.
      unawaited(_cancelSiblings(itemId, p));
    }

    _markPaused(itemId, p);
    notifyListeners();
    unawaited(_processQueue());
  }

  /// Resumes a paused download, continuing the paused package tasks where they
  /// left off. Falls back to a fresh [downloadItem] run if the package has no
  /// paused records left (e.g. they were cleared between sessions).
  Future<void> resumeDownload(String itemId, {required ApiService api}) async {
    final p = _pending[itemId];
    if (p == null || !p.paused) return;
    p.paused = false;
    await _persistPending();

    final tasks = await _itemTasks(itemId, {TaskStatus.paused});
    if (tasks.isEmpty) {
      // Package has no paused records to continue from: try a clean restart.
      // Drop the stale paused marker first so downloadItem isn't blocked by it.
      _pending.remove(itemId);
      await _persistPending();
      final err = await downloadItem(
        api: api,
        itemId: p.itemId,
        title: p.title,
        author: p.author,
        coverUrl: p.coverUrl,
        episodeId: p.episodeId,
        libraryId: p.libraryId,
        selectedChapters: p.selectedChapters,
      );
      if (err != null) {
        // Couldn't restart (e.g. Wi-Fi-only while offline): put it back, paused.
        _pending[itemId] = p..paused = true;
        await _persistPending();
        _markPaused(itemId, p);
        notifyListeners();
      }
      return;
    }

    _activeDownloadIds.add(itemId);
    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloading,
      progress: p.overallProgress,
      title: p.title,
      author: p.author,
      coverUrl: p.coverUrl,
      libraryId: p.libraryId,
    );
    notifyListeners();
    unawaited(FileDownloader().resumeAll(tasks: tasks));
  }

  // ── Per-track management for completed downloads ──

  /// Lists every audio file of a completed download, index-aligned with
  /// [DownloadInfo.localPaths] / `sessionData['audioTracks']`.
  List<LocalTrackInfo> getLocalTracks(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) {
      return const [];
    }
    final tracks = <Map<String, dynamic>>[];
    List<double>? starts;
    if (info.sessionData != null) {
      try {
        final s = jsonDecode(info.sessionData!) as Map<String, dynamic>;
        tracks.addAll(
            (s['audioTracks'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
                const []);
        starts = (s['trackStartOffsets'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList();
      } catch (_) {}
    }
    final result = <LocalTrackInfo>[];
    double cumulative = 0;
    for (int i = 0; i < info.localPaths.length; i++) {
      final path = info.localPaths[i];
      final meta = i < tracks.length ? tracks[i] : null;
      final metaFile = meta?['metadata'];
      var title = metaFile is Map<String, dynamic>
          ? (metaFile['filename'] as String? ?? '')
          : '';
      if (title.isEmpty && !isContentUri(path)) {
        title = path.split(RegExp(r'[\\/]')).last;
      }
      final duration = (meta?['duration'] as num?)?.toDouble() ?? 0;
      final absStart =
          (starts != null && i < starts.length) ? starts[i] : cumulative;
      int size = 0;
      bool exists = false;
      bool saf = isContentUri(path);
      DateTime? downloadedAt;
      if (!saf) {
        try {
          final file = File(path);
          exists = file.existsSync();
          if (exists) {
            size = file.lengthSync();
            downloadedAt = file.lastModifiedSync();
          }
        } catch (_) {}
      } else {
        exists = true;
      }
      result.add(LocalTrackInfo(
        index: i,
        path: path,
        title: title.isEmpty ? 'Track ${i + 1}' : title,
        sizeBytes: size,
        exists: exists,
        durationSeconds: duration,
        absoluteStart: absStart,
        downloadedAt: downloadedAt,
      ));
      cumulative += duration;
    }
    return result;
  }

  /// Indices of [chapters] already covered by a completed download of
  /// [itemId]. The picker grey them out and keeps them when re-downloading.
  /// Mirrors the overlap rule in [_resolveSelectedTracks].
  Set<int> downloadedChapterIndices(String itemId, List<dynamic> chapters) {
    final result = <int>{};
    if (chapters.isEmpty || !isDownloaded(itemId)) return result;
    final tracks = getLocalTracks(itemId);
    if (tracks.isEmpty) return result;
    for (int ci = 0; ci < chapters.length; ci++) {
      final ch = chapters[ci] as Map<String, dynamic>;
      final chStart = (ch['start'] as num?)?.toDouble() ?? 0;
      // Same end fallback as [_resolveSelectedTracks].
      var chEnd = (ch['end'] as num?)?.toDouble() ?? 0;
      if (chEnd <= chStart) {
        chEnd = ci + 1 < chapters.length
            ? (((chapters[ci + 1] as Map<String, dynamic>)['start'] as num?)
                    ?.toDouble() ??
                double.infinity)
            : double.infinity;
      }
      for (final t in tracks) {
        if (t.durationSeconds <= 0) continue;
        final fileStart = t.absoluteStart;
        final fileEnd = fileStart + t.durationSeconds;
        if (chStart < fileEnd && chEnd > fileStart) {
          result.add(ci);
          break;
        }
      }
    }
    return result;
  }

  /// Number of chapters already saved by a completed download vs the book's
  /// full chapter count, derived from the persisted playback session (no
  /// filesystem I/O). Returns null when the item isn't downloaded or the
  /// session has no chapter list.
  ///
  /// Uses the same chapter/track overlap rule as [downloadedChapterIndices]
  /// (and therefore [_resolveSelectedTracks]) so the count matches the picker.
  ({int saved, int total})? chapterDownloadCounts(String itemId) {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) {
      _chapterCountCache.remove(itemId);
      return null;
    }
    final src = info.sessionData;
    final cached = _chapterCountCache[itemId];
    if (cached != null && cached.src == src) {
      return (saved: cached.saved, total: cached.total);
    }
    if (src == null) return null;
    try {
      final session = jsonDecode(src) as Map<String, dynamic>;
      final chapters = session['chapters'] as List<dynamic>? ?? const [];
      if (chapters.isEmpty) return null;
      // The persisted session carries the downloaded track subset with their
      // true full-book starts, so no file probing is needed for the overlap.
      final tracks = session['audioTracks'] as List<dynamic>? ?? const [];
      final starts = (session['trackStartOffsets'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final ranges = <({double start, double end})>[];
      for (var i = 0; i < tracks.length; i++) {
        if (i >= starts.length) break;
        final duration =
            ((tracks[i] as Map<String, dynamic>)['duration'] as num?)
                    ?.toDouble() ??
                0;
        if (duration <= 0) continue;
        ranges.add((start: starts[i], end: starts[i] + duration));
      }
      var saved = 0;
      for (var ci = 0; ci < chapters.length; ci++) {
        final ch = chapters[ci] as Map<String, dynamic>;
        final chStart = (ch['start'] as num?)?.toDouble() ?? 0;
        // Same end fallback as [_resolveSelectedTracks].
        var chEnd = (ch['end'] as num?)?.toDouble() ?? 0;
        if (chEnd <= chStart) {
          chEnd = ci + 1 < chapters.length
              ? (((chapters[ci + 1] as Map<String, dynamic>)['start'] as num?)
                      ?.toDouble() ??
                  double.infinity)
              : double.infinity;
        }
        for (final r in ranges) {
          if (chStart < r.end && chEnd > r.start) {
            saved++;
            break;
          }
        }
      }
      _chapterCountCache[itemId] =
          (src: src, saved: saved, total: chapters.length);
      return (saved: saved, total: chapters.length);
    } catch (e) {
      debugPrint('[Download] chapterDownloadCounts failed for $itemId: $e');
      return null;
    }
  }

  /// Chapters of [chapters] covered by a completed download of [itemId],
  /// computed from the persisted session's track ranges only — no filesystem
  /// I/O. Mirrors the overlap rule in [_resolveSelectedTracks] (and therefore
  /// [downloadedChapterIndices]); safe to call from hot card build paths where
  /// [downloadedChapterIndices]' file probing would be too heavy. Falls back
  /// to the file-aware variant when no session data is available.
  Set<int> downloadedChapterIndicesCached(
      String itemId, List<dynamic> chapters) {
    if (itemId.isEmpty || chapters.isEmpty || !isDownloaded(itemId)) {
      _chapterIndicesCache.remove(itemId);
      return const {};
    }
    final info = _downloads[itemId];
    final src = info?.sessionData;
    final cached = _chapterIndicesCache[itemId];
    if (cached != null && cached.src == src) return cached.indices;
    Set<int> result;
    if (src == null) {
      result = downloadedChapterIndices(itemId, chapters);
    } else {
      try {
        final session = jsonDecode(src) as Map<String, dynamic>;
        final tracks = session['audioTracks'] as List<dynamic>? ?? const [];
        final starts = (session['trackStartOffsets'] as List<dynamic>?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const <double>[];
        final ranges = <({double start, double end})>[];
        for (var i = 0; i < tracks.length; i++) {
          if (i >= starts.length) break;
          final duration = ((tracks[i] as Map<String, dynamic>)['duration']
                      as num?)
                  ?.toDouble() ??
              0;
          if (duration <= 0) continue;
          ranges.add((start: starts[i], end: starts[i] + duration));
        }
        if (ranges.isEmpty) {
          result = downloadedChapterIndices(itemId, chapters);
        } else {
          final computed = <int>{};
          for (var ci = 0; ci < chapters.length; ci++) {
            final ch = chapters[ci] as Map<String, dynamic>;
            final chStart = (ch['start'] as num?)?.toDouble() ?? 0;
            // Same end fallback as [_resolveSelectedTracks].
            var chEnd = (ch['end'] as num?)?.toDouble() ?? 0;
            if (chEnd <= chStart) {
              chEnd = ci + 1 < chapters.length
                  ? (((chapters[ci + 1] as Map<String, dynamic>)['start']
                              as num?)
                          ?.toDouble() ??
                      double.infinity)
                  : double.infinity;
            }
            for (final r in ranges) {
              if (chStart < r.end && chEnd > r.start) {
                computed.add(ci);
                break;
              }
            }
          }
          result = computed;
        }
      } catch (e) {
        debugPrint(
            '[Download] downloadedChapterIndicesCached failed for $itemId: $e');
        result = downloadedChapterIndices(itemId, chapters);
      }
    }
    _chapterIndicesCache[itemId] = (src: src, indices: result);
    return result;
  }

  /// Whether the currently-relevant unit should read as "saved":
  ///
  /// - Podcast episode ([episodeId] set): the episode key owns its download,
  ///   so the whole-item state is per-episode already.
  /// - Book with no chapter list (single-file): the plain item key.
  /// - Multi-chapter book ([chapters] + [chapterIndex]): only when the chapter
  ///   at [chapterIndex] is actually covered by the download — a partial album
  ///   download must not badge every chapter as saved.
  bool isCurrentChapterSaved({
    String? episodeId,
    required String itemId,
    List<dynamic> chapters = const [],
    int chapterIndex = -1,
  }) {
    if (itemId.isEmpty) return false;
    if (episodeId != null) return isDownloaded('$itemId-$episodeId');
    if (chapters.isEmpty || chapterIndex < 0) return isDownloaded(itemId);
    return downloadedChapterIndicesCached(itemId, chapters)
        .contains(chapterIndex);
  }

  /// Deletes one audio file of a completed download and keeps the item's
  /// metadata consistent (trims `localPaths` + `sessionData.audioTracks` so
  /// offline playback maps 1:1). Deleting the last remaining track removes the
  /// whole download. SAF (content URI) tracks are skipped.
  Future<void> deleteLocalTrack(String itemId, int index) async {
    final info = _downloads[itemId];
    if (info == null || info.status != DownloadStatus.downloaded) return;
    if (index < 0 || index >= info.localPaths.length) return;
    if (isContentUri(info.localPaths[index])) return;

    if (info.localPaths.length <= 1) {
      await deleteDownload(itemId, skipStopCheck: true, byUser: true);
      return;
    }

    try {
      final file = File(info.localPaths[index]);
      if (file.existsSync()) await file.delete();
    } catch (_) {}

    final newPaths = List<String>.from(info.localPaths)..removeAt(index);
    var newSession = info.sessionData;
    if (newSession != null) {
      try {
        final s = jsonDecode(newSession) as Map<String, dynamic>;
        final tracks = s['audioTracks'] as List<dynamic>?;
        if (tracks != null && index < tracks.length) {
          tracks.removeAt(index);
          s['audioTracks'] = tracks;
        }
        final starts = s['trackStartOffsets'] as List<dynamic>?;
        if (starts != null && index < starts.length) {
          starts.removeAt(index);
          s['trackStartOffsets'] = starts;
        }
        newSession = jsonEncode(s);
      } catch (_) {}
    }

    _downloads[itemId] = DownloadInfo(
      itemId: itemId,
      status: DownloadStatus.downloaded,
      localPaths: newPaths,
      sessionData: newSession,
      title: info.title,
      author: info.author,
      coverUrl: info.coverUrl,
      localCoverPath: info.localCoverPath,
      localDirPath: info.localDirPath,
      libraryId: info.libraryId,
    );
    await _save();
    notifyListeners();
  }

  /// Deletes the audio tracks covered by [chapterIndices] (indices into
  /// [chapters]) of a downloaded [itemId]. Mirrors the chapter↔track overlap
  /// rule used at download time so removing one chapter only drops the files
  /// that actually belong to it; removing the last remaining track removes the
  /// whole download (same as [deleteLocalTrack]). Returns how many tracks were
  /// deleted (0 when nothing matched).
  Future<int> deleteDownloadChapters(
      String itemId, List<dynamic> chapters, List<int> chapterIndices) async {
    final info = _downloads[itemId];
    if (info == null ||
        info.status != DownloadStatus.downloaded ||
        chapters.isEmpty ||
        chapterIndices.isEmpty) {
      return 0;
    }
    final src = info.sessionData;
    if (src == null) {
      // Legacy single-file download: no session tracks to trim, so a
      // chapter-level removal clears the whole download.
      await deleteDownload(itemId, skipStopCheck: true, byUser: true);
      return info.localPaths.length;
    }
    var tracks = <int>{};
    try {
      final session = jsonDecode(src) as Map<String, dynamic>;
      final tks = session['audioTracks'] as List<dynamic>? ?? const [];
      if (tks.isEmpty) {
        await deleteDownload(itemId, skipStopCheck: true, byUser: true);
        return info.localPaths.length;
      }
      final starts = (session['trackStartOffsets'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final durations = <double>[
        for (final t in tks)
          ((t as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0,
      ];
      for (final ci in chapterIndices) {
        if (ci < 0 || ci >= chapters.length) continue;
        final ch = chapters[ci] as Map<String, dynamic>;
        final chStart = (ch['start'] as num?)?.toDouble() ?? 0;
        // Same end fallback as [_resolveSelectedTracks].
        var chEnd = (ch['end'] as num?)?.toDouble() ?? 0;
        if (chEnd <= chStart) {
          chEnd = ci + 1 < chapters.length
              ? (((chapters[ci + 1] as Map<String, dynamic>)['start'] as num?)
                      ?.toDouble() ??
                  double.infinity)
              : double.infinity;
        }
        for (var i = 0; i < tks.length; i++) {
          if (durations[i] <= 0) continue;
          final fileStart = i < starts.length ? starts[i] : 0.0;
          final fileEnd = fileStart + durations[i];
          if (chStart < fileEnd && chEnd > fileStart) tracks.add(i);
        }
      }
    } catch (_) {
      // Fall back to clearing the download when the session can't be parsed.
      await deleteDownload(itemId, skipStopCheck: true, byUser: true);
      return info.localPaths.length;
    }
    if (tracks.isEmpty) return 0;
    final ordered = tracks.toList()..sort((a, b) => b.compareTo(a));
    for (final t in ordered) {
      await deleteLocalTrack(itemId, t);
    }
    return ordered.length;
  }

  /// Items the user paused mid-download.
  List<DownloadInfo> get pausedDownloads => _downloads.values
      .where((d) => d.status == DownloadStatus.paused)
      .toList();
}
