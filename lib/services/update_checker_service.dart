import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'inflight_temp_writes.dart';
import 'player_settings.dart';
import 'update_policy.dart';

class UpdateInfo {
  final String latestVersion;
  final String currentVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool isPreRelease;
  final bool isDirectApk;
  final String? packageLabel;

  UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.downloadUrl,
    this.releaseNotes = '',
    this.isPreRelease = false,
    this.isDirectApk = true,
    this.packageLabel,
  });

  bool get hasUpdate =>
      compareUpdateVersions(latestVersion, currentVersion) > 0;

  /// Which beta the release is, read from the "## Beta N" heading the release
  /// notes open with. Null for full releases or notes without that line.
  int? get latestBetaNumber => betaNumberFromReleaseNotes(releaseNotes);
}

/// Pulls N out of a "## Beta N" heading in GitHub release notes.
int? betaNumberFromReleaseNotes(String notes) {
  final m = RegExp(r'^#+\s*Beta\s+(\d+)\b', multiLine: true, caseSensitive: false)
      .firstMatch(notes);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Outcome of an update check, telling callers apart:
/// * [info] non-null — a newer version exists and can be offered;
/// * [error] non-null — the server couldn't be queried (network, HTTP error);
/// * both null — no newer version (or the check was skipped by cooldown/etc.).
class UpdateCheckResult {
  final UpdateInfo? info;
  final String? error;

  const UpdateCheckResult.update(this.info)
      : error = null;
  const UpdateCheckResult.failure(String this.error)
      : info = null;
  const UpdateCheckResult.none()
      : info = null,
        error = null;
}

class UpdateCheckerService {
  static const _repo = 'MayflyDestiny/absorb';
  static const _checkInterval = Duration(hours: 12);
  static const _dismissedKey = 'update_dismissed_version';
  static const _lastCheckKey = 'update_last_check';
  static const _updateChannel = MethodChannel('com.absorb.update');

  static Future<String> currentInstalledVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    int? baseBuildNumber;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        baseBuildNumber =
            await _updateChannel.invokeMethod<int>('getBaseBuildNumber');
      } catch (error) {
        debugPrint('[UpdateChecker] Base build lookup failed: $error');
      }
    }
    return currentUpdateVersion(
      versionName: packageInfo.version,
      packageBuildNumber: packageInfo.buildNumber,
      baseBuildNumber: baseBuildNumber,
    );
  }

  /// Check for updates. Returns an [UpdateCheckResult] telling the caller
  /// apart an update (info non-null) from "no update" (all null) from a
  /// failed check ([error] non-null).
  /// Respects a 12-hour cooldown between checks and skips dismissed versions.
  /// When [includePreReleases] is true, pre-release/alpha builds are also considered.
  static Future<UpdateCheckResult> check({bool force = false, bool includePreReleases = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Cooldown check (skip if forced)
      if (!force) {
        final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
        final elapsed = DateTime.now().millisecondsSinceEpoch - lastCheck;
        if (elapsed < _checkInterval.inMilliseconds) return const UpdateCheckResult.none();
      }

      await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

      Map<String, dynamic>? data;

      if (includePreReleases) {
        // Fetch all releases and pick the first (newest) one, which may be a pre-release
        final response = await http.get(
          Uri.parse('https://api.github.com/repos/$_repo/releases?per_page=5'),
          headers: {'Accept': 'application/vnd.github.v3+json'},
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          return UpdateCheckResult.failure('HTTP ${response.statusCode}');
        }
        final releases = jsonDecode(response.body) as List<dynamic>;
        if (releases.isEmpty) return const UpdateCheckResult.none();
        data = releases.first as Map<String, dynamic>;
      } else {
        final response = await http.get(
          Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
          headers: {'Accept': 'application/vnd.github.v3+json'},
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          return UpdateCheckResult.failure('HTTP ${response.statusCode}');
        }
        data = jsonDecode(response.body) as Map<String, dynamic>;
      }

      final tagName = data['tag_name'] as String? ?? '';
      final body = data['body'] as String? ?? '';
      final assets = data['assets'] as List<dynamic>? ?? [];
      final isPreRelease = data['prerelease'] as bool? ?? false;

      final releaseAssets = <UpdateReleaseAsset>[];
      for (final rawAsset in assets) {
        if (rawAsset is! Map<String, dynamic>) continue;
        final name = rawAsset['name'] as String? ?? '';
        final url = rawAsset['browser_download_url'] as String? ?? '';
        if (name.isNotEmpty && url.isNotEmpty) {
          releaseAssets.add(UpdateReleaseAsset(name: name, downloadUrl: url));
        }
      }

      List<String> supportedAbis = const [];
      if (!kIsWeb && Platform.isAndroid) {
        try {
          supportedAbis =
              (await DeviceInfoPlugin().androidInfo).supportedAbis;
        } catch (error) {
          debugPrint('[UpdateChecker] ABI detection failed: $error');
        }
      }
      final selectedAsset = selectAndroidUpdateAsset(
        assets: releaseAssets,
        supportedAbis: supportedAbis,
      );
      final currentVersion = await currentInstalledVersion();
      final rawDownloadUrl = selectedAsset?.downloadUrl ??
          data['html_url'] as String? ??
          '';
      final downloadUrl = await PlayerSettings.githubProxyFor(rawDownloadUrl);
      if (selectedAsset != null) {
        debugPrint(
          '[UpdateChecker] Selected ${selectedAsset.name} for '
          '${supportedAbis.join(', ')}',
        );
      }

      final info = UpdateInfo(
        latestVersion: tagName,
        currentVersion: currentVersion,
        downloadUrl: downloadUrl,
        releaseNotes: body,
        isPreRelease: isPreRelease,
        isDirectApk: selectedAsset != null,
        packageLabel: selectedAsset == null
            ? null
            : androidUpdatePackageLabel(selectedAsset),
      );

      if (!info.hasUpdate) return const UpdateCheckResult.none();

      // Check if user dismissed this version
      if (!force) {
        final dismissed = prefs.getString(_dismissedKey);
        if (dismissed == tagName) return const UpdateCheckResult.none();
      }

      return UpdateCheckResult.update(info);
    } on TimeoutException {
      debugPrint('[UpdateChecker] Timed out');
      return const UpdateCheckResult.failure('timeout');
    } on http.ClientException catch (e) {
      debugPrint('[UpdateChecker] Network error: $e');
      return UpdateCheckResult.failure(e.message);
    } on FormatException catch (e) {
      debugPrint('[UpdateChecker] Bad response: $e');
      return const UpdateCheckResult.failure('bad response');
    } catch (e) {
      debugPrint('[UpdateChecker] Error: $e');
      return UpdateCheckResult.failure('$e');
    }
  }

  /// Dismiss the update prompt for a specific version.
  static Future<void> dismiss(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedKey, version);
  }
}

enum ApkInstallStatus {
  ok,
  downloadFailed,
  permissionDenied,
  launchFailed,
  cancelled,
}

class ApkInstallResult {
  final ApkInstallStatus status;
  final String? message;
  const ApkInstallResult(this.status, [this.message]);
}

/// Downloads the APK in-app and hands it to the system installer.
///
/// Why: launching the URL in a browser leaves Chrome holding the APK in its
/// SafeBrowsing "scanning" limbo - the download bar hits 100% and never
/// finalises. Pulling the bytes ourselves and opening the file with
/// open_filex bypasses the browser entirely.
class ApkUpdater {
  static http.Client? _activeClient;

  static Future<ApkInstallResult> downloadAndInstall(
    UpdateInfo info, {
    required void Function(int received, int total) onProgress,
  }) async {
    if (!Platform.isAndroid) {
      return const ApkInstallResult(ApkInstallStatus.launchFailed, 'Android only');
    }

    final perm = await Permission.requestInstallPackages.request();
    if (!perm.isGranted) {
      return const ApkInstallResult(ApkInstallStatus.permissionDenied);
    }

    final File file;
    try {
      file = await _download(info, onProgress);
    } on _CancelledException {
      return const ApkInstallResult(ApkInstallStatus.cancelled);
    } catch (e) {
      debugPrint('[ApkUpdater] Download failed: $e');
      return ApkInstallResult(ApkInstallStatus.downloadFailed, e.toString());
    }

    final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      debugPrint('[ApkUpdater] OpenFilex failed: ${result.type} ${result.message}');
      return ApkInstallResult(ApkInstallStatus.launchFailed, result.message);
    }
    return const ApkInstallResult(ApkInstallStatus.ok);
  }

  /// Cancel an in-flight download started by [downloadAndInstall].
  static void cancel() {
    _activeClient?.close();
    _activeClient = null;
  }

  static const int _chunkSize = 8 * 1024 * 1024;
  static const int _maxConcurrentChunks = 4;
  static const int _maxChunks = 8;

  static Future<File> _download(
    UpdateInfo info,
    void Function(int, int) onProgress,
  ) async {
    final dir = await getTemporaryDirectory();
    final filename = Uri.parse(info.downloadUrl).pathSegments.last;
    final file = File('${dir.path}/$filename');
    if (await file.exists()) await file.delete();

    final client = http.Client();
    _activeClient = client;
    registerInFlightWrite(file.path);
    try {
      final total = await _probeTotal(client, info.downloadUrl);
      if (total != null && total > 0) {
        if (await _chunkedDownload(client, file, info.downloadUrl, total, onProgress)) {
          return file;
        }
      }
      await _singleStreamDownload(client, file, info.downloadUrl, onProgress);
      return file;
    } on _CancelledException {
      rethrow;
    } catch (e) {
      if (_activeClient != client) throw const _CancelledException();
      rethrow;
    } finally {
      unregisterInFlightWrite(file.path);
      if (_activeClient == client) _activeClient = null;
      client.close();
    }
  }

  static Future<int?> _probeTotal(http.Client client, String url) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Range'] = 'bytes=0-0';
      final response = await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 206) return null;
      await response.stream.drain<void>();
      final contentRange = response.headers['content-range'];
      if (contentRange == null) return null;
      final slash = contentRange.lastIndexOf('/');
      return int.tryParse(slash < 0 ? '' : contentRange.substring(slash + 1));
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static String _partPath(File file, int index) => '${file.path}.part$index';
  static String _chunkMetaPath(File file) => '${file.path}.part.meta';

  static Future<void> _clearParts(File file) async {
    final base = file.path;
    await for (final entry in file.parent.list()) {
      if (entry is File && entry.path.startsWith('$base.part')) {
        try {
          await entry.delete();
        } catch (_) {}
      }
    }
  }

  static Future<List<int>?> _readChunkMeta(File file, int total, int chunkCount) async {
    final meta = File(_chunkMetaPath(file));
    if (!await meta.exists()) return null;
    try {
      final saved = jsonDecode(await meta.readAsString());
      if (saved['total'] != total || saved['chunks'] != chunkCount) return null;
      final list = saved['progress'] as List<dynamic>?;
      if (list == null || list.length != chunkCount) return null;
      return list.map((e) => (e as num).toInt()).toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveChunkMeta(
    File file,
    int total,
    int chunkCount,
    List<int> progress,
  ) async {
    final meta = File(_chunkMetaPath(file));
    await meta.writeAsString(jsonEncode({
      'total': total,
      'chunks': chunkCount,
      'progress': progress,
    }));
  }

  static Future<bool> _chunkedDownload(
    http.Client client,
    File file,
    String url,
    int total,
    void Function(int, int) onProgress,
  ) async {
    final chunkCount = (total / _chunkSize).ceil().clamp(1, _maxChunks).toInt();
    final chunkSize = (total / chunkCount).ceil();
    final lastSize = total - (chunkCount - 1) * chunkSize;
    final sizes = List<int>.generate(
      chunkCount,
      (i) => i == chunkCount - 1 ? lastSize : chunkSize,
    );

    final savedProgress = await _readChunkMeta(file, total, chunkCount);
    if (savedProgress == null) {
      await _clearParts(file);
    }
    var progress = savedProgress ?? List<int>.filled(chunkCount, 0);

    for (var i = 0; i < chunkCount; i++) {
      final part = File(_partPath(file, i));
      if (progress[i] < sizes[i]) {
        progress[i] = 0;
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      } else {
        final ok = await part.exists() && await part.length() == sizes[i];
        if (!ok) {
          progress[i] = 0;
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
        }
      }
    }

    final remaining = <int>[
      for (var i = 0; i < chunkCount; i++)
        if (progress[i] < sizes[i]) i,
    ];

    var lastReport = DateTime.now();
    Future<void> reportProgress({required bool force}) async {
      if (!force && DateTime.now().difference(lastReport).inMilliseconds < 200) {
        return;
      }
      lastReport = DateTime.now();
      var sum = 0;
      for (var i = 0; i < chunkCount; i++) {
        sum += progress[i];
      }
      onProgress(sum.clamp(0, total), total);
    }

    Future<void> downloadChunk(int i) async {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1 ? total : (i + 1) * chunkSize) - 1;
      final part = File(_partPath(file, i));
      if (await part.exists()) await part.delete();
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Range'] = 'bytes=$start-$end';
      final response = await client.send(request).timeout(const Duration(seconds: 60));
      if (response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final sink = part.openWrite();
      try {
        await for (final chunk in response.stream) {
          if (_activeClient != client) {
            await sink.close();
            throw const _CancelledException();
          }
          sink.add(chunk);
          progress[i] += chunk.length;
          await reportProgress(force: false);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await part.length() != sizes[i]) {
        throw HttpException('Short chunk ${i + 1}/$chunkCount');
      }
      progress[i] = sizes[i];
      await _saveChunkMeta(file, total, chunkCount, progress);
      await reportProgress(force: true);
    }

    while (remaining.isNotEmpty) {
      final batch = remaining.take(_maxConcurrentChunks).toList();
      remaining.removeRange(0, batch.length);
      await Future.wait(batch.map(downloadChunk));
    }

    final merged = file.openWrite();
    try {
      for (var i = 0; i < chunkCount; i++) {
        merged.add(await File(_partPath(file, i)).readAsBytes());
      }
      await merged.flush();
    } finally {
      await merged.close();
    }
    await _clearParts(file);
    await reportProgress(force: true);
    return true;
  }

  static Future<void> _singleStreamDownload(
    http.Client client,
    File file,
    String url,
    void Function(int, int) onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        if (_activeClient != client) {
          await sink.close();
          throw const _CancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
}
