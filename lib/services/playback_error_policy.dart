import 'package:flutter/services.dart';

class PlaybackErrorPolicy {
  PlaybackErrorPolicy._();

  static bool isSourceError(Object error) {
    final text = error.toString().toLowerCase();

    if (error is PlatformException) {
      final message = error.message?.toLowerCase() ?? '';
      return error.code == '0' && message.contains('source error');
    }

    return text.contains('source error') || text.contains('type_source');
  }

  /// The audio-source index carried by just_audio's source error. The index is
  /// the one piece of state that survives ExoPlayer's automatic advance, so
  /// retries can go back to the file that actually failed instead of the next
  /// one.
  static int? sourceErrorIndex(Object error) {
    if (error is PlatformException) {
      final details = error.details;
      if (details is Map) {
        final index = details['index'];
        if (index is num) return index.toInt();
        final cause = details['cause'];
        if (cause is Map) {
          final causeIndex = cause['index'];
          if (causeIndex is num) return causeIndex.toInt();
        }
      }
    }
    final text = error.toString();
    for (final pattern in [
      RegExp(r'\{index:\s*(\d+)'),
      RegExp(r'"index"\s*:\s*(\d+)'),
      RegExp(r'index[=:]\s*(\d+)'),
    ]) {
      final match = pattern.firstMatch(text);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }

  /// The stream URL was rejected as unauthenticated. A rotated access token is
  /// the usual cause on long plays; this is not a dead session.
  static bool isAuthError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('response code: 401') ||
        text.contains('http 401') ||
        text.contains('unauthorized');
  }

  /// A byte range turned down: by the server with a 416, or by the disk
  /// cache in front of the Android player, which reports a bare
  /// DataSourceException with nothing after it when the position asked for
  /// is past the length it has on record for the URL.
  static bool isCacheRangeError(Object error) {
    final text = error.toString();
    return text.contains('Response code: 416') ||
        RegExp(r'Source error: DataSourceException(?![:\w])').hasMatch(text);
  }

  static bool shouldRetryWithTranscode(Object error) {
    final text = error.toString().toLowerCase();

    if (text.contains('mediacodecaudiorenderer') ||
        text.contains('audiotrack') ||
        text.contains('decoder') ||
        text.contains('format_supported')) {
      return true;
    }

    return isSourceError(error);
  }
}
