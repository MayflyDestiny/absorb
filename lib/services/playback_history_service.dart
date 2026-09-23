import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../l10n/app_localizations.dart';
import 'scoped_prefs.dart';

/// Types of playback events we track.
enum PlaybackEventType {
  play,
  pause,
  seek,
  syncLocal,
  syncServer,
  autoRewind,
  skipForward,
  skipBackward,
  speedChange,
  bookFinished,
  sessionStart,
  sessionEnd,
  clickDebounce,
}

/// Events that only show in the sheet when the user enables advanced mode.
const Set<PlaybackEventType> kAdvancedHistoryEvents = {
  PlaybackEventType.syncLocal,
  PlaybackEventType.syncServer,
  PlaybackEventType.sessionStart,
  PlaybackEventType.sessionEnd,
  PlaybackEventType.clickDebounce,
};

/// A single playback event entry.
class PlaybackEvent {
  final PlaybackEventType type;
  final double positionSeconds;
  final DateTime timestamp;
  final String? detail;

  PlaybackEvent({
    required this.type,
    required this.positionSeconds,
    required this.timestamp,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'pos': positionSeconds,
        'ts': timestamp.millisecondsSinceEpoch,
        if (detail != null) 'detail': detail,
      };

  factory PlaybackEvent.fromJson(Map<String, dynamic> json) {
    return PlaybackEvent(
      type: PlaybackEventType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => PlaybackEventType.play,
      ),
      positionSeconds: (json['pos'] as num).toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int),
      detail: json['detail'] as String?,
    );
  }

  String get label {
    switch (type) {
      case PlaybackEventType.play:
        if (detail != null && detail!.isNotEmpty) return detail!;
        return 'Resumed playback';
      case PlaybackEventType.pause:
        if (detail != null && detail!.isNotEmpty) return detail!;
        return 'Paused';
      case PlaybackEventType.seek:
        if (detail != null && detail!.isNotEmpty) return 'Seeked $detail';
        return 'Seeked';
      case PlaybackEventType.syncLocal:
        return 'Saved locally';
      case PlaybackEventType.syncServer:
        return 'Synced to server';
      case PlaybackEventType.autoRewind:
        if (detail != null && detail!.isNotEmpty) return 'Auto-rewound $detail';
        return 'Auto-rewound';
      case PlaybackEventType.skipForward:
        if (detail != null && detail!.isNotEmpty) return 'Skipped forward (${detail!})';
        return 'Skipped forward';
      case PlaybackEventType.skipBackward:
        if (detail != null && detail!.isNotEmpty) return 'Skipped back (${detail!})';
        return 'Skipped back';
      case PlaybackEventType.speedChange:
        if (detail != null && detail!.isNotEmpty) return 'Speed set to ${detail!}';
        return 'Speed changed';
      case PlaybackEventType.bookFinished:
        return 'Book finished';
      case PlaybackEventType.sessionStart:
        if (detail != null && detail!.isNotEmpty) return 'Session started ($detail)';
        return 'Session started';
      case PlaybackEventType.sessionEnd:
        if (detail != null && detail!.isNotEmpty) return 'Session ended ($detail)';
        return 'Session ended';
      case PlaybackEventType.clickDebounce:
        if (detail != null && detail!.isNotEmpty) return 'Media button: $detail';
        return 'Media button';
    }
  }

  String localizedLabel(AppLocalizations l) {
    switch (type) {
      case PlaybackEventType.play:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventResumedDetail(_localizePlayDetail(l, detail!));
        }
        return l.historyEventResumed;
      case PlaybackEventType.pause:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventPausedDetail(_localizePauseDetail(l, detail!));
        }
        return l.historyEventPaused;
      case PlaybackEventType.seek:
        if (detail != null && detail!.isNotEmpty) {
          return _localizeSeekDetail(l, detail!);
        }
        return l.historyEventSeeked;
      case PlaybackEventType.syncLocal:
        return l.historyEventSyncLocal;
      case PlaybackEventType.syncServer:
        return l.historyEventSyncServer;
      case PlaybackEventType.autoRewind:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventAutoRewoundDetail(
              _localizeRewindDetail(l, detail!));
        }
        return l.historyEventAutoRewound;
      case PlaybackEventType.skipForward:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventSkipForwardDetail(
              _localizeSkipDetail(l, detail!, forward: true));
        }
        return l.historyEventSkipForward;
      case PlaybackEventType.skipBackward:
        if (detail != null && detail!.isNotEmpty) {
          if (detail == 'snap to chapter start') {
            return l.historyDetailSnapToChapterStart;
          }
          return l.historyEventSkipBackDetail(
              _localizeSkipDetail(l, detail!, forward: false));
        }
        return l.historyEventSkipBack;
      case PlaybackEventType.speedChange:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventSpeedSetTo(_localizedSpeed(l, detail!));
        }
        return l.historyEventSpeedChanged;
      case PlaybackEventType.bookFinished:
        return l.historyEventBookFinished;
      case PlaybackEventType.sessionStart:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventSessionStartedDetail(
              _localizeSessionDetail(l, detail!));
        }
        return l.historyEventSessionStarted;
      case PlaybackEventType.sessionEnd:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventSessionEndedDetail(
              _localizeSessionDetail(l, detail!));
        }
        return l.historyEventSessionEnded;
      case PlaybackEventType.clickDebounce:
        if (detail != null && detail!.isNotEmpty) {
          return l.historyEventMediaButtonDetail(detail!);
        }
        return l.historyEventMediaButton;
    }
  }

  static String _localizedDuration(AppLocalizations l, String raw) {
    if (raw.endsWith('m')) {
      return l.historyMinutes(raw.substring(0, raw.length - 1));
    }
    if (raw.endsWith('s')) {
      return l.historySeconds(raw.substring(0, raw.length - 1));
    }
    return raw;
  }

  static String _localizedSpeed(AppLocalizations l, String raw) {
    if (raw.endsWith('x')) {
      return l.historySpeed(raw.substring(0, raw.length - 1));
    }
    return raw;
  }

  static String _localizePlayDetail(AppLocalizations l, String d) {
    if (d == 'Switched to local playback') return l.historyDetailSwitchedToLocal;
    if (d == 'Auto-resumed after interruption') {
      return l.historyDetailPlayAutoResumedInterruption;
    }
    if (d == 'page key') return l.historyDetailPlayPageKey;
    if (d == 'read along stopped') return l.historyDetailPlayReadAlongStopped;
    if (d == 'read along ready') return l.historyDetailPlayReadAlongReady;
    return d;
  }

  static String _localizePauseDetail(AppLocalizations l, String d) {
    if (d == 'offline') return l.historyDetailPauseOffline;
    if (d == 'Spurious completion blocked') {
      return l.historyDetailPauseSpuriousBlocked;
    }
    if (d == 'iOS premature completion blocked') {
      return l.historyDetailPauseIosPrematureBlocked;
    }
    return d;
  }

  static String _localizeSessionDetail(AppLocalizations l, String d) {
    if (d == 'stream') return l.historyDetailStream;
    if (d == 'stream hot-swap') return l.historyDetailStreamHotSwap;
    if (d == 'local hot-swap') return l.historyDetailLocalHotSwap;
    if (d == 'local-session') return l.historyDetailLocalSession;
    if (d == 'refresh') return l.historyDetailRefresh;
    if (d == 'recovery') return l.historyDetailRecovery;
    if (d == 'stall recovery') return l.historyDetailStallRecovery;
    if (d == 'dead source') return l.historyDetailDeadSource;
    if (d == 'direct-file') return l.historyDetailDirectFile;
    if (d == 'book finished') return l.historyDetailBookFinished;
    if (d == 'local book finished') return l.historyDetailLocalBookFinished;
    if (d == 'pause timeout') return l.historyDetailPauseTimeout;
    if (d == 'stop') return l.historyDetailStop;
    return d;
  }

  static String _localizeSeekDetail(AppLocalizations l, String detail) {
    if (detail == 'next chapter') return l.historyDetailNextChapter;
    if (detail == 'prev chapter') return l.historyDetailPrevChapter;
    if (detail == 'next chapter to end') return l.historyDetailNextChapterToEnd;
    if (detail == 'skip chapter intro') return l.historyDetailSkipChapterIntro;
    if (detail == 'skip chapter outro') return l.historyDetailSkipChapterOutro;
    if (detail == 'skip to end') return l.historyDetailSkipToEnd;
    if (detail == 'sleep rewind undone') {
      return l.historyDetailSeekSleepRewindUndone;
    }
    if (detail == 'prev chapter (direct)') {
      return l.historyDetailPrevChapterDirect;
    }
    final m = RegExp(r'^(next|prev) chapter to ([\d.]+)s \(intro skip\)$')
        .firstMatch(detail);
    if (m != null) {
      final position = _localizedDuration(l, '${m.group(2)}s');
      if (m.group(1) == 'next') {
        return l.historyDetailNextChapterToIntroSkip(position);
      }
      return l.historyDetailPrevChapterToIntroSkip(position);
    }
    final directM = RegExp(
      r'^prev chapter \(direct\) to ([\d.]+)s \(intro skip\)$',
    ).firstMatch(detail);
    if (directM != null) {
      return l.historyDetailPrevChapterDirectToIntroSkip(
        _localizedDuration(l, '${directM.group(1)}s'),
      );
    }
    return l.historyEventSeekedDetail(detail);
  }

  static String _localizeRewindDetail(AppLocalizations l, String detail) {
    final m = RegExp(r'^([\d.]+[sm])\s*(?:\((.+)\))?$').firstMatch(detail);
    if (m == null) return detail;
    final base = _localizedDuration(l, m.group(1)!);
    final paren = m.group(2);
    if (paren == null) return base;
    if (paren.contains('sleep timer')) {
      return l.historyDetailRewindSleepTimer(base);
    }
    final speedM = RegExp(r'^([\d.]+)s at ([\d.]+)x').firstMatch(paren);
    final session = paren.contains('session start');
    if (speedM != null) {
      final adjusted = _localizedDuration(l, '${speedM.group(1)}s');
      final speed = _localizedSpeed(l, speedM.group(2)!);
      if (session) {
        return l.historyDetailRewindSessionStartAtSpeed(base, adjusted, speed);
      }
      return l.historyDetailRewindAtSpeed(base, adjusted, speed);
    }
    if (session) return l.historyDetailRewindSessionStart(base);
    return detail;
  }

  static String _localizeSkipDetail(
    AppLocalizations l,
    String detail, {
    required bool forward,
  }) {
    final m =
        RegExp(r'^[+-](\d+)s \(([\d.]+)s @ ([\d.]+)x\)$').firstMatch(detail);
    if (m == null) return detail;
    final seconds = _localizedDuration(l, '${m.group(1)}s');
    final adjusted = _localizedDuration(l, '${m.group(2)}s');
    final speed = _localizedSpeed(l, m.group(3)!);
    return forward
        ? l.historyDetailSkipForwardAtSpeed(seconds, adjusted, speed)
        : l.historyDetailSkipBackwardAtSpeed(seconds, adjusted, speed);
  }

  String get icon {
    switch (type) {
      case PlaybackEventType.play:
        return '▶';
      case PlaybackEventType.pause:
        return '⏸';
      case PlaybackEventType.seek:
        return '⏩';
      case PlaybackEventType.syncLocal:
        return '💾';
      case PlaybackEventType.syncServer:
        return '☁';
      case PlaybackEventType.autoRewind:
        return '⏪';
      case PlaybackEventType.skipForward:
        return '⏭';
      case PlaybackEventType.skipBackward:
        return '⏮';
      case PlaybackEventType.speedChange:
        return '⚡';
      case PlaybackEventType.bookFinished:
        return '🏁';
      case PlaybackEventType.sessionStart:
        return '🟢';
      case PlaybackEventType.sessionEnd:
        return '🔴';
      case PlaybackEventType.clickDebounce:
        return '🖲';
    }
  }
}

/// Stores per-book playback history in SharedPreferences.
class PlaybackHistoryService {
  static final PlaybackHistoryService _instance = PlaybackHistoryService._();
  factory PlaybackHistoryService() => _instance;
  PlaybackHistoryService._();

  static const int _maxEventsPerBook = 1000;

  /// Log an event for a book.
  Future<void> log({
    required String itemId,
    required PlaybackEventType type,
    required double positionSeconds,
    String? detail,
  }) async {
    final event = PlaybackEvent(
      type: type,
      positionSeconds: positionSeconds,
      timestamp: DateTime.now(),
      detail: detail,
    );

    final key = 'playback_history_$itemId';
    final existing = await ScopedPrefs.getStringList(key);

    existing.add(jsonEncode(event.toJson()));

    // Trim to max size (keep most recent)
    if (existing.length > _maxEventsPerBook) {
      existing.removeRange(0, existing.length - _maxEventsPerBook);
    }

    await ScopedPrefs.setStringList(key, existing);
  }

  /// Get all events for a book, newest first.
  Future<List<PlaybackEvent>> getHistory(String itemId) async {
    final key = 'playback_history_$itemId';
    final stored = await ScopedPrefs.getStringList(key);

    final events = <PlaybackEvent>[];
    for (final json in stored) {
      try {
        events.add(PlaybackEvent.fromJson(jsonDecode(json)));
      } catch (e) {
        debugPrint('[History] Failed to parse event: $e');
      }
    }

    return events.reversed.toList(); // newest first
  }

  /// Clear history for a book.
  Future<void> clearHistory(String itemId) async {
    await ScopedPrefs.remove('playback_history_$itemId');
  }
}
