import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../build_info.dart';
import 'api_service.dart';

class LogService {
  static final LogService _instance = LogService._();
  factory LogService() => _instance;
  LogService._();

  static const supportEmail = 'absorb@barnabashq.com';

  // Keep 1MB max, trim to 512KB.
  static const _maxSize = 1 * 1024 * 1024; // 1 MB
  static const _keepSize = 512 * 1024; // 512 KB
  static const _rotateCheckInterval = 500; // check every N writes
  static const _createdAtKey = 'log_created_at';

  // Compiled once: every logged line runs these, and building a RegExp per
  // call is pure overhead on the hottest path in the app.
  static final _reUrl = RegExp(r'(?:https?|wss?)://[^\s\]"]+');
  static final _reBearer = RegExp(r'Bearer [A-Za-z0-9_\-.]{12,}', caseSensitive: false);
  // Bare key=value credentials outside URLs. Explicit credential names only, so
  // non-secret keys like cacheKey/storageKey stay readable for debugging.
  static final _reKeyValue = RegExp(
      r'((?:access|refresh|id|auth)[_-]?token|code[_-]?verifier|client[_-]?secret|api[_-]?key|secret[_-]?key|token|secret|password|passwd|authorization|bearer|session[_-]?id|cookie)\s*[=:]\s*(?!null\b|\*\*\*|true\b|false\b)\S+',
      caseSensitive: false);
  static final _reJwt = RegExp(r'(?:(?<=Bearer\s)|\b)([A-Za-z0-9_-]{6,})\.([A-Za-z0-9_-]{6,})\.([A-Za-z0-9_-]{8,})');
  // Whole Cookie / Set-Cookie header lines: the value (session/refresh token) is
  // the secret, the name alone is not, so redact the whole line.
  static final _reCookie = RegExp(r'(?:Set-Cookie|Cookie)\s*:\s*[^\n\r]+', caseSensitive: false);
  // JSON string fields carrying tokens/secrets, e.g. `"accessToken":"..."` in a
  // logged response body. Keeps the field name, masks only the value.
  static final _reJsonSecret = RegExp(
      r'"((?:accessToken|refreshToken|idToken|access_token|refresh_token|id_token|token|secret|password|apiKey|api_key))"\s*:\s*"[^"]*"',
      caseSensitive: false);
  static final _reLocalPath = RegExp(r'(?<![A-Za-z0-9])(?:/data|/storage|/home|/var|/private|/Users|[A-Za-z]:)(?:[/\\][^,\s\]\)"<>]+)+');

  File? _logFile;
  bool _enabled = false;
  DebugPrintCallback? _originalDebugPrint;
  int _writeCount = 0;

  bool get enabled => _enabled;

  /// Call once at startup. Always overrides [debugPrint] so every line reaching
  /// logcat is sanitized (no debug/release filtering). If [loggingEnabled] is
  /// true it additionally captures all sanitized output to a rotating log file
  /// for sharing.
  Future<void> init(bool loggingEnabled) async {
    // Override debugPrint globally no matter what: it must run before any
    // other service logs, so URLs/tokens are sanitized before reaching logcat.
    //
    // Idempotence guard: re-entering here would capture our own interceptor as
    // [_originalDebugPrint] and every later log line would recurse until the
    // stack blew.
    if (!identical(debugPrint, _interceptedDebugPrint)) {
      _originalDebugPrint = debugPrint;
      debugPrint = _interceptedDebugPrint;
    }

    _enabled = loggingEnabled;
    if (!_enabled) return;

    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/absorb_logs.txt');

    // Auto-clear if log is older than 24 hours.
    // Track creation time via a sidecar file since lastModified updates
    // on every write and can't be used for age checks.
    final createdAtFile = File('${dir.path}/$_createdAtKey');
    bool shouldClear = false;
    if (_logFile!.existsSync() && createdAtFile.existsSync()) {
      try {
        final createdMs = int.tryParse(createdAtFile.readAsStringSync().trim());
        if (createdMs != null) {
          final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(createdMs));
          if (age.inHours >= 24) shouldClear = true;
        }
      } catch (_) {
        shouldClear = true;
      }
    }

    if (shouldClear || !_logFile!.existsSync() || !createdAtFile.existsSync()) {
      // Start fresh - write device/server info header
      final header = StringBuffer()
        ..writeln('=== Absorb Log ===')
        ..writeln('App Version: ${versionWithBeta(ApiService.appVersionFull)}')
        ..writeln('Device: ${ApiService.deviceManufacturer} ${ApiService.deviceModel}')
        ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('Created: ${DateTime.now().toIso8601String()}')
        ..writeln('==================')
        ..writeln();
      await _logFile!.writeAsString(header.toString());
      createdAtFile.writeAsStringSync(DateTime.now().millisecondsSinceEpoch.toString());
    }

    // Rotate on startup if needed
    await _rotateIfNeeded();

    // Session header - stamps the app version here too, since the file
    // header above only gets rewritten on clear/24h rollover and can go
    // stale across an app update in between.
    final now = DateTime.now().toIso8601String();
    await _logFile!.writeAsString(
      '\n=== Session started $now (App Version: ${versionWithBeta(ApiService.appVersionFull)}) ===\n',
      mode: FileMode.append,
    );
  }

  void _interceptedDebugPrint(String? message, {int? wrapWidth}) {
    // Forward every line in full (no debug/release filtering); sanitize once
    // before it reaches logcat so raw URLs/tokens never leak. When a log file
    // is active, the same sanitized copy is appended to it.
    final sanitized = message == null ? null : _sanitize(message);
    _originalDebugPrint?.call(sanitized, wrapWidth: wrapWidth);
    if (_logFile != null && message != null) {
      final ts = DateTime.now().toIso8601String();
      _logFile!.writeAsStringSync(
        '[$ts] $sanitized\n',
        mode: FileMode.append,
      );
      _maybeRotate();
    }
  }

  /// Write a log entry directly (for error handlers that bypass debugPrint).
  void log(String message) {
    if (_logFile != null) {
      final ts = DateTime.now().toIso8601String();
      final sanitized = _sanitize(message);
      _logFile!.writeAsStringSync(
        '[$ts] $sanitized\n',
        mode: FileMode.append,
      );
      _maybeRotate();
    }
  }

  /// Write an uncaught exception to a dedicated crash file. Works even when
  /// the regular log capture is disabled - crash dumps must always land so
  /// post-mortem diagnosis is possible.
  Future<void> logCrash(Object error, StackTrace stack, {String context = ''}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/absorb_crash.log');
      final ts = DateTime.now().toIso8601String();
      final buf = StringBuffer()
        ..writeln('========================================')
        ..writeln('[$ts] CRASH${context.isNotEmpty ? " ($context)" : ""}')
        ..writeln('App: ${versionWithBeta(ApiService.appVersionFull)}')
        ..writeln('Error: $error')
        ..writeln('--- Stack ---')
        ..writeln(stack.toString())
        ..writeln();
      await f.writeAsString(buf.toString(), mode: FileMode.append);
    } catch (_) {
      // Last-resort logging must never throw.
    }
  }

  /// Read the most recent crash dump (if any) and clear it. Returns null when
  /// no crash was recorded since the last read.
  Future<String?> consumeLastCrash() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/absorb_crash.log');
      if (!await f.exists()) return null;
      final content = await f.readAsString();
      await f.delete();
      return content.trim().isEmpty ? null : content;
    } catch (_) {
      return null;
    }
  }

  /// Periodic runtime rotation - check file size every [_rotateCheckInterval]
  /// writes so the log never grows much past [_maxSize] even during long
  /// sessions. This keeps the most recent entries and trims the oldest.
  void _maybeRotate() {
    _writeCount++;
    if (_writeCount < _rotateCheckInterval) return;
    _writeCount = 0;
    // Run async rotation in the background - don't block the write path.
    // Writes between the check and the trim are fine; they just append
    // and the next rotation pass will catch them.
    _rotateIfNeeded();
  }

  /// If the log file exceeds [_maxSize], keep only the last [_keepSize] bytes.
  /// Trims at a newline boundary so partial lines aren't left at the top.
  Future<void> _rotateIfNeeded() async {
    try {
      if (_logFile == null || !await _logFile!.exists()) return;
      final size = await _logFile!.length();
      if (size <= _maxSize) return;

      final contents = await _logFile!.readAsString();
      final trimStart = contents.length - _keepSize;
      // Find the next newline after the trim point so we don't start
      // mid-line, which makes logs confusing to read.
      var cutAt = contents.indexOf('\n', trimStart);
      if (cutAt < 0) cutAt = trimStart;
      await _logFile!.writeAsString(contents.substring(cutAt + 1));
    } catch (_) {
      // Don't let rotation errors break logging
    }
  }

  Future<void> clearLogs() async {
    if (_logFile != null && await _logFile!.exists()) {
      // Write a fresh header immediately so logs shared in the same session
      // still have device info (don't wait for next init/restart).
      final header = StringBuffer()
        ..writeln('=== Absorb Log ===')
        ..writeln('App Version: ${versionWithBeta(ApiService.appVersionFull)}')
        ..writeln('Device: ${ApiService.deviceManufacturer} ${ApiService.deviceModel}')
        ..writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
        ..writeln('Created: ${DateTime.now().toIso8601String()}')
        ..writeln('==================')
        ..writeln();
      await _logFile!.writeAsString(header.toString());
      // Reset creation timestamp
      try {
        final dir = _logFile!.parent;
        final createdAtFile = File('${dir.path}/$_createdAtKey');
        createdAtFile.writeAsStringSync(
            DateTime.now().millisecondsSinceEpoch.toString());
      } catch (_) {}
    }
  }

  /// Build device info string used by both email methods.
  String _deviceInfo({String? serverVersion}) {
    final buf = StringBuffer()
      ..writeln('App Version: ${versionWithBeta(ApiService.appVersionFull)}')
      ..writeln('Device: ${ApiService.deviceManufacturer} ${ApiService.deviceModel}')
      ..writeln('Device ID: ${ApiService.deviceId}');
    if (serverVersion != null) {
      buf.writeln('Server Version: $serverVersion');
    }
    buf.writeln('Timestamp: ${DateTime.now().toIso8601String()}');
    return buf.toString();
  }

  /// Params whose values should be masked in logged URLs.
  static final _sensitiveParamPattern = RegExp(
    r'token|code|code_verifier|secret|client_secret|password|key|verifier|challenge|state|cookie|auth|bearer|nonce|refresh_token|access_token|id_token',
    caseSensitive: false,
  );

  /// Sanitize a single log message: mask URLs, sensitive query params,
  /// tokens (JWT / header / ref, incl. "Bearer xxx"), and bare key=value
  /// pairs that look like credentials.
  static String _sanitize(String message) {
    // Whole Cookie / Set-Cookie lines first, before URL/key scans, so the
    // session/refresh value inside is removed regardless of its format.
    var result = message.replaceAllMapped(_reCookie, (_) => '[cookie-redacted]');
    result = _sanitizeUrls(result);
    // JSON token fields in a logged response body.
    result = result.replaceAllMapped(_reJsonSecret, (m) => '"${m.group(1)}":"***"');
    // Standalone key=value credentials outside a URL, e.g. "token=abc123".
    result = result.replaceAllMapped(_reKeyValue, (m) => '${m.group(1)}=***');
    // Opaque tokens in prose: three dot-separated base64url segments, plus
    // "Bearer xxx".
    result = result.replaceAllMapped(_reJwt, (_) => '[token-redacted]');
    result = result.replaceAllMapped(_reBearer, (_) => '[bearer-redacted]');
    // Absolute local paths, keeping the basename for debuggability. Anchored
    // so an `http://` host's `p:` can't be mistaken for a drive.
    return result.replaceAllMapped(_reLocalPath, (m) {
      // Basename without split(): the pattern guarantees a separator, so
      // scanning back avoids allocating every segment just to keep the tail.
      final p = m.group(0)!;
      final fwd = p.lastIndexOf('/');
      final cut = fwd > p.lastIndexOf('\\') ? fwd : p.lastIndexOf('\\');
      return '[local-path ${p.substring(cut + 1)}]';
    });
  }

  /// Sanitize URLs in log content, replacing server hosts with a connection
  /// type label (e.g. [local-ip], [tailscale], [reverse-proxy]) while keeping
  /// API paths intact for debugging.
  static String _sanitizeUrls(String content) {
    // Collect unique hostnames found in URLs so we can scrub bare references too
    final foundHosts = <String>{};

    var result = content.replaceAllMapped(_reUrl, (match) {
      final url = match.group(0)!;
      try {
        final uri = Uri.parse(url);
        final host = uri.host.toLowerCase();
        foundHosts.add(host);
        String label;
        if (host == 'localhost' || host == '127.0.0.1') {
          label = '[localhost]';
        } else if (host.endsWith('.ts.net')) {
          label = '[tailscale]';
        } else if (_isPrivateIp(host)) {
          label = '[local-ip]';
        } else if (uri.scheme == 'https' || uri.scheme == 'wss') {
          label = '[reverse-proxy]';
        } else {
          label = '[remote-http]';
        }
        final path = uri.path.isNotEmpty ? uri.path : '';
        final query = _maskQuery(uri);
        return '$label$path$query';
      } catch (_) {
        return '[url-redacted]';
      }
    });

    // Scrub bare hostnames that leak in error messages (e.g. SocketException
    // includes "address = hostname.com, port = 1234")
    for (final host in foundHosts) {
      if (host == 'localhost' || host == '127.0.0.1') continue;
      result = result.replaceAll(host, '[host-redacted]');
    }
    return result;
  }

  /// Keep query param names but mask values of sensitive ones.
  static String _maskQuery(Uri uri) {
    if (uri.queryParameters.isEmpty) return '';
    final masked = uri.queryParameters.entries.map((e) {
      if (_sensitiveParamPattern.hasMatch(e.key)) {
        return '${e.key}=***';
      }
      return '${e.key}=${e.value}';
    }).join('&');
    return '?$masked';
  }

  static bool _isPrivateIp(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
  }

  /// Share log file as attachment via share sheet with device info.
  ///
  /// [sharePositionOrigin] is required on iPad for the share popover anchor.
  Future<void> shareLogs({String? serverVersion, Rect? sharePositionOrigin}) async {
    final info = _deviceInfo(serverVersion: serverVersion);

    final hasFile =
        _logFile != null && await _logFile!.exists() && await _logFile!.length() > 0;

    if (hasFile) {
      // Write sanitized copy to share instead of raw logs. Run the full
      // sanitizer (URLs, query params, Bearer/JWT, key=value, local paths),
      // not just URL scrubbing, so no credential leaks into the shared file.
      final raw = await _logFile!.readAsString();
      final sanitized = _sanitize(raw);
      final dir = _logFile!.parent;
      final sanitizedFile = File('${dir.path}/absorb_logs_share.txt');
      await sanitizedFile.writeAsString(sanitized);

      await Share.shareXFiles(
        [XFile(sanitizedFile.path)],
        subject: 'Absorb Log Report',
        text: 'Send to: $supportEmail\n\n$info',
        sharePositionOrigin: sharePositionOrigin,
      );
    } else {
      await Share.share(
        'Send to: $supportEmail\n\n$info\n(No log file found — is logging enabled?)',
        subject: 'Absorb Log Report',
        sharePositionOrigin: sharePositionOrigin,
      );
    }
  }

  /// Open a mailto: link with device info (no logs) for general contact.
  Future<void> contactEmail({String? serverVersion}) async {
    final info = _deviceInfo(serverVersion: serverVersion);
    final uri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: _encodeMailtoQuery({
        'subject': 'Absorb Feedback',
        'body': info,
      }),
    );
    await launchUrl(uri);
  }

  String _encodeMailtoQuery(Map<String, String> params) {
    return params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }
}
