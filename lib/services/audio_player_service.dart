import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '_audio_player.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'book_track_resolver.dart';
import 'download_service.dart';
import 'narrated_books.dart';
import 'narration_stream.dart';
import 'offline_source.dart';
import 'playback_history_service.dart' hide PlaybackEvent;
import 'progress_sync_service.dart';
import 'local_session_service.dart';
import 'sync_logic.dart';
import 'transcription_service.dart';
import 'sleep_timer_service.dart';
import 'equalizer_service.dart';
import 'external_audio_output_types.dart';
import 'android_auto_service.dart';
import 'chromecast_service.dart';
import 'chapter_cache.dart';
import 'chapter_lookup.dart';
import 'playback_manifest.dart';
import 'playback_quiet_gate.dart';
import 'now_playing_layout.dart';
import 'cold_start_play_policy.dart';
import 'playback_error_policy.dart';
import 'player_settings.dart';
import 'session_cache.dart';
import 'home_widget_service.dart';
import 'bookmark_service.dart';
import 'review_service.dart';
import 'book_finish_reminder.dart';
import '../utils/episode_key.dart';
import '../utils/duration_format.dart';
import '../utils/app_platform.dart';
import '../l10n/app_localizations.dart';
import '../main.dart' show rootNavigatorKey;
import '../widgets/overlay_toast.dart' show showNavigatorOverlayToast;
export 'player_settings.dart';

String playbackDownloadKey(String itemId, String? episodeId) =>
    episodeKeyFor(itemId, episodeId);

// ─── AudioHandler (runs in background, controls notification) ───

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayer _player = AudioPlayer(
    handleInterruptions: false,
    // Bypass the local HTTP proxy — headers are sent natively on both
    // platforms (ExoPlayer via setDefaultRequestProperties, AVPlayer via
    // AVURLAssetHTTPHeaderFieldsKey). The proxy doubles the packet count.
    useProxyForRequestHeaders: false,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Start playing after only 1s of buffered audio: playback bitrate is
        // a fraction of typical link throughput, so this shaves the startup
        // and post-seek wait without meaningfully raising rebuffer risk
        // (rebuffer recovery keeps its own, larger 5s threshold).
        bufferForPlaybackDuration: Duration(seconds: 1),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
        // Read-ahead is the app's largest data cost: the player fills to the
        // maximum even while paused (measured ~7 MB per start/seek and 2.6 MB
        // per pause at 50s). 40s forward (4 MB ceiling) trims that while
        // keeping enough cushion for a weak mobile link; rewind stays instant
        // because the 2-minute back buffer below is separate.
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 40),
        targetBufferBytes: 4 * 1024 * 1024,
        // Keep played audio buffered: a backward seek inside the current
        // file (rewind button, chapter-start snap) then lands INSTANTLY on
        // already-buffered samples instead of re-fetching the byte range
        // over the network ("rewind stalls a few seconds pulling data").
        // ~2 minutes of audio is 2-4 MB of samples.
        backBufferDuration: Duration(minutes: 2),
      ),
      // iOS: disable AVPlayer's "wait for sustained playback guarantee" mode.
      // Default true makes AVPlayer set _player.rate = speed and only actually
      // start playing once iOS thinks stalls are unlikely. In foreground this
      // resolves instantly; in background after a fresh asset load, iOS never
      // grants that guarantee, so the new track stays state=buffering at
      // pos=0.0 forever even with hundreds of seconds buffered (GH #244).
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
      ),
    ),
  );
  AudioPlayerService? _service; // back-reference for auto-rewind

  // Cached skip amounts for notification icon selection (updated when settings change)
  int _cachedForwardSkip = 30;
  int _cachedBackSkip = 10;
  // Android: which pair fills the phone media player's two extra slots - speed +
  // bookmark (true) or chapter skip (false). Android Auto shows all of them
  // regardless. See PlayerSettings.getMediaControlsSpeedBookmark.
  bool _cachedNotifSpeedBookmark = false;
  // When true, the system scrubber is non-draggable (seek action dropped from
  // the playback state). See PlayerSettings.getLockSeekBar.
  bool _cachedLockSeekBar = false;

  AudioPlayer get player => _player;

  void bindService(AudioPlayerService service) => _service = service;

  // [AbsorbDiag] Channel for phantom-resume diagnostics (GH #243). Reads
  // statics from the vendored audio_service Java side via MainActivity.kt.
  // Strip the call sites + the channel once #243 is closed.
  static const _absorbDiagChannel = MethodChannel('com.absorb.audio_diag');
  static const _nativeHandlerChannel = MethodChannel(
    'com.ryanheise.audio_service.handler.methods',
  );
  static bool _diagMissingLogged = false;

  /// Fetch the raw diag snapshot from the Java side. Returns null on iOS or
  /// when the channel is unavailable. Used by click() to also read the
  /// keycode for intent disambiguation, not just to log it.
  static Future<Map<String, dynamic>?> _absorbDiagSnapshot() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _absorbDiagChannel.invokeMapMethod<String, dynamic>(
        'snapshot',
      );
    } on MissingPluginException {
      if (!_diagMissingLogged) {
        _diagMissingLogged = true;
        debugPrint('[AbsorbDiag] snapshot channel missing on this engine');
      }
      return null;
    } catch (e) {
      debugPrint('[AbsorbDiag] snapshot failed: $e');
      return null;
    }
  }

  /// Output devices arrive comma-separated from the Java side and often repeat
  /// the same headset several times; keep the line readable in exported logs.
  static String _compactOutputs(Object? raw, {int max = 4}) {
    final s = raw?.toString() ?? '';
    if (s.isEmpty || s == 'none' || s == 'n/a') return s;
    final seen = <String>{};
    final unique = <String>[];
    for (final part in s.split(',')) {
      final t = part.trim();
      if (t.isEmpty || !seen.add(t)) continue;
      unique.add(t);
    }
    final shown = unique.take(max).join(',');
    final rest = unique.length - max;
    return rest > 0 ? '$shown,+$rest' : shown;
  }

  static void _logAbsorbDiagFromSnapshot(
    String tag,
    Map<String, dynamic>? snap,
  ) {
    if (snap == null) return;
    debugPrint(
      '[AbsorbDiag] $tag: '
      'keyCode=${snap['lastKeyCode']} keyAgeMs=${snap['lastKeyAgeMs']} '
      'lastPlayCaller=${snap['lastPlayCaller']} playAgeMs=${snap['lastPlayCallerAgeMs']} '
      'lastPauseCaller=${snap['lastPauseCaller']} pauseAgeMs=${snap['lastPauseCallerAgeMs']} '
      'carClientAgeMs=${snap['carClientAgeMs']} keyPkg=${snap['lastKeyPkg']} '
      'route=[${snap['route']}] outputs=[${_compactOutputs(snap['outputs'])}]',
    );
  }

  static bool _isCarPackage(String? pkg) =>
      pkg != null &&
      (pkg == 'com.google.android.projection.gearhead' ||
          pkg.startsWith('com.android.car'));

  /// Our own widget sends its play button through the media session like a
  /// headset would; the package tells them apart.
  static bool _isOwnPackage(String? pkg) =>
      pkg != null && pkg.startsWith('com.barnabas.absorb');

  static Future<void> _logAbsorbDiag(String tag) async {
    _logAbsorbDiagFromSnapshot(tag, await _absorbDiagSnapshot());
  }

  /// How long after a car client (Android Auto / Automotive) last touched the
  /// browse tree we still assume a car is attached. Long enough to span a
  /// drive where the head unit connected once and never browsed again, short
  /// enough that a headset press hours after the drive is taken at face value.
  static const _carClientWindow = Duration(hours: 2);

  /// Whether another app is playing on the music stream right now. A media
  /// key that reaches us while we are paused and something else is audible
  /// was meant for that something else - an earbud's wear detection pausing
  /// a video, say. Android routes keys to the last media session, and video
  /// apps often have none, so it lands here; playing on top of the video is
  /// the last thing the user wants. Unknown reads as nothing playing.
  static Future<bool> _otherAudioActive() async {
    if (!Platform.isAndroid) return false;
    try {
      final active = await AndroidAudioManager().isMusicActive();
      debugPrint('[Handler] other audio active=$active');
      return active;
    } catch (e) {
      debugPrint('[Handler] isMusicActive failed: $e');
      return false;
    }
  }

  /// Whether a car client has touched the media browse tree recently, per the
  /// Java-side stamp. The MEDIA_PAUSE-while-paused phantom (GH #243) only
  /// exists on Android Auto, so this is what decides whether the click
  /// resolver suppresses that keycode or honors it as a headset toggle.
  /// Snapshot missing (iOS, channel unavailable) reads as no car.
  static Future<bool> _carClientRecentlySeen() async {
    final snap = await _absorbDiagSnapshot();
    final age = snap?['carClientAgeMs'];
    final seen =
        age is int && age >= 0 && age < _carClientWindow.inMilliseconds;
    debugPrint(
      '[Handler] car client ${seen ? 'seen' : 'not seen'} (carClientAgeMs=$age)',
    );
    return seen;
  }

  /// Force-push current PlaybackState so the notification picks up
  /// new chapter-relative position immediately (e.g. on chapter change).
  void refreshPlaybackState() {
    if (_idleNowPlayingState) {
      // Settings (skip amounts, lock seek bar, now-playing layout) still
      // change the idle notification; its position lives in the target, not
      // the player.
      _service?._pushIdleMediaItem();
      showIdlePlaybackState();
      return;
    }
    try {
      playbackState.add(_transformEvent(_player.playbackEvent));
      _lastPlaybackStateUpdate = DateTime.now();
      _lastPlaying = _player.playing;
      _lastProcessingState = _player.processingState;
    } catch (_) {}
  }

  bool _idleNowPlayingState = false;

  /// True while the notification describes the post-removal idle book. The
  /// media buttons then move the notification's position instead of a player
  /// that has no source loaded.
  bool get _idleControlsLive =>
      _idleNowPlayingState && (_service?._idleNotificationTarget != null);

  void clearIdlePlaybackState() {
    _idleNowPlayingState = false;
  }

  /// Show the retargeted idle book as a paused media item with a live Play
  /// control. The player has no source yet; play() routes to the stored
  /// notification target and starts that book. The progress bar sits at the
  /// book's saved position and seek/skip/chapter controls adjust that
  /// position before Play starts it.
  void showIdlePlaybackState() {
    _idleNowPlayingState = true;
    try {
      final service = _service;
      final idle = service?._idleNotificationTarget;
      final idleChapter = service?.idleChapterBounds;
      final chapter = service?.idleChapterMode == true ? idleChapter : null;
      final rawPosition = idle?.positionSec ?? 0;
      final chapterSpan = chapter != null ? chapter.end - chapter.start : 0.0;
      // Chapter progress mode shows the bar relative to the current chapter,
      // matching what playback reports for the same setting.
      final positionSec = chapter != null
          ? (chapterSpan > 0
              ? (rawPosition - chapter.start).clamp(0.0, chapterSpan).toDouble()
              : 0.0)
          : rawPosition;
      final hasChapters = idle != null && idle.chapters.isNotEmpty;

      final rewindControl = MediaControl(
        androidIcon: _skipIconName(_cachedBackSkip, forward: false),
        label: 'Back ${_cachedBackSkip}s',
        action: MediaAction.rewind,
      );
      final fastForwardControl = MediaControl(
        androidIcon: _skipIconName(_cachedForwardSkip, forward: true),
        label: 'Forward ${_cachedForwardSkip}s',
        action: MediaAction.fastForward,
      );
      final playControl = MediaControl.play.copyWith(
        androidIcon: 'drawable/ic_widget_play',
      );

      final controls = <MediaControl>[];
      final List<int> compactIndices;
      if (Platform.isAndroid) {
        if (!hasChapters) {
          // Without chapters the prev/next slots would just duplicate the
          // rewind/forward pair; keep the transport honest until the chapter
          // list arrives.
          controls.addAll([rewindControl, playControl, fastForwardControl]);
          compactIndices = const [0, 1, 2];
        } else {
          final prevChapter = MediaControl.skipToPrevious.copyWith(
            androidIcon: 'drawable/ic_widget_prev_chapter',
            label: 'Previous chapter',
          );
          final nextChapter = MediaControl.skipToNext.copyWith(
            androidIcon: 'drawable/ic_widget_next_chapter',
            label: 'Next chapter',
          );
          controls.addAll([
            rewindControl,
            prevChapter,
            playControl,
            nextChapter,
            fastForwardControl,
          ]);
          compactIndices = const [1, 2, 3];
        }
      } else {
        controls.addAll([rewindControl, playControl, fastForwardControl]);
        compactIndices = const [0, 1, 2];
      }

      playbackState.add(PlaybackState(
        controls: controls,
        systemActions: {
          if (!_cachedLockSeekBar) MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToQueueItem,
          if (Platform.isIOS) MediaAction.skipToNext,
          if (Platform.isIOS) MediaAction.skipToPrevious,
        },
        androidCompactActionIndices: compactIndices,
        processingState: AudioProcessingState.ready,
        playing: false,
        updatePosition:
            Duration(milliseconds: (positionSec * 1000).round()),
        bufferedPosition:
            Duration(milliseconds: (positionSec * 1000).round()),
        speed: 1.0,
        queueIndex: idleChapter?.index,
      ));
      _lastPlaybackStateUpdate = DateTime.now();
      _lastPlaying = false;
      _lastProcessingState = _player.processingState;
    } catch (e) {
      debugPrint('[Handler] showIdlePlaybackState failed: $e');
    }
  }

  AudioPlayerHandler() {
    _subscribePlaybackEvents();
    // One line per ExoPlayer state transition (playerStateStream is already
    // distinct). Tells "the app paused it" apart from "the audio pipeline
    // stalled": a play/pause blip the app caused shows up as playing flips
    // next to a Handler/Service/AudioSession line, a rebuffer shows as
    // ready -> buffering -> ready, and a BT-link hiccup shows nothing here.
    _player.playerStateStream.listen((s) {
      debugPrint(
        '[PlayerState] playing=${s.playing} state=${s.processingState.name} '
        'pos=${(_player.position.inMilliseconds / 1000).toStringAsFixed(2)}s',
      );
    });
  }

  /// Subscribe to the player's playback event stream and forward state to
  /// the system MediaSession. If the stream errors or completes unexpectedly,
  /// re-subscribe so system media controls stay alive.
  /// Rate-limited to prevent infinite error loops (e.g. multi-channel audio).
  int _resubscribeCount = 0;
  DateTime _lastResubscribe = DateTime.now();

  // Throttle playback state updates to avoid excessive notification refreshes
  DateTime _lastPlaybackStateUpdate = DateTime.now();
  bool? _lastPlaying;
  ProcessingState? _lastProcessingState;

  // Brief "Saved" flash on the Android Auto bookmark button after a save.
  bool _bookmarkSavedFlash = false;
  Timer? _bookmarkFlashTimer;

  // Keep the media session in buffering while a queued item is taking over.
  // Android maps AudioProcessingState.loading to STATE_CONNECTING, which does
  // not show the buffering animation used for an in-progress media load.
  bool _advanceBuffering = false;
  DateTime? _advanceBufferingUntil;
  Timer? _advanceBufferingMinimumTimer;

  void setAdvanceBuffering(
    bool value, {
    Duration minimumDuration = Duration.zero,
  }) {
    _advanceBufferingMinimumTimer?.cancel();
    _advanceBufferingMinimumTimer = null;
    final changed = _advanceBuffering != value;
    _advanceBuffering = value;
    _advanceBufferingUntil = value ? DateTime.now().add(minimumDuration) : null;
    if (value) _clearAdvanceBufferingIfReady();
    if (!changed && !value) return;
    refreshPlaybackState();
  }

  void _clearAdvanceBufferingIfReady({bool refresh = true}) {
    if (!_advanceBuffering ||
        _player.processingState != ProcessingState.ready) {
      return;
    }
    final remaining =
        _advanceBufferingUntil?.difference(DateTime.now()) ?? Duration.zero;
    if (remaining > Duration.zero) {
      _advanceBufferingMinimumTimer?.cancel();
      _advanceBufferingMinimumTimer = Timer(remaining, () {
        _advanceBufferingMinimumTimer = null;
        _clearAdvanceBufferingIfReady();
      });
      return;
    }
    _advanceBuffering = false;
    _advanceBufferingUntil = null;
    if (refresh) refreshPlaybackState();
  }

  void _subscribePlaybackEvents() {
    _player.playbackEventStream.listen(
      (event) {
        if (_idleNowPlayingState) return;
        _clearAdvanceBufferingIfReady(refresh: false);
        final state = _transformEvent(event);
        // Only push state on meaningful changes (play/pause, processing state)
        // or at most every 5 seconds for position updates
        final now = DateTime.now();
        final playingChanged = _player.playing != _lastPlaying;
        final processingChanged =
            _player.processingState != _lastProcessingState;
        final elapsed = now.difference(_lastPlaybackStateUpdate);

        if (playingChanged || processingChanged || elapsed.inSeconds >= 5) {
          playbackState.add(state);
          _lastPlaybackStateUpdate = now;
          _lastPlaying = _player.playing;
          _lastProcessingState = _player.processingState;
        }
        // Reset error counter on successful events
        _resubscribeCount = 0;
      },
      onError: (Object e, StackTrace st) {
        if (PlaybackErrorPolicy.isSourceError(e)) {
          // Paused: there is no audible stream to rescue, and a rebuild here
          // would start audio the user had paused (see the pause-intent guard
          // in playItem/_attemptStreamRetry).
          if (_player.playing) {
            debugPrint(
              '[Player] playbackEvent source error - restarting stream: $e',
            );
            AudioPlayerService()._attemptStreamRetry(e);
          } else {
            debugPrint(
              '[Player] playbackEvent source error while paused - ignoring: $e',
            );
          }
          return;
        }

        AudioPlayerService()._playerFailedWhilePaused('player error');

        final now = DateTime.now();
        // Reset counter if it's been more than 5 seconds since last error
        if (now.difference(_lastResubscribe).inSeconds > 5) {
          _resubscribeCount = 0;
        }
        _lastResubscribe = now;
        _resubscribeCount++;

        if (_resubscribeCount <= 3) {
          debugPrint(
            '[Player] playbackEvent error ($_resubscribeCount/3) - re-subscribing: $e',
          );
          refreshPlaybackState();
          Future.delayed(const Duration(seconds: 1), _subscribePlaybackEvents);
        } else {
          debugPrint(
            '[Player] playbackEvent error - too many rapid failures, stopping re-subscribe: $e',
          );
          if (PlaybackErrorPolicy.shouldRetryWithTranscode(e)) {
            final service = AudioPlayerService();
            if (service._localSessionMode) {
              service._recoverLocalPlayback(e);
            } else {
              service._retryWithTranscode();
            }
          }
        }
      },
      onDone: () {
        _resubscribeCount++;
        if (_resubscribeCount <= 3) {
          debugPrint(
            '[Player] playbackEvent stream completed ($_resubscribeCount/3) - re-subscribing',
          );
          refreshPlaybackState();
          Future.delayed(const Duration(seconds: 1), _subscribePlaybackEvents);
        } else {
          debugPrint(
            '[Player] playbackEvent stream completed - too many rapid re-subscribes, stopping',
          );
        }
      },
    );
  }

  // The Android Auto speed button shows a pre-baked badge for the current rate.
  // We snap to the nearest 0.05 within the baked range (0.5x..5.0x); every step
  // has a generated ic_speed_*x drawable (rendered from Roboto Bold).
  String _speedBadgeIcon() {
    final speed = _service?.speed ?? _player.speed;
    var rate = (speed * 20).round() / 20; // nearest 0.05
    if (rate < 0.5) rate = 0.5;
    if (rate > 5.0) rate = 5.0;
    // 1.0 -> "1x", 1.2 -> "1_2x", 1.25 -> "1_25x" (matches the generated files).
    final s = rate
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    return 'drawable/ic_speed_${s.replaceAll('.', '_')}x';
  }

  // The notification's rewind/forward buttons show a baked-in number for the
  // skip amount (out of the existing 5..60s set in 5s steps). Snap to the
  // nearest step so the resource always exists, mirroring _speedBadgeIcon.
  String _skipIconName(int seconds, {required bool forward}) {
    var step = ((seconds + 2) ~/ 5) * 5; // nearest 5 under rounding
    if (step < 5) step = 5;
    if (step > 60) step = 60;
    final dir = forward ? 'forward' : 'back';
    return 'drawable/ic_skip_${dir}_$step';
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    final playPause = (_player.playing ? MediaControl.pause : MediaControl.play)
        .copyWith(
          androidIcon: _player.playing
              ? 'drawable/ic_widget_pause'
              : 'drawable/ic_widget_play',
        );

    final rewindControl = MediaControl(
      androidIcon: _skipIconName(_cachedBackSkip, forward: false),
      label: 'Back ${_cachedBackSkip}s',
      action: MediaAction.rewind,
    );
    final fastForwardControl = MediaControl(
      androidIcon: _skipIconName(_cachedForwardSkip, forward: true),
      label: 'Forward ${_cachedForwardSkip}s',
      action: MediaAction.fastForward,
    );

    final controls = <MediaControl>[];
    // On Android, compact view (collapsed notification) shows 3 buttons:
    // prev | play | next — the solid, prominent middle three. On iOS the
    // expanded list is [rewind, play, forward], so compact = first three.
    final compactIndices = Platform.isAndroid
        ? const [1, 2, 3]
        : const [0, 1, 2];

    if (Platform.isAndroid) {
      final prevChapter = MediaControl.skipToPrevious.copyWith(
        androidIcon: 'drawable/ic_widget_prev_chapter',
        label: 'Previous chapter',
      );
      final nextChapter = MediaControl.skipToNext.copyWith(
        androidIcon: 'drawable/ic_widget_next_chapter',
        label: 'Next chapter',
      );
      final speed = MediaControl.custom(
        androidIcon: _speedBadgeIcon(),
        label: 'Speed',
        name: 'cycleSpeed',
      );
      // Bookmark icon/label briefly flip to a checkmark + "Saved" after a save,
      // as on-screen confirmation for Android Auto (the CarPlay banner equivalent).
      final bookmark = MediaControl.custom(
        androidIcon: _bookmarkSavedFlash
            ? 'drawable/ic_check'
            : 'drawable/ic_bookmark',
        label: _bookmarkSavedFlash ? 'Saved' : 'Bookmark',
        name: 'bookmark',
      );
      // Expanded order: rewind | prev | play | next | forward.
      // Prev/next/play use solid filled icons (ic_widget_*) so they read
      // bolder than the thin rewind/forward ring icons.
      controls.addAll([
        rewindControl,
        prevChapter,
        playPause,
        nextChapter,
        fastForwardControl,
      ]);
      // Speed/bookmark trail the five core buttons; on Android 13+ the phone
      // player shows a couple of trailing extra slots.
      controls.addAll([speed, bookmark]);
    } else {
      controls.addAll([rewindControl, playPause, fastForwardControl]);
    }

    return PlaybackState(
      controls: controls,
      // iOS-only in systemActions: on Android the prev/next buttons come from the
      // controls list above (standard skip actions feed the media notification);
      // iOS needs skipToNext/skipToPrevious here for the lock screen and CarPlay.
      systemActions: {
        // Dropping seek locks the scrubber: Android omits ACTION_SEEK_TO and iOS
        // omits changePlaybackPositionCommand, so it shows progress but can't be
        // dragged. The skip (rewind/forward) buttons stay functional.
        if (!_cachedLockSeekBar) MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToQueueItem,
        if (Platform.isIOS) MediaAction.skipToNext,
        if (Platform.isIOS) MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: compactIndices,
      processingState: () {
        final mapped = const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!;
        if (_advanceBuffering) return AudioProcessingState.buffering;
        return mapped;
      }(),
      playing: _player.playing,
      updatePosition: _speedAdjustedPosition(),
      bufferedPosition: _player.bufferedPosition,
      // Report speed as 1.0 because duration and position are already
      // divided by the playback speed. This makes Android Auto, WearOS,
      // and the notification show "real time remaining" instead of raw
      // content duration.
      speed: 1.0,
      queueIndex: _safeCurrentChapterIndex(),
    );
  }

  /// Return the index of the chapter containing the current playback position,
  /// or null if there are no chapters.  Used as queueIndex so Android Auto
  /// highlights the active chapter in the queue view.
  int? _safeCurrentChapterIndex() {
    try {
      if (_service == null) return null;
      final posSec = _player.position.inMilliseconds / 1000.0;
      return ChapterLookup.indexAt(
        _service!.chapters,
        posSec,
        _service!.totalDuration,
      );
    } catch (e) {
      debugPrint('[Handler] _safeCurrentChapterIndex error: $e');
      return null;
    }
  }

  /// Compute the position to report to the MediaSession, divided by playback
  /// speed so that Android Auto / WearOS / notification show "real time
  /// remaining" rather than raw content duration.
  Duration _speedAdjustedPosition() {
    Duration pos;
    if (_service != null && _service!.notifChapterMode) {
      final absPos = _service!.position;
      final chStart = Duration(seconds: _service!.currentChapterStart.round());
      final relative = absPos - chStart;
      pos = relative.isNegative ? Duration.zero : relative;
    } else {
      pos = _service?.position ?? _player.position;
    }
    final speed = _player.speed;
    if (speed <= 0 || speed == 1.0) return pos;
    return Duration(milliseconds: (pos.inMilliseconds / speed).round());
  }

  @override
  Future<void> play() async {
    debugPrint(
      '[Handler] play() called - routing to service (state=${_player.processingState.name})',
    );
    await _logAbsorbDiag('play');
    final entryBt = await AudioPlayerService._isBluetoothAudioConnected();
    if (entryBt) AudioPlayerService._lastPlayedOnBtAt = DateTime.now();
    debugPrint(
      '[ClickDebug] play() entry: ${_clickDebugSnapshot(btNow: entryBt)}',
    );
    // Mirror the click() guard: a raw play() arriving within 5s of a
    // headphone/AA/BT disconnect is almost always the platform echoing a
    // resume command from Android Auto / BT, not the user. Drop it to
    // avoid playback jumping to the phone speaker after the user unplugs
    // or AA tears down. Phone-surface play()s (notification, lock screen,
    // taskbar, in-app) are flagged via lastPlayFromHandset so they pass.
    if (_noisyPauseAt != null) {
      final elapsed = DateTime.now().difference(_noisyPauseAt!).inMilliseconds;
      if (elapsed < _noisyGuardMs && !lastPlayFromHandset) {
        debugPrint(
          '[Handler] Ignoring phantom play (${elapsed}ms after platform pause)',
        );
        return;
      }
      _noisyPauseAt = null;
    }
    _lastHandlerPlayAt = DateTime.now();
    if (_service != null) {
      await _service!.play();
    } else {
      debugPrint('[Handler] play() - no service ref, using player directly');
      await _player.play();
    }
  }

  @override
  Future<void> pause() async {
    _service?._markPauseRequested();
    debugPrint('[Handler] pause() called - routing to service');
    await _logAbsorbDiag('pause');
    final pauseEntryBt = await AudioPlayerService._isBluetoothAudioConnected();
    debugPrint(
      '[ClickDebug] pause() entry: ${_clickDebugSnapshot(btNow: pauseEntryBt)}',
    );
    _lastHandlerPauseAt = DateTime.now();
    // Android Auto disconnect can dispatch both a MediaButton click and a
    // pause() action simultaneously. The click's 400ms debounce timer would
    // then see playing=false and misinterpret it as "user wants to play",
    // triggering a cold-start restore. Cancel any pending click so the
    // platform-initiated pause wins.
    final clickPending = _clickTimer?.isActive ?? false;
    if (clickPending) {
      debugPrint('[Handler] Cancelling pending click (platform pause)');
      _clickTimer!.cancel();
      _clickCount = 0;
    }
    // Detect BT/AA disconnect by route change: we were playing on BT recently
    // and BT is no longer connected at this pause. Arm the 5s phantom guard
    // so any echoed resume command from the dead route gets dropped. We do
    // NOT stamp for plain user pauses (notification, lock screen, in-app)
    // because that would block their immediate follow-up play. becomingNoisy
    // covers the headphone-unplug path independently.
    if (!_inClickResolver) {
      final lastBt = AudioPlayerService._lastPlayedOnBtAt;
      final btJustWent = lastBt != null && !pauseEntryBt;
      if (btJustWent) {
        _noisyPauseAt = DateTime.now();
        _noisyGuardMs = 5000;
      }
    }
    if (_service != null) {
      await _service!.pause();
    } else {
      await _player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('[Handler] seek(${position.inSeconds}s)');
    if (_idleControlsLive) {
      var seconds = position.inMilliseconds / 1000.0;
      // In chapter mode the slider reports a position inside the displayed
      // chapter; the target stores whole-book time.
      final chapter = _service!.idleChapterMode
          ? _service!.idleChapterBounds
          : null;
      if (chapter != null) seconds += chapter.start;
      _service!.setIdleNotificationPosition(seconds);
      return;
    }
    if (_service != null) {
      final speed = _player.speed;
      final realPos = speed > 0 && speed != 1.0
          ? Duration(milliseconds: (position.inMilliseconds * speed).round())
          : position;
      final absPos = _service!.notifChapterMode
          ? realPos + Duration(seconds: _service!.currentChapterStart.round())
          : realPos;
      await _service!.seekTo(absPos);
    } else {
      await _player.seek(position);
    }
  }

  @override
  Future<void> stop() async {
    // Don't call super.stop() - it deactivates the MediaSession, and on some
    // devices (Android 16+) the system never re-routes BT media buttons /
    // notification controls to a reactivated session. Same reasoning as
    // onTaskRemoved below: keep the session alive so external controls
    // recover when the user comes back. Just stop the player.
    // Keep the MediaSession alive; it is what keeps BT/notification controls
    // routed after a stop (see onTaskRemoved).
    debugPrint(
      '[Handler] stop() - keeping MediaSession alive '
      '(playing=${_player.playing}, processingState=${_player.processingState.name}, '
      'hasService=${_service != null})',
    );
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[Handler] stop() player.stop error: $e');
    }
  }

  /// Dismiss the media notification after the user removed the current book
  /// from Absorbing. The normal [stop] deliberately keeps the MediaSession
  /// alive; an explicitly removed book must not keep showing there.
  Future<void> clearNotification() async {
    _idleNowPlayingState = false;
    final current = playbackState.value;
    debugPrint(
      '[Handler] clearNotification - dismissing stale notification '
      'state=${current.processingState.name}',
    );
    // audio_service's platform observer drops a null media item, so the
    // native side never receives this. It still clears the app-side stream.
    mediaItem.add(null);
    if (Platform.isAndroid) {
      // The vendored audio_service deliberately does not auto-stop on idle
      // (Android 16 keeps BT controls routed). Adding another idle state here
      // therefore never removed the notification; only the progress bar
      // changed. Ask the service to detach/cancel the notification directly,
      // leaving the MediaSession alive.
      if (current.processingState == AudioProcessingState.idle) {
        playbackState.add(PlaybackState(
          processingState: AudioProcessingState.idle,
          playing: false,
        ));
      }
      try {
        await _nativeHandlerChannel.invokeMethod<void>('dismissNotification');
        debugPrint(
          '[Handler] clearNotification - native notification dismissed',
        );
      } catch (e) {
        debugPrint('[Handler] clearNotification - native dismiss failed: $e');
      }
      return;
    }
    playbackState.add(PlaybackState(
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    try {
      await super.stop();
    } catch (e) {
      debugPrint('[Handler] clearNotification error: $e');
    }
  }

  /// Called when the user swipes the app away from recents.
  ///
  /// Only pause instead of stopping - the 10-minute pause timeout already
  /// handles cleanup (server session + audio focus). Calling stop() here
  /// deactivates the MediaSession, and on some devices (Android 16+) the
  /// system never re-routes BT media buttons to a reactivated session,
  /// leaving earbud controls permanently broken until reboot.
  @override
  Future<void> onTaskRemoved() async {
    debugPrint('[Handler] onTaskRemoved - app swiped away');
    // Don't stop cast playback when app is swiped away
    if (ChromecastService().isCasting) return;
    if (_service != null) {
      await _service!.pause();
    } else {
      await _player.pause();
    }
    // Don't call super.onTaskRemoved() - it calls stop() which deactivates
    // the MediaSession and breaks BT media button routing on restart.
  }

  @override
  Future<void> fastForward() async {
    debugPrint('[Handler] fastForward() - seeking forward');
    if (_idleControlsLive) {
      final target = _service!._idleNotificationTarget!;
      final skipAmount = await PlayerSettings.getEffectiveForwardSkip(
        libraryId: target.libraryId,
      );
      _service!.setIdleNotificationPosition(
        target.positionSec + skipAmount,
      );
      return;
    }
    final skipAmount = await PlayerSettings.getEffectiveForwardSkip(
      libraryId: _service?.currentLibraryId,
    );
    debugPrint(
      '[SkipDebug] fastForward: lib=${_service?.currentLibraryId} amount=${skipAmount}s',
    );
    if (_service != null) {
      await _service!.skipForward(skipAmount);
    } else {
      // Content seconds: skip the configured amount of audio regardless of
      // playback speed, matching AudioPlayerService.skipForward.
      await _player.seek(_player.position + Duration(seconds: skipAmount));
    }
  }

  @override
  Future<void> rewind() async {
    debugPrint('[Handler] rewind() - seeking back');
    if (_idleControlsLive) {
      final target = _service!._idleNotificationTarget!;
      final skipAmount = await PlayerSettings.getEffectiveBackSkip(
        libraryId: target.libraryId,
      );
      _service!.setIdleNotificationPosition(
        target.positionSec - skipAmount,
      );
      return;
    }
    final skipAmount = await PlayerSettings.getEffectiveBackSkip(
      libraryId: _service?.currentLibraryId,
    );
    debugPrint(
      '[SkipDebug] rewind: lib=${_service?.currentLibraryId} amount=${skipAmount}s',
    );
    if (_service != null) {
      await _service!.skipBackward(skipAmount);
    } else {
      // Content seconds, matching AudioPlayerService.skipBackward.
      var pos = _player.position - Duration(seconds: skipAmount);
      if (pos < Duration.zero) pos = Duration.zero;
      await _player.seek(pos);
    }
  }

  // Android 13+'s media notification and Android Auto transport route
  // Previous/Next through these, so on Android they mean chapters (no-op for
  // items without chapters). iOS keeps them as skip-by-seconds for Bluetooth
  // track buttons.
  @override
  Future<void> skipToNext() async {
    if (_idleControlsLive) {
      if (_service!.skipIdleNotificationChapter(forward: true)) return;
      await fastForward();
      return;
    }
    if (Platform.isAndroid && _service != null) {
      await _service!.skipToNextChapter();
      return;
    }
    await fastForward();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_idleControlsLive) {
      if (_service!.skipIdleNotificationChapter(forward: false)) return;
      await rewind();
      return;
    }
    if (Platform.isAndroid && _service != null) {
      await _service!.skipToPreviousChapter();
      return;
    }
    await rewind();
  }

  // Custom click handler with proper multi-press detection
  Timer? _clickTimer;
  int _clickCount = 0;
  DateTime? _hardwareButtonTime; // cooldown after hardware next/prev
  DateTime? _noisyPauseAt; // suppress clicks for a window after BT disconnect
  int _noisyGuardMs = 5000;
  // Keycode of the media button event that arrived at the most recent click().
  // Read from the [AbsorbDiag] snapshot at click arrival and consumed by the
  // 400ms resolver to honor PAUSE/PLAY intent instead of blindly toggling -
  // Android Auto sends KEYCODE_MEDIA_PAUSE when the user switches to Radio,
  // and the old toggle path bounced it back as a phantom resume (GH #243).
  int? _lastClickKeyCode;
  String? _lastClickKeyPkg;
  // When the debounce-free resume last fired, so a second press arriving just
  // after it is still read as a double-press skip rather than a fresh click.
  DateTime? _fastPathPlayAt;
  // True while the click resolver is synchronously calling pause()/play().
  // pause() uses this to skip stamping _noisyPauseAt for click-driven pauses,
  // so legit user pause-then-play flows are not blocked by the disconnect guard.
  bool _inClickResolver = false;
  // [ClickDebug] — timestamp of the last Handler-level pause() call.
  // Used to correlate phantom play/click commands with a preceding pause.
  DateTime? _lastHandlerPauseAt;
  // [ClickDebug] — timestamp of the last Handler-level play() call.
  // Used to spot the variant-3 phantom-resume fingerprint: click-initiated
  // play followed by a raw pause a few seconds later (AA disconnect tearing
  // down after a spurious transport event).
  DateTime? _lastHandlerPlayAt;

  /// [ClickDebug] — one-line snapshot of state around a media-button event.
  /// Helps diagnose phantom clicks after Android Auto disconnect.
  ///
  /// `btNow` should be pre-fetched async by the caller when available so
  /// the AA-disconnect heuristic can be evaluated. When null, that flag
  /// is reported as `unknown`.
  String _clickDebugSnapshot({bool? btNow}) {
    final now = DateTime.now();
    int sincePrevPauseMs = -1;
    if (_lastHandlerPauseAt != null) {
      sincePrevPauseMs = now.difference(_lastHandlerPauseAt!).inMilliseconds;
    }
    int sincePrevPlayMs = -1;
    if (_lastHandlerPlayAt != null) {
      sincePrevPlayMs = now.difference(_lastHandlerPlayAt!).inMilliseconds;
    }
    int sinceForegroundMs = -1;
    if (AudioPlayerService._lastForegroundAt != null) {
      sinceForegroundMs = now
          .difference(AudioPlayerService._lastForegroundAt!)
          .inMilliseconds;
    }
    int sinceNoisyPauseMs = -1;
    if (_noisyPauseAt != null) {
      sinceNoisyPauseMs = now.difference(_noisyPauseAt!).inMilliseconds;
    }
    final backgrounded = _service?.isBackgrounded;
    // Variant-3 fingerprint: raw pause fires within 5s of a click-initiated
    // play while still playing in background. Flag it so the pause log line
    // is self-describing without having to cross-reference timestamps.
    final phantomSuspect =
        sincePrevPlayMs >= 0 &&
        sincePrevPlayMs < 5000 &&
        _player.playing &&
        (backgrounded ?? false);
    // AA-disconnect fingerprint: BT/AA was the audio route within the last
    // 10 min, isn't anymore, and the click came in while bg + not playing.
    int sinceBtMs = -1;
    final lastBt = AudioPlayerService._lastPlayedOnBtAt;
    if (lastBt != null) sinceBtMs = now.difference(lastBt).inMilliseconds;
    final String aaDisconnect;
    if (btNow == null) {
      aaDisconnect = 'unknown';
    } else {
      final fired =
          lastBt != null && !btNow && sinceBtMs >= 0 && sinceBtMs < 600000;
      aaDisconnect = fired ? 'true' : 'false';
    }
    return 'bg=$backgrounded, sincePrevPauseMs=$sincePrevPauseMs, '
        'sincePrevPlayMs=$sincePrevPlayMs, '
        'sinceForegroundMs=$sinceForegroundMs, '
        'sinceNoisyPauseMs=$sinceNoisyPauseMs, '
        'playing=${_player.playing}, '
        'processingState=${_player.processingState.name}, '
        'noisyPause=${AudioPlayerService._noisyPause}, '
        'phantomSuspect=$phantomSuspect, '
        'sinceBtMs=$sinceBtMs, btNow=${btNow ?? 'unknown'}, '
        'aaDisconnectSuspect=$aaDisconnect';
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    debugPrint(
      '[Handler] click(button=$button) count=${_clickCount + 1} playing=${_player.playing}',
    );
    final diagSnap = await _absorbDiagSnapshot();
    _logAbsorbDiagFromSnapshot('click', diagSnap);
    // Pre-fetch BT-route state so the snapshot can fill in the AA-disconnect
    // heuristic and the suppression branch below has a value to test against.
    final btNow = await AudioPlayerService._isBluetoothAudioConnected();
    final snapshot = _clickDebugSnapshot(btNow: btNow);
    debugPrint('[ClickDebug] click arrival (button=$button): $snapshot');
    _service?._logEvent(
      PlaybackEventType.clickDebounce,
      detail: 'button=$button | $snapshot',
    );

    if (button != MediaButton.media) {
      // Hardware next/prev button — set cooldown to ignore phantom media click
      _hardwareButtonTime = DateTime.now();
      if (button == MediaButton.next) {
        debugPrint('[Handler] Hardware NEXT button');
        if (Platform.isAndroid && _service != null) {
          await _service!.skipToNextChapter();
        } else {
          await fastForward();
        }
      } else if (button == MediaButton.previous) {
        debugPrint('[Handler] Hardware PREV button');
        if (Platform.isAndroid && _service != null) {
          await _service!.skipToPreviousChapter();
        } else {
          await rewind();
        }
      }
      return;
    }

    // Ignore phantom media click that follows hardware next/prev within 500ms
    if (_hardwareButtonTime != null) {
      final elapsed = DateTime.now()
          .difference(_hardwareButtonTime!)
          .inMilliseconds;
      if (elapsed < 500) {
        debugPrint(
          '[Handler] Ignoring phantom media click (${elapsed}ms after hardware button)',
        );
        _hardwareButtonTime = null;
        return;
      }
      _hardwareButtonTime = null;
    }

    // Suppress phantom play commands within 5s of a BT/auto disconnect
    if (_noisyPauseAt != null) {
      final elapsed = DateTime.now().difference(_noisyPauseAt!).inMilliseconds;
      if (elapsed < _noisyGuardMs) {
        debugPrint(
          '[Handler] Ignoring phantom click (${elapsed}ms after noisy pause)',
        );
        return;
      }
      _noisyPauseAt = null;
    }

    // AA-disconnect phantom: a delayed MediaButton.media event arrives in
    // background, not playing, after we last played on BT/AA — and BT is
    // gone now. On devices where AA disconnect doesn't fire becomingNoisy
    // (Pixel 10 Pro / Android 16 observed), this is the only way to catch
    // the lingering MediaSession resume that the OS sends minutes later.
    final lastBt = AudioPlayerService._lastPlayedOnBtAt;
    final bg = _service?.isBackgrounded ?? false;
    if (bg && !_player.playing && lastBt != null && !btNow) {
      final ageMs = DateTime.now().difference(lastBt).inMilliseconds;
      if (ageMs < 600000) {
        debugPrint(
          '[Handler] Ignoring phantom click after AA/BT disconnect '
          '(${ageMs}ms since last BT-on, btNow=false, bg=true, playing=false)',
        );
        _service?._logEvent(
          PlaybackEventType.clickDebounce,
          detail: 'phantom AA/BT click suppressed | sinceBtMs=$ageMs',
        );
        // Re-arm the 5s noisy guard so a follow-up click in the same
        // burst is also ignored, matching the BT-disconnect suppression flow.
        _noisyPauseAt = DateTime.now();
        _noisyGuardMs = 5000;
        return;
      }
    }

    // click() is a genuine hardware-button / media-button press — always
    // handset-originated. Clears any stale car/AA flag so the play()
    // call below isn't swallowed by the noisy-guard.
    lastPlayFromHandset = true;

    // Stash the keycode for the resolver if it belongs to this click. Only
    // do this for clicks that actually count - early-return guards above
    // skip the stash so they can't poison the keycode of a click that does
    // make it to the resolver. 500ms cap is a safety margin; typical
    // keyAgeMs from the Java side is 0-2ms.
    if (diagSnap != null) {
      final age = diagSnap['lastKeyAgeMs'];
      final kc = diagSnap['lastKeyCode'];
      if (age is int && age >= 0 && age < 500 && kc is int && kc != 0) {
        _lastClickKeyCode = kc;
        final pkg = diagSnap['lastKeyPkg'];
        _lastClickKeyPkg = pkg is String ? pkg : null;
      }
    }

    // Second half of the fast path below: a press landing right after an
    // instant resume is the double-press the debounce would normally have
    // caught, so honour it as a skip. We are already playing by now, which is
    // exactly the state a double-press-to-skip expects.
    final fastPlay = _fastPathPlayAt;
    if (fastPlay != null &&
        DateTime.now().difference(fastPlay) <
            const Duration(milliseconds: 600)) {
      _fastPathPlayAt = null;
      debugPrint(
        '[Handler] -> second press after instant play -> SKIP FORWARD',
      );
      await fastForward();
      return;
    }

    // Resume from an explicit MEDIA_PLAY does not wait for the multi-press
    // window. The 400ms timer is punctual while audio runs - every pause press
    // resolves in ~407ms - but once paused the process gets throttled and the
    // same timer fired 7-8 SECONDS late (measured 2026-08-13, with total log
    // silence in the gap). The keypress itself always arrives instantly.
    //
    // Deliberately play-only: pause never had the latency, and pausing
    // instantly would eat the second press of a double-press-to-skip, which is
    // the gesture people use while listening. PLAY_PAUSE (85) and HEADSETHOOK
    // stay on the debounce too - for a single-button remote the second press is
    // genuinely ambiguous until the window closes.
    if (_clickCount == 0 &&
        !(_clickTimer?.isActive ?? false) &&
        _lastClickKeyCode == 126 &&
        !_player.playing) {
      _lastClickKeyCode = null;
      _inClickResolver = true;
      try {
        debugPrint('[Handler] -> MEDIA_PLAY while paused, no debounce -> PLAY');
        await play();
      } finally {
        _inClickResolver = false;
      }
      _fastPathPlayAt = DateTime.now();
      return;
    }

    _clickCount++;
    _clickTimer?.cancel();
    _clickTimer = Timer(const Duration(milliseconds: 400), () async {
      final count = _clickCount;
      _clickCount = 0;
      debugPrint(
        '[Handler] click resolved: count=$count playing=${_player.playing}',
      );
      final resolveBt = await AudioPlayerService._isBluetoothAudioConnected();
      debugPrint(
        '[ClickDebug] click resolve (count=$count): ${_clickDebugSnapshot(btNow: resolveBt)}',
      );
      switch (count) {
        case 1:
          // Sleep-timer snooze (GH #333): during the wind-down window a
          // single press resets the timer instead of pausing. Sits after all
          // the phantom guards so a spurious AA/BT click can't reset it, and
          // inside the resolver so double/triple presses still skip.
          if (await SleepTimerService().snoozeFromMediaButton()) {
            _lastClickKeyCode = null;
            debugPrint(
              '[Handler] → single press consumed by sleep timer snooze',
            );
            break;
          }
          _inClickResolver = true;
          try {
            // Honor the actual keycode the system dispatched when we can.
            // audio_service collapses MEDIA_PLAY / MEDIA_PAUSE / PLAY_PAUSE /
            // HEADSETHOOK all into MediaButton.media, but Android Auto sends
            // MEDIA_PAUSE specifically when the user switches to another media
            // app - blindly toggling there resumes us right after we paused
            // (GH #243). For the unambiguous play / pause keycodes, follow the
            // intent. PLAY_PAUSE / HEADSETHOOK / unknown / stale stay as
            // toggles so single-button BT remotes keep working.
            const keycodeMediaPlay = 126;
            const keycodeMediaPause = 127;
            final kc = _lastClickKeyCode;
            final pkg = _lastClickKeyPkg;
            _lastClickKeyCode = null;
            _lastClickKeyPkg = null;
            final sincePause = _lastHandlerPauseAt == null
                ? null
                : DateTime.now().difference(_lastHandlerPauseAt!);
            // A key that reaches us while something else is audible was
            // probably meant for that something else (an earbud pausing a
            // video) - unless we paused a moment ago, in which case the
            // user is toggling us back and the other sound is beside the
            // point. A beta tester with a car link could not resume from
            // his headset or his widget for two hours because of this.
            Future<bool> meantForOtherAudio() async {
              if (_isOwnPackage(pkg)) return false;
              if (sincePause != null &&
                  sincePause < const Duration(minutes: 3)) {
                return false;
              }
              return _otherAudioActive();
            }

            if (kc == keycodeMediaPause) {
              if (_player.playing) {
                debugPrint('[Handler] → single press (MEDIA_PAUSE) → PAUSE');
                await pause();
              } else if (_isCarPackage(pkg) ||
                  (pkg == null && await _carClientRecentlySeen())) {
                // A car never means play with a pause key: Android Auto
                // repeats MEDIA_PAUSE right after we pause (#243), and sends
                // it again when the head unit switches to its radio, which
                // started the book back up over the radio. Its own play
                // button comes in as a play command, not this key.
                debugPrint(
                  '[Handler] -> single press (MEDIA_PAUSE while paused, car, '
                  '${sincePause?.inMilliseconds ?? -1}ms after pausing) -> no-op',
                );
              } else if (await meantForOtherAudio()) {
                debugPrint(
                  '[Handler] -> single press (MEDIA_PAUSE while paused, other audio active) -> no-op',
                );
              } else {
                // Some BT headsets (Shokz seen in the wild) send MEDIA_PAUSE
                // for a play press when their idea of our state went stale.
                debugPrint(
                  '[Handler] -> single press (MEDIA_PAUSE while paused, pkg=$pkg) -> PLAY',
                );
                await play();
              }
            } else if (kc == keycodeMediaPlay) {
              if (!_player.playing) {
                debugPrint('[Handler] → single press (MEDIA_PLAY) → PLAY');
                await play();
              } else {
                debugPrint(
                  '[Handler] → single press (MEDIA_PLAY while playing) → no-op',
                );
              }
            } else if (_player.playing) {
              debugPrint('[Handler] → single press → PAUSE');
              await pause();
            } else if (await meantForOtherAudio()) {
              debugPrint(
                '[Handler] -> single press while paused, other audio active -> no-op',
              );
            } else {
              debugPrint('[Handler] → single press (pkg=$pkg) → PLAY');
              await play();
            }
          } finally {
            _inClickResolver = false;
          }
          break;
        case 2:
          debugPrint('[Handler] → double press → SKIP FORWARD');
          await fastForward();
          break;
        case 3:
        default:
          debugPrint('[Handler] → triple press → SKIP BACK');
          await rewind();
          break;
      }
    });
  }

  /// Cancel any pending media-button click so a BT disconnect doesn't
  /// accidentally resume playback on the phone speaker. [guardMs] is how long
  /// a play that follows is treated as the platform echoing a resume.
  void cancelPendingClick({int guardMs = 5000}) {
    _noisyPauseAt = DateTime.now();
    _noisyGuardMs = guardMs;
    if (_clickTimer?.isActive ?? false) {
      debugPrint('[Handler] Cancelling pending click (noisy pause)');
      _clickTimer!.cancel();
      _clickCount = 0;
    }
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    debugPrint('[Handler] customAction($name)');
    switch (name) {
      case 'nextChapter':
        if (_service != null) await _service!.skipToNextChapter();
        break;
      case 'previousChapter':
        if (_service != null) await _service!.skipToPreviousChapter();
        break;
      case 'cycleSpeed':
        await _cycleSpeed();
        break;
      case 'bookmark':
        return await _bookmarkCurrentPosition();
    }
  }

  /// Step playback speed up to the next configured preset, wrapping back to the
  /// slowest once past the top. Used by the CarPlay / Android Auto speed button.
  Future<void> _cycleSpeed() async {
    final presets = await PlayerSettings.getSpeedPresets();
    if (presets.isEmpty) return;
    final cur = _service?.speed ?? _player.speed;
    var next = presets.first; // wrap to slowest when already at/above the top
    for (final p in presets) {
      if (p > cur + 0.001) {
        next = p;
        break;
      }
    }
    if (_service != null) {
      await _service!.setSpeed(next);
    } else {
      await setSpeed(next);
    }
  }

  /// Save a bookmark at the current position, mirroring the in-app car-mode
  /// button (chapter title as the label, pushed to the server via the API).
  /// A podcast episode is bookmarked under its own key, which keeps it on the
  /// device - ABS bookmarks have nowhere to put an episode id.
  Future<bool> _bookmarkCurrentPosition() async {
    final svc = _service;
    if (svc == null) return false;
    final itemId = svc.currentItemId;
    if (itemId == null) return false;
    final pos = svc.position.inMilliseconds / 1000.0;
    final chTitle = svc.currentChapter?['title'] as String?;
    await BookmarkService().addBookmark(
      itemId: playbackDownloadKey(itemId, svc.currentEpisodeId),
      positionSeconds: pos,
      title: (chTitle != null && chTitle.isNotEmpty) ? chTitle : 'Bookmark',
      api: svc.currentApi,
    );
    if (Platform.isAndroid) {
      // Flash a checkmark on the Android Auto bookmark button for ~2s. iOS gets
      // its confirmation via the CarPlay banner instead.
      _bookmarkSavedFlash = true;
      refreshPlaybackState();
      _bookmarkFlashTimer?.cancel();
      _bookmarkFlashTimer = Timer(const Duration(seconds: 2), () {
        _bookmarkSavedFlash = false;
        refreshPlaybackState();
      });
    }
    return true;
  }

  // ─── Chapter queue (for Android Auto queue button) ─────────────────

  /// Populate the MediaSession queue with chapter entries so AA shows
  /// a chapter list via the queue button on the Now Playing screen.
  void updateChaptersQueue(List<dynamic> chapters) {
    if (chapters.isEmpty) {
      queue.add(const []);
      return;
    }
    final items = chapters.asMap().entries.map((e) {
      final ch = e.value as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      return MediaItem(
        id: 'chapter_${e.key}',
        title: ch['title'] as String? ?? 'Chapter ${e.key + 1}',
        duration: Duration(milliseconds: ((end - start) * 1000).round()),
      );
    }).toList();
    queue.add(items);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    debugPrint('[Handler] skipToQueueItem($index)');
    if (_idleControlsLive) {
      final idle = _service!._idleNotificationTarget!;
      if (index >= 0 && index < idle.chapters.length) {
        final start =
            (idle.chapters[index] as Map<String, dynamic>)['start'] as num?;
        _service!.setIdleNotificationPosition(start?.toDouble() ?? 0);
      }
      return;
    }
    if (_service == null) return;
    final chapters = _service!.chapters;
    if (index < 0 || index >= chapters.length) return;
    final start = (chapters[index]['start'] as num?)?.toDouble() ?? 0;
    await _service!.seekTo(Duration(milliseconds: (start * 1000).round()));
  }

  // ─── Android Auto browse tree ──────────────────────────────────────

  final _autoService = AndroidAutoService();

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    debugPrint('[Handler] getChildren($parentMediaId)');
    if (Platform.isAndroid) unawaited(_maybeAutoplayOnCarConnect());
    // Don't await refresh() here — getChildrenOf() handles it:
    // downloads are populated instantly, server data loads in background.
    return _autoService.getChildrenOf(parentMediaId);
  }

  DateTime? _lastCarBrowseSeen;

  /// GH #371: opt-in autoplay when Android Auto connects with nothing loaded.
  ///
  /// A browse request alone isn't a car - Bluetooth stereos browse over AVRCP
  /// too - so this trusts the Java-side gearhead stamp, and only a stamp a few
  /// seconds old counts as "the car just connected". A book already loaded
  /// means the session is alive and Android Auto's own resume setting owns the
  /// warm case (and it keeps a deliberate mid-drive pause from being undone by
  /// a later browse). Browses during the same drive keep refreshing
  /// [_lastCarBrowseSeen], so only a fresh stamp after a quiet gap fires.
  Future<void> _maybeAutoplayOnCarConnect() async {
    try {
      final service = _service;
      if (service == null) return;
      final snap = await _absorbDiagSnapshot();
      final age = snap?['carClientAgeMs'];
      final carFresh = age is int && age >= 0 && age < 15000;
      if (!carFresh) return;
      final now = DateTime.now();
      final last = _lastCarBrowseSeen;
      _lastCarBrowseSeen = now;
      final isNewConnection =
          last == null || now.difference(last) > const Duration(minutes: 5);
      if (!isNewConnection) return;
      if (service.hasBook) return;
      if (!await PlayerSettings.getAutoplayOnCarConnect()) return;
      // Let the browse tree and session setup settle before starting audio.
      await Future.delayed(const Duration(milliseconds: 1500));
      if (service.hasBook || service.isPlaying) return;
      final restore = AudioPlayerService.onColdStartPlayRequested;
      if (restore == null) return;
      debugPrint('[AutoPlay] Android Auto connected - resuming last played');
      await restore();
    } catch (e) {
      debugPrint('[AutoPlay] car-connect autoplay failed: $e');
    }
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    debugPrint('[Handler] getMediaItem($mediaId)');
    return _autoService.getMediaItem(mediaId);
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    debugPrint('[Handler] search("$query")');
    return _autoService.search(query);
  }

  @override
  Future<void> prepareFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    debugPrint('[Handler] prepareFromMediaId($mediaId)');
    await _playFromAutoMediaId(mediaId);
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    debugPrint('[Handler] playFromMediaId($mediaId)');
    await _playFromAutoMediaId(mediaId);
  }

  Future<void> _playFromAutoMediaId(String mediaId) async {
    final absId = AutoMediaIds.absItemId(mediaId);
    if (absId == null) {
      debugPrint('[Handler] Invalid media ID for playback: $mediaId');
      return;
    }

    if (_service == null) {
      debugPrint('[Handler] No service bound — cannot play');
      return;
    }

    final api = await _autoService.getApi();
    if (api == null) {
      debugPrint('[Handler] No API credentials — cannot play');
      return;
    }

    // Detect podcast episodes via compound key (showId-episodeId, length > 36)
    final isEpisode = absId.length > 36;
    final showId = isEpisode ? absId.substring(0, 36) : null;
    final episodeId = isEpisode ? absId.substring(37) : null;
    // For API calls, use the show ID (not compound key) for podcast episodes
    final apiItemId = showId ?? absId;

    // Try to find in cached entries first
    var entry = _autoService.findEntry(absId);

    // If not in AA cache, check if the item is downloaded locally.
    // This handles cold-start scenarios where the AA browse tree hasn't
    // been populated yet but the user taps a downloaded item.
    if (entry == null) {
      final ds = DownloadService();
      if (ds.isDownloaded(absId)) {
        debugPrint(
          '[Handler] Item not in AA cache but downloaded locally: $absId',
        );
        final dl = ds.getInfo(absId);
        double duration = 0;
        List<dynamic> chapters = [];
        if (dl.sessionData != null) {
          try {
            final session = jsonDecode(dl.sessionData!) as Map<String, dynamic>;
            duration = (session['duration'] as num?)?.toDouble() ?? 0;
            chapters = session['chapters'] as List<dynamic>? ?? [];
          } catch (_) {}
        }
        entry = AutoBookEntry(
          id: absId,
          title: dl.title ?? 'Unknown',
          author: dl.author ?? '',
          duration: duration,
          coverUrl: AndroidAutoService.localCoverUri(apiItemId),
          chapters: chapters,
          episodeId: episodeId,
          showId: showId,
          libraryId: dl.libraryId,
        );
      }
    }

    // If still not found, fetch the item details from server
    if (entry == null) {
      debugPrint('[Handler] Item not cached, fetching from server: $apiItemId');
      try {
        final response = await api.getLibraryItem(apiItemId);
        if (response != null) {
          final media = response['media'] as Map<String, dynamic>?;
          final metadata = media?['metadata'] as Map<String, dynamic>? ?? {};

          if (isEpisode) {
            // Find the specific episode in the show's episode list
            final episodes = media?['episodes'] as List<dynamic>? ?? [];
            final ep = episodes.cast<Map<String, dynamic>?>().firstWhere(
              (e) => e?['id'] == episodeId,
              orElse: () => null,
            );
            if (ep != null) {
              entry = AutoBookEntry(
                id: absId,
                title: ep['title'] as String? ?? 'Episode',
                author: metadata['title'] as String? ?? '', // show name
                duration: (ep['duration'] as num?)?.toDouble() ?? 0,
                coverUrl: AndroidAutoService.localCoverUri(apiItemId),
                chapters: ep['chapters'] as List<dynamic>? ?? [],
                episodeId: episodeId,
                showId: showId,
                libraryId: response['libraryId'] as String?,
              );
            }
          } else {
            entry = AutoBookEntry(
              id: absId,
              title: metadata['title'] as String? ?? 'Unknown',
              author: metadata['authorName'] as String? ?? '',
              duration: (media?['duration'] as num?)?.toDouble() ?? 0,
              coverUrl: AndroidAutoService.localCoverUri(absId),
              chapters: media?['chapters'] as List<dynamic>? ?? [],
              libraryId: response['libraryId'] as String?,
            );
          }
        }
      } catch (e) {
        debugPrint('[Handler] Error fetching item: $e');
      }
    }

    if (entry == null) {
      debugPrint('[Handler] Item not found: $absId');
      return;
    }

    debugPrint(
      '[Handler] Android Auto play: "${entry.title}" by ${entry.author}',
    );

    // Always generate a fresh HTTP cover URL for Now Playing — api is
    // available here, so use it directly rather than relying on the cached
    // entry.coverUrl (which may be a content:// URI when offline).
    final nowPlayingCoverUrl = api.getCoverUrl(apiItemId, width: 400);

    await _service!.playItem(
      api: api,
      itemId: apiItemId,
      title: entry.title,
      author: entry.author,
      coverUrl: nowPlayingCoverUrl,
      totalDuration: entry.duration,
      chapters: entry.chapters,
      startTime: entry.currentTime ?? 0,
      episodeId: entry.episodeId,
      episodeTitle: entry.episodeId != null ? entry.title : null,
      libraryId: entry.libraryId,
      seriesId: null,
    );
  }
}

// ─── Singleton service ───

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._() {
    ApiService.addTokenRefreshListener(_onApiTokenRefreshed);
  }

  /// Called when a book completes naturally (before player state is cleared).
  /// Register via [setOnBookFinishedCallback]. Used by LibraryProvider to
  /// update local finished state immediately without waiting for a server refresh.
  static void Function(String itemId)? _onBookFinishedCallback;
  // Buffers the most recent completion key when the callback fires before
  // LibraryProvider is ready to handle it (e.g. Android Auto cold-start).
  // LibraryProvider calls [drainPendingBookFinished] once its absorbing cache
  // is loaded so auto-advance has the state it needs.
  static String? _pendingBookFinishedKey;

  /// A book started or resumed from the app's own controls.
  static void Function(String itemId)? onAppPlay;

  static void setOnBookFinishedCallback(void Function(String itemId)? cb) {
    _onBookFinishedCallback = cb;
  }

  // Pre-buffer callback. AudioPlayerService asks LibraryProvider for the next
  // manual-queue item ~15s before current ends, so the next AVQueuePlayer item
  // is already in the queue when the current one finishes. iOS auto-advances
  // natively (no fresh setAudioSource in background, so iOS keeps granting
  // audio output). The map must contain at least: itemId, title, author,
  // duration, and either localPaths or audioTracks.
  static Future<Map<String, dynamic>?> Function(String currentItemId)?
  _onPeekNextItemCallback;
  static void setOnPeekNextItemCallback(
    Future<Map<String, dynamic>?> Function(String)? cb,
  ) {
    _onPeekNextItemCallback = cb;
  }

  // Relaxed "will the queue auto-continue to another item after this one?"
  // probe. Unlike [_onPeekNextItemCallback] (which requires a directly playable,
  // single-track source for pre-buffering), this only asks whether an eligible
  // next entry exists, so the finish-cue gate can separate an auto continuation
  // from a book that stops here.
  static Future<bool> Function(String currentKey)? _onWillAutoAdvanceCallback;
  static void setOnWillAutoAdvanceCallback(Future<bool> Function(String)? cb) {
    _onWillAutoAdvanceCallback = cb;
  }

  // Fired when the AVQueuePlayer natively auto-advances from the current item
  // to a pre-buffered next item. LibraryProvider uses this to mark the old
  // item finished WITHOUT triggering its normal auto-advance flow (which would
  // call playItem and rebuild the source, defeating the pre-buffer).
  static void Function(String oldItemId)? _onAutoQueueAdvancedCallback;
  static void setOnAutoQueueAdvancedCallback(void Function(String)? cb) {
    _onAutoQueueAdvancedCallback = cb;
  }

  static void drainPendingBookFinished() {
    final cb = _onBookFinishedCallback;
    final pending = _pendingBookFinishedKey;
    if (cb == null || pending == null) return;
    _pendingBookFinishedKey = null;

    // If something is loaded in the player by the time the drain fires, the
    // user already moved on (manually selected a new item in AA, or is paused
    // mid-book). Replaying the completion here would auto-advance on top of
    // their current state — the "phantom resume after pause" regression.
    // Drop the stale completion instead.
    final loaded = _instance._currentItemId;
    if (loaded != null) {
      debugPrint(
        '[Player] Dropping stale book-finished drain (player has item=$loaded, buffered key=$pending)',
      );
      return;
    }

    debugPrint('[Player] Draining buffered book-finished key=$pending');
    cb(pending);
  }

  /// Called when a new item starts playing. Used by LibraryProvider to trigger
  /// rolling downloads for the next items in a series/podcast.
  static Future<void> Function(String key, double duration)?
  _onPlayStartedCallback;
  static void setOnPlayStartedCallback(
    Future<void> Function(String key, double duration)? cb,
  ) {
    _onPlayStartedCallback = cb;
  }

  /// Called when a podcast episode starts playing. Used by AppShell to
  /// auto-navigate to the Absorbing tab.
  static void Function()? _onEpisodePlayStartedCallback;
  static void setOnEpisodePlayStartedCallback(void Function()? cb) {
    _onEpisodePlayStartedCallback = cb;
  }

  /// Called when playback state changes (playing/paused). Used by
  /// LibraryProvider for battery-saving socket lifecycle.
  static void Function(bool isPlaying)? _onPlaybackStateChangedCallback;
  static void setOnPlaybackStateChangedCallback(
    void Function(bool isPlaying)? cb,
  ) {
    _onPlaybackStateChangedCallback = cb;
  }

  /// Invoked when `play()` fires on a cold-started service that has no
  /// current item loaded (typical headphone / lock-screen tap after the OS
  /// killed the app). Registered by main.dart to delegate the restore to
  /// HomeWidgetService (which has the item-fetch + ApiService construction
  /// logic), avoiding a circular import.
  static Future<void> Function()? onColdStartPlayRequested;

  static AudioPlayerHandler? _handler;
  static AudioPlayerHandler? get handler => _handler;
  static Completer<void> _initCompleter = Completer<void>();
  AudioPlayer? get _player => _handler?.player;

  String? _currentItemId;
  String? _currentSeriesId;
  String? _currentTitle;
  String? _currentAuthor;
  String? _currentCoverUrl;
  double _totalDuration = 0;
  // The item's metadata duration as passed to playItem. _totalDuration gets
  // replaced by the playback session's track-sum once a stream opens, and the
  // two can disagree by minutes when the server's metadata is off - but the
  // in-app cards display the metadata number, so time surfaces that need to
  // match them (the iOS widget) read this instead.
  double _metaDuration = 0;
  List<dynamic> _chapters = [];
  // ── Parked-on-finish state (finish action: hold / replay) ──
  bool _finishedHeld = false;
  String _heldFinishAction = 'clear';
  String? _heldItemId;
  String? _heldSeriesId;
  String? _heldTitle;
  String? _heldAuthor;
  String? _heldCoverUrl;
  String? _heldLibraryId;
  String? _heldEpisodeId;
  String? _heldEpisodeTitle;
  double _heldTotalDuration = 0;
  List<dynamic> _heldChapters = [];
  ApiService? _api;
  ApiService? get currentApi => _api;
  String? _playbackSessionId;

  /// The server session this phone is playing on, so its own syncs echoed
  /// back over the socket can be told apart from another device's.
  String? get playbackSessionId => _playbackSessionId;

  // A source swap started by pausing. A seek waits for it: the swap reloads
  // at the spot it saw, so a seek that landed first was undone (GH #433).
  Future<void>? _pauseSwap;

  /// Phase 1.7: latest streaming URLs (with auth token already in the
  /// query string) and custom HTTP headers needed by reverse proxies like
  /// Cloudflare Access. Stashed to the iOS app group on each player update
  /// so the native widget core can keep playing if Flutter dies.
  List<String> _activeStreamUrls = const [];
  Map<String, String> _activeStreamHeaders = const {};
  List<String> get activeStreamUrls => _activeStreamUrls;
  Map<String, String> get activeStreamHeaders => _activeStreamHeaders;
  bool _isOfflineMode = false;

  /// True while the current play started from downloaded files and is reporting
  /// to the server via the client-owned LOCAL session model (GH #276/#280)
  /// instead of a live `/play` session. Position still syncs via /me/progress.
  bool _localSessionMode = false;

  /// True while a STREAMING play whose source doesn't run through a server
  /// session (manifest / cache / direct-file URLs) is credited through a
  /// client-owned local session instead of opening `/play`. The session is
  /// stamped Direct Play, so the server label matches what `/play` produced;
  /// only the multi-MB session body is avoided.
  bool _localSessionAccounting = false;

  // Set when a loadOnly playItem skipped starting the local session; the
  // first real play() begins it, so listening time still gets recorded.
  ({
    String progressKey,
    String itemId,
    String? episodeId,
    double duration,
    String title,
    String author,
    bool streamed,
  })?
  _pendingLoadOnlySession;

  /// Externally-pushed signal that the server is currently unreachable.
  /// AuthProvider mirrors `serverReachable` here on each ping result so we
  /// can short-circuit pre-play server calls (e.g. session creation) for
  /// instant offline playback - no need to wait for a network timeout to
  /// discover what the auth layer already knows. Other services
  /// (AndroidAuto/CarPlay browse) read it via [knownOffline] to skip
  /// their own server fetches.
  bool _knownOffline = false;
  bool get knownOffline => _knownOffline;

  /// Manual offline mode, mirrored from LibraryProvider so it behaves the same
  /// as a dropped connection for playback purposes.
  bool _manualOffline = false;

  /// Set when we pause a remote stream only because we went offline; cleared
  /// when the user takes over (pause/stop) so a reconnect doesn't auto-resume.
  bool _pausedForOffline = false;

  bool get _offline => _knownOffline || _manualOffline;

  /// Offline while the ACTIVE source is served over the network: every resume,
  /// chapter jump or seek would pull network bytes that offline mode must not
  /// request (GH: playing a non-cached episode, toggling offline, then still
  /// loading episodes 8/9/10 online). Note [_streamIsRemote] cannot decide
  /// this: a PARTIALLY downloaded book still has a `downloaded` record, so a
  /// streamed episode of it reads as "downloaded" and the guard would never
  /// fire. Transport actions are inert until the connection is back; the pause
  /// taken on going offline is resumed by [_onOfflineStateChanged].
  bool get _offlineRemoteStream => _offline && _sourceIsNetwork;

  /// Whether the ACTIVE audio source is served over the network (server
  /// session URLs, or direct file URLs), as opposed to local downloaded
  /// files. Set at every source setup: streaming starts true, a local play
  /// flips it false, and [_clearState] resets it. This - not
  /// [_streamIsRemote] - is what an offline guard must ask, because a
  /// partially downloaded book is both.
  bool _sourceIsNetwork = false;

  /// True while offline (manual toggle or known network loss), for UIs that
  /// need to present the player's offline state (e.g. dim non-downloaded
  /// chapters in the chapters sheet).
  bool get offlineActive => _offline;

  /// Chapter indices of the current item whose audio is actually on disk
  /// (empty when nothing is downloaded). Lets the UI highlight / dim which
  /// chapters are reachable offline.
  List<int> get downloadedChapterIndices =>
      _downloadedChapterSubset() ?? const [];

  void setKnownOffline(bool offline) {
    if (_knownOffline == offline) return;
    _knownOffline = offline;
    // Listener-driven UI (the chapter sheet's downloaded-only filter, offline
    // badges) reads offlineActive. Without this notify the sheet keeps the
    // snapshot it took while offline until the next unrelated player tick -
    // while paused, forever.
    notifyListeners();
    unawaited(_onOfflineStateChanged());
  }

  void setManualOffline(bool offline) {
    if (_manualOffline == offline) return;
    _manualOffline = offline;
    notifyListeners();
    unawaited(_onOfflineStateChanged());
  }

  /// Offline must stop a remote stream from being hammered: pause it (a
  /// downloaded book keeps playing), skip stall/retry recovery, and resume
  /// where it left off once the connection is back.
  Future<void> _onOfflineStateChanged() async {
    if (_offline) {
      if (_pausedForOffline) return;
      if (_player == null) return;
      // Network-sourced only: a downloaded book keeps playing offline. A
      // streamed episode of a PARTIALLY downloaded book counts as network
      // here — its download record exists but its audio comes from the wire.
      if (!_sourceIsNetwork) return;
      // Buffering counts as active: a stream still loading when the toggle
      // arrives must stop too, not just one already audible.
      final state = _player!.processingState;
      if (!_player!.playing &&
          state != ProcessingState.loading &&
          state != ProcessingState.buffering) {
        return;
      }
      _stuckCheckTimer?.cancel();
      _stuckCheckTimer = null;
      _resetStuckDetection();
      debugPrint('[Player] Offline - pausing remote stream');
      _logEvent(PlaybackEventType.pause, detail: 'offline');
      // Flag set after pause(): pause() clears it for any explicit user pause.
      await pause();
      _pausedForOffline = true;
    } else if (_pausedForOffline) {
      _pausedForOffline = false;
      debugPrint('[Player] Back online - resuming remote stream');
      await play();
    }
  }

  bool _isBackgrounded = false;
  bool get isBackgrounded => _isBackgrounded;
  SharedPreferences? _prefs;
  StreamSubscription? _syncSub;
  StreamSubscription? _completionSub;
  StreamSubscription? _nativeAutoAdvanceSub;

  // ── Pre-buffer next book in queue (iOS background auto-advance fix) ──
  // iOS denies background audio output to freshly-loaded AVPlayerItems.
  // Workaround: append the next book to the live ConcatenatingAudioSource
  // ~15s before current ends. AVQueuePlayer auto-advances natively, audio
  // engine stays continuous, iOS keeps granting output.
  ConcatenatingAudioSource? _activeConcatSource;
  int _currentBookTrackCount = 0;
  bool _nextBookPreloading = false;
  Map<String, dynamic>? _preloadedNextBook;
  bool _autoQueueAdvancing = false;
  Timer? _bgSaveTimer;
  Timer? _advanceBufferingBackstop;
  Timer? _pauseStopTimer;
  static const _pauseStopTimeout = Duration(minutes: 10);
  // A streamed book's cover isn't in the content-provider cache on first play,
  // so the notification's first art request races the on-demand fetch and the
  // OS caches the empty result against the fixed cover URI (loadThumbnail is a
  // one-shot per-URI operation on Android Q+). We re-push the MediaItem with a
  // cache-busting URI so the OS re-requests it after the cover has been
  // fetched. Tracks the item already scheduled for this.
  String? _coverRepushItem;
  Timer? _coverRepushTimer;
  int _coverRepushAttempt = 0;

  // Widening gaps, one campaign per item (cleared in _clearState so replaying
  // the same book gets a fresh one). A single 3s re-push was not enough: the
  // CoverContentProvider's own connect/read timeout is 5s, so on a slow link
  // the one chance could itself land inside that window, get negative-cached by
  // the OS, and leave the notification permanently blank with no further
  // attempt. Three attempts with 3s/8s/15s gaps cover the fetch comfortably.
  static const _coverRepushDelays = <int>[3, 8, 15];

  void _beginAdvanceBuffering() {
    if (!Platform.isAndroid) return;
    _handler?.setAdvanceBuffering(
      true,
      minimumDuration: const Duration(milliseconds: 900),
    );
    _advanceBufferingBackstop?.cancel();
    _advanceBufferingBackstop = Timer(const Duration(seconds: 30), () {
      _advanceBufferingBackstop = null;
      _handler?.setAdvanceBuffering(false);
    });
  }

  void _endAdvanceBuffering() {
    if (!Platform.isAndroid) return;
    _advanceBufferingBackstop?.cancel();
    _advanceBufferingBackstop = null;
    _handler?.setAdvanceBuffering(false);
  }

  /// Last known position in seconds — used to detect end→0 position jumps.
  double _lastKnownPositionSec = 0;
  // Where the latest seek was headed, a start's own seek included. A stream
  // that fails before that seek lands has no known position yet, and the
  // retry began the book again from zero.
  double? _lastSeekTargetSec;
  DateTime? _lastSeekAt;

  /// When this phone last moved the position itself: a seek, a chapter jump,
  /// a start at a chosen spot. A server position saved before then is not
  /// newer than where you are.
  DateTime? get lastSeekAt => _lastSeekAt;
  // ── Stream error retry tracking ──
  int _streamRetryCount = 0;
  static const _maxStreamRetries = 3;
  bool _retryInProgress = false;
  // ── Stuck position detection (xHE-AAC/USAC iOS seek failures) ──
  Timer? _stuckCheckTimer;
  double _stuckCheckLastPosition = -1;
  int _stuckConsecutiveCount = 0; // consecutive checks with no advancement
  int _stuckReseekAttempts = 0; // how many re-seeks we've tried
  static const _maxStuckReseekAttempts = 2;
  // ── Play verification (iOS USAC can silently fail to start after seek) ──
  Timer? _playVerifyTimer;
  // ── Multi-file track offset tracking ──
  // For ConcatenatingAudioSource, _player.position is track-relative.
  // We store cumulative start offsets so we can compute absolute book position.
  List<double> _trackStartOffsets = []; // absolute start of each track
  List<double> get trackStartOffsets => _trackStartOffsets;
  // Track-relative last position per source index, so a 401 on a file can be
  // retried on that file instead of wherever ExoPlayer auto-advanced to.
  final Map<int, double> _lastTrackPositions = {};
  bool _tokenlessUpgradeInFlight = false;
  // Duration of each tracked track, kept alongside the starts so a partial
  // download (missing files => gaps in the timeline) can still tell where a
  // track ends rather than assuming track i ends where track i+1 begins.
  List<double> _trackDurations = [];
  int _currentTrackIndex = 0;

  // When a downloaded file decodes shorter than the book's metadata duration
  // (an incomplete or corrupt download), this holds the real playable length
  // in seconds. Seeks are clamped to it, and the truncation-end position is
  // never saved over a further-along stored position. null = file looks fine.
  // GH #278: a half-downloaded book otherwise clamped every resume back to the
  // file's end (50% of the book) and saved that over the user's real progress.
  double? _shortLocalDurationSec;
  // In a 1:1 layout (one audio file per chapter) the current chapter is simply
  // the current track index — no position math, so a track flip can update the
  // title the instant it happens. For partial downloads this holds the
  // full-book chapter index of each downloaded track (local index -> chapter
  // index). Empty = not a 1:1 layout (time-based lookup stays in charge).
  List<int> _localTrackChapterIdx = const [];

  /// Full-book chapter indices that are PLAYABLE in the current local-session
  /// play. Non-empty only for a PARTIAL download (files missing): chapters
  /// whose start falls inside a downloaded track — the only subset prev/next
  /// navigation may move between. Jumping at an un-downloaded chapter start
  /// lands in a gap (dead seek) or past the local coverage end (phantom
  /// completion showing the last episode's title), so those chapters are cut
  /// from navigation while playback is limited to the download.
  List<int> _localPlayableChapterIndices = const [];

  /// Prev/next navigation subset for a PARTIAL download: the chapters whose
  /// start is covered by a downloaded track — moving only between them keeps
  /// a jump from seeking into a gap (dead seek) or past the local coverage end
  /// (phantom completion with the last episode's title). Offline - or online
  /// with no API to stream from - the subset is the only reachable content;
  /// when streaming IS available this is empty so the full book is reachable
  /// and uncovered chapters continue via streaming ([_partialJumpGate]).
  /// Empty for full plays.
  List<int> get _navPlayableChapters =>
      !_offline && _api != null ? const [] : _localPlayableChapterIndices;

  /// True when the current play is a PARTIAL download (files missing), so the
  /// local audio ends before the book does. Guards the completion path from
  /// marking a half-downloaded book as finished, and navigation from crossing
  /// into chapters that have no local audio.
  bool _isPartialLocalPlay = false;

  /// Set when playback parks at the end of a partial download's local range
  /// (natural completion, or a forward skip that would cross it). While parked,
  /// the current chapter reports the LAST downloaded chapter (the boundary is
  /// also the next chapter's start, which would otherwise show "episode 5" with
  /// no audio behind it), and play() restarts from that chapter's beginning.
  bool _parkedAtBoundary = false;
  int? _parkedBoundaryChapterIdx;

  /// Absolute end of the locally covered range (end of the last downloaded
  /// file in the full-book timeline). Non-null while [_isPartialLocalPlay];
  /// reaching it means "the download is done, the book is not".
  double? _localCoverageEndSec;

  /// Memo for [_downloadedChapterSubset]: the raw session string instance and
  /// chapter list instance last decoded. The store returns the same string
  /// until the record changes and _chapters is reassigned on any list change,
  /// so identity checks skip the whole-session jsonDecode — which otherwise
  /// runs on every position tick while the chapters sheet is open offline.
  String? _subsetMemoJson;
  List<dynamic>? _subsetMemoChapters;
  List<int>? _subsetMemo;

  /// Chapter index meant by [track] when the layout is 1:1 (one file per
  /// chapter): partial downloads via the persisted map, full books by identity
  /// (track i == chapter i). Returns null when the mapping is unknown so the
  /// position-based path stays in charge.
  int? _chapterIndexForTrack(int track) {
    if (track < 0) return null;
    if (_localTrackChapterIdx.isNotEmpty) {
      return track < _localTrackChapterIdx.length
          ? _localTrackChapterIdx[track]
          : null;
    }
    // Full-book identity: only when every chapter has its own file.
    if (_chapters.isNotEmpty &&
        _trackStartOffsets.length - 1 == _chapters.length &&
        track < _chapters.length) {
      return track;
    }
    return null;
  }

  /// In a 1:1 layout one downloaded file maps to exactly one chapter. Loads the
  /// local-track -> chapter-index map persisted by the downloader so an
  /// auto-advance can pin the correct chapter title the moment the track flips
  /// (time-based lookup would lag behind the position stream at the boundary).
  /// Leaves the map empty (fall back to position math) for non-1:1 or legacy
  /// sessions.
  void _applyTrackToChapterFromSession(Map<String, dynamic> session) {
    _localTrackChapterIdx = const [];
    if (session['tracksAreChapters'] != true) return;
    final dl = session['downloadedChapters'] as List<dynamic>?;
    if (dl == null || dl.isEmpty) return;
    _localTrackChapterIdx = [
      for (final e in dl) (e is num) ? e.toInt() : (int.tryParse('$e') ?? 0),
    ];
    debugPrint('[Player] 1:1 local->chapter map: $_localTrackChapterIdx');
  }

  // Ignore small encoder/container rounding when comparing decoded vs metadata.
  static const double _kLocalTruncationMarginSec = 60.0;
  // When seeking a multi-file book, chapter boundaries and file boundaries are
  // separate metadata timelines that drift by an arbitrary amount after many
  // files (ms rounding, trailing silence, per-file duration estimates). A jump
  // to the NEXT chapter's start can then be judged to sit back in THIS file's
  // tail — the bar pins at ~max and a few words play before the concatenating
  // source rolls over. For genuine chapter-start targets we snap to the
  // nearest FILE boundary: whichever of the containing track's start and the
  // following track's start is closer decides the track (see _seekAbsolute).
  // Ordinary in-chapter seeks never qualify because they aren't chapter starts.
  int _lastNotifiedChapterIndex = -1;
  // While set, a chapter jump has pinned the reported chapter; the position
  // watchers must not demote it until the engine position passes the chapter's
  // end (see _latchChapterJumpTarget). Cleared on any non-jump seek / load.
  int _chapterJumpLatchIndex = -1;
  int _lastChapterCheckSec = -1;
  StreamSubscription? _indexSub;

  // ── iOS premature-completion guard (GH #219) ──
  // ConcatenatingAudioSource on iOS sometimes fires ProcessingState.completed
  // when advancing to the LAST item without actually rendering its audio,
  // making books appear to "skip" the final chapter. We watch how recently
  // _currentTrackIndex flipped to the last track; if completion fires within
  // a few seconds of that advance for a substantial last track, treat it as
  // spurious and seek-resume into the last track. Capped to prevent loops
  // if recovery itself can't get the player unstuck.
  DateTime? _lastIndexAdvanceTime;
  int _iosLastTrackRecoveryAttempts = 0;
  static const _maxIosLastTrackRecoveries = 2;

  // Force one lock-screen state push after an intra-book track advance.
  bool _pendingTrackAdvanceRefresh = false;

  // ── Notification chapter progress mode ──
  bool _notifChapterMode = false;
  double _currentChapterStart = 0;
  double _currentChapterEnd = 0;
  bool get notifChapterMode => _notifChapterMode && _chapters.isNotEmpty;
  NowPlayingLayout _nowPlayingLayout = NowPlayingLayout.standard;
  String _nowPlayingLayoutJson = '';
  bool _speedAdjustedTime = true;
  // The moving parts (percent, minutes left) the media controls last showed.
  String _lastNowPlayingTicker = '-1|-1';
  String? _currentNarrator;
  String? _currentSeries;
  double get currentChapterStart => _currentChapterStart;
  double get currentChapterEnd => _currentChapterEnd;

  void _onSettingsChanged() {
    Future.wait<Object>([
      PlayerSettings.getNotificationChapterProgress(),
      PlayerSettings.getNowPlayingLayout(),
      PlayerSettings.getSpeedAdjustedTime(),
    ]).then((v) {
      final chapterMode = v[0] as bool;
      final layoutJson = v[1] as String;
      final speedAdjusted = v[2] as bool;
      final chapterModeChanged = chapterMode != _notifChapterMode;
      final textChanged =
          layoutJson != _nowPlayingLayoutJson ||
          (speedAdjusted != _speedAdjustedTime &&
              _nowPlayingLayout.uses(NowPlayingPiece.timeLeft));
      _notifChapterMode = chapterMode;
      _speedAdjustedTime = speedAdjusted;
      if (layoutJson != _nowPlayingLayoutJson) {
        _nowPlayingLayoutJson = layoutJson;
        _nowPlayingLayout = NowPlayingLayout.fromJson(layoutJson);
      }
      if (!chapterModeChanged && !textChanged) return;
      // Re-push MediaItem + PlaybackState so notification updates immediately
      if (_currentItemId != null) {
        _repushNotifiedMediaItem();
        if (chapterModeChanged) _handler?.refreshPlaybackState();
      } else if (_handler?._idleNowPlayingState == true) {
        _handler!.refreshPlaybackState();
      }
    });
    // Update cached skip amounts so notification icons stay in sync
    _syncNotifSkipCache();
    PlayerSettings.getMediaControlsSpeedBookmark().then((v) {
      if (_handler != null && v != _handler!._cachedNotifSpeedBookmark) {
        _handler!._cachedNotifSpeedBookmark = v;
        _handler!.refreshPlaybackState();
      }
    });
    PlayerSettings.getLockSeekBar().then((v) {
      if (_handler != null && v != _handler!._cachedLockSeekBar) {
        _handler!._cachedLockSeekBar = v;
        _handler!.refreshPlaybackState();
      }
    });
    if (Platform.isAndroid) {
      PlayerSettings.getDuckBriefInterruptions().then((v) async {
        if (v == _duckBriefInterruptions) return;
        final previousVolume = _volumeBeforeInterruptionDuck;
        _volumeBeforeInterruptionDuck = null;
        _clearDuckWatchdog();
        if (previousVolume != null) {
          await _player?.setVolume(previousVolume);
        }
        await _configureAudioSession();
      });
    }
  }

  static const _playerCoreChannel = MethodChannel('com.absorb.player_core');
  static const _audioServiceClientChannel = MethodChannel(
    'com.ryanheise.audio_service.client.methods',
  );

  /// Point the iOS lock screen skip buttons at [forward] / [backward] seconds.
  /// Unlike Android, iOS doesn't ask how far to skip on each press - it reads
  /// the amounts off MPRemoteCommandCenter, which audio_service writes once at
  /// startup and the native core armed with the defaults, so changing the
  /// setting never reached the lock screen. Tell both, since they write the
  /// same properties and whoever goes last wins.
  static Future<void> _pushIosSkipIntervals(int forward, int backward) async {
    try {
      await _playerCoreChannel.invokeMethod('setSkipIntervals', {
        'forward': forward,
        'backward': backward,
      });
    } catch (e) {
      debugPrint('[SkipDebug] native core setSkipIntervals failed: $e');
    }
    try {
      await _audioServiceClientChannel.invokeMethod('updateSkipIntervals', {
        'fastForwardInterval': forward * 1000,
        'rewindInterval': backward * 1000,
      });
    } catch (e) {
      debugPrint('[SkipDebug] audio_service updateSkipIntervals failed: $e');
    }
  }

  /// Refresh the notification's cached skip labels with the amounts for the
  /// current library. Called on settings changes and whenever the loaded
  /// item changes.
  void _syncNotifSkipCache() {
    final libId = _currentLibraryId;
    final fwdFuture = PlayerSettings.getEffectiveForwardSkip(libraryId: libId);
    final backFuture = PlayerSettings.getEffectiveBackSkip(libraryId: libId);
    fwdFuture.then((v) {
      debugPrint(
        '[SkipDebug] notif cache: lib=$libId fwd=${v}s (was ${_handler?._cachedForwardSkip})',
      );
      if (_handler != null && v != _handler!._cachedForwardSkip) {
        _handler!._cachedForwardSkip = v;
        _handler!.refreshPlaybackState();
      }
    });
    backFuture.then((v) {
      if (_handler != null && v != _handler!._cachedBackSkip) {
        _handler!._cachedBackSkip = v;
        _handler!.refreshPlaybackState();
      }
    });
    if (Platform.isIOS) {
      unawaited(
        Future.wait([
          fwdFuture,
          backFuture,
        ]).then((v) => _pushIosSkipIntervals(v[0], v[1])),
      );
    }
  }

  /// Fill in a missing library id for the playing item so per-library skip
  /// amounts apply outside the in-app UI too (notification, headset, home
  /// widget, Android Auto). Lean shelf items and merged-library podcast
  /// entries often arrive without one; try download metadata synchronously,
  /// then the server.
  void _resolveMissingLibraryId(String itemId, String? episodeId) {
    if (itemId.isEmpty) return;
    if (_currentLibraryId != null && _currentLibraryId!.isNotEmpty) return;
    final key = episodeId != null ? '$itemId-$episodeId' : itemId;
    final fromDownload = DownloadService().getInfo(key).libraryId;
    if (fromDownload != null && fromDownload.isNotEmpty) {
      debugPrint(
        '[SkipDebug] libraryId resolved from download metadata: $fromDownload',
      );
      _currentLibraryId = fromDownload;
      return;
    }
    final api = _api;
    if (api == null) return;
    unawaited(() async {
      try {
        final item = await api.getLibraryItem(itemId);
        final libId = item?['libraryId'] as String?;
        if (libId == null || libId.isEmpty) return;
        // Only adopt if this item is still the one playing and nothing else
        // resolved the library in the meantime (e.g. the play session).
        if (_currentItemId != itemId) return;
        if (_currentLibraryId != null && _currentLibraryId!.isNotEmpty) return;
        debugPrint('[SkipDebug] libraryId resolved from server: $libId');
        _currentLibraryId = libId;
        _syncNotifSkipCache();
        notifyListeners();
      } catch (e) {
        debugPrint('[SkipDebug] libraryId lookup failed: $e');
      }
    }());
  }

  /// The last seek target in seconds (absolute book position).
  /// UI can use this to immediately snap to the target before stream catches up.
  double? _lastSeekTargetSeconds;
  DateTime? _lastSeekTime;

  /// Latest scrub requested while a [playItem] start was still loading.
  /// The start captured its landing position before the user could drag and
  /// goes on to load the source / seek there, which would silently overwrite
  /// the request. The latest one is applied once the load finishes; the
  /// generation tag keeps a request from leaking into a different item's start.
  double? _pendingLoadSeekSec;
  int? _pendingLoadSeekGeneration;

  /// The full action behind [_pendingLoadSeekSec]. Chapter jumps keep their
  /// intro-skip / boundary-snap / chapter-pin semantics instead of degrading
  /// to a bare seek; plain scrubs leave this null and apply via [seekTo].
  Future<void> Function()? _pendingLoadSeekApply;

  /// A chapter jump made from a paused/loading player wants playback resumed
  /// after the load lands (the normal resume auto-play policy). Consumed at
  /// the end of [playItem].
  bool _pendingLoadAutoPlay = false;

  /// Play was pressed while a start was loading. The start itself will play,
  /// but a load-only start ends paused, so it is replayed at load end.
  bool _playRequestedDuringLoad = false;

  double? _pendingLoadSeekFor(int generation) =>
      _pendingLoadSeekGeneration == generation ? _pendingLoadSeekSec : null;

  /// Record a user seek while the current start is loading. All user-facing
  /// seek entry points funnel through here so the LATEST intent wins: the
  /// engine cannot accept seeks while its source is loading (the in-repo
  /// just_audio fork returns early for ProcessingState.loading), so seeking
  /// now would be silently discarded and the start would land on its own
  /// captured position (often 0 = first chapter).
  void _queueLoadSeek(
    double targetSec, {
    Future<void> Function()? apply,
    bool autoPlay = false,
  }) {
    _pendingLoadSeekSec = targetSec;
    _pendingLoadSeekGeneration = _playbackGeneration;
    _pendingLoadSeekApply = apply;
    if (autoPlay) _pendingLoadAutoPlay = true;
    _pendingStartSec = targetSec;
    _lastSeekTargetSeconds = targetSec;
    _lastSeekTime = DateTime.now();
    _lastUserSeekTime = DateTime.now();
    if (_player != null && !_player!.playing) _seekedWhilePaused = true;
    debugPrint(
      '[Service] Seek to ${targetSec.toStringAsFixed(1)}s queued — the item '
      'is still loading and would overwrite it'
      '${apply != null ? ' (chapter action)' : ''}',
    );
    notifyListeners();
  }

  void _clearPendingLoadIntent({bool clearPlayRequest = false}) {
    _pendingLoadSeekSec = null;
    _pendingLoadSeekGeneration = null;
    _pendingLoadSeekApply = null;
    _pendingLoadAutoPlay = false;
    if (clearPlayRequest) _playRequestedDuringLoad = false;
  }

  /// Keep the chapter/label on the position this start will really land on,
  /// after the near-end restart / session rewind / queued user target. A start
  /// reset to 0 must clear the old near-end target instead of pinning it.
  void _pinStartPositionForLoad(int generation, double startTime) {
    final shown = _pendingLoadSeekFor(generation) ?? startTime;
    _pendingStartSec = shown;
    if (shown > 0) {
      _lastSeekTargetSeconds = shown;
      _lastSeekTime = DateTime.now();
    } else {
      _lastSeekTargetSeconds = null;
      _lastSeekTime = null;
    }
  }

  /// Absolute start (seconds) of the item currently being loaded, captured at
  /// playItem time. While `_isLoadingNewItem` the stream position is stale
  /// (still points into the previous book), so chapter/UI resolution must use
  /// this instead of the live position.
  double _pendingStartSec = 0;

  /// Timestamp of the most recent user-initiated seek (skipForward,
  /// skipBackward, seekTo).
  /// Used to suppress chapter intro/outro auto-skip so it doesn't immediately
  /// override a deliberate user navigation (e.g. rewinding to chapter start).
  DateTime _lastUserSeekTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// When the current playback started (a user play/resume, or the engine
  /// play a load path ends with). The chapter intro/outro auto-skip holds off
  /// briefly after it so a super-short chapter isn't jumped the instant audio
  /// begins — that read as "the app started episode 2 by itself" on books
  /// whose first chapter is a few-second stub.
  DateTime? _playStartAt;

  /// The engine-level play a load path ends with. Stamps the play start so
  /// the intro/outro skip suppression window runs from here too.
  void _enginePlayAfterLoad() {
    _playStartAt = DateTime.now();
    _player!.play();
    // A start that lands inside a chapter's intro window has no boundary
    // crossing to arm the fast watch; begin it here so the first post-play
    // tick doesn't leak the opening words (self-stops when no window applies).
    if (_chapters.isNotEmpty) _startChapterSkipWatch();
  }

  // TEMP latency diagnostics helper.
  void _startTraceLog(String message) {
    final sw = _startTrace;
    if (sw == null) return;
    debugPrint('[StartTrace] ${sw.elapsedMilliseconds}ms $message');
  }

  Timer? _firstByteTimer;

  /// Latency diagnostics, quiet by design: a start that behaves prints
  /// nothing (the trace already records its cost). Only a start still waiting
  /// after [_slowStartMs] reports, once when it turns slow and once when it
  /// ends - enough to tell "the request never opened" (buffer parked at zero
  /// the whole wait) from "opened but slow" (buffer crawls) without putting
  /// four lines in every log for a 400ms start.
  static const _slowStartMs = 1200;

  void _watchFirstBytes(String stage) {
    _firstByteTimer?.cancel();
    final trace = _startTrace;
    if (trace == null) return;
    final generation = _playbackGeneration;
    final fromMs = trace.elapsedMilliseconds;
    var firstAudioAtMs = -1;
    var slowReported = false;
    var nextReportAtMs = _slowStartMs;
    _firstByteTimer = Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (generation != _playbackGeneration) {
        t.cancel();
        return;
      }
      final p = _player;
      if (p == null) {
        t.cancel();
        return;
      }
      final elapsed = trace.elapsedMilliseconds - fromMs;
      final buffered = p.bufferedPosition.inMilliseconds;
      final posMs = p.position.inMilliseconds;
      if (firstAudioAtMs < 0 && buffered > posMs + 250) firstAudioAtMs = elapsed;
      final playing = p.playing;
      if (elapsed >= nextReportAtMs) {
        slowReported = true;
        nextReportAtMs = elapsed + 2000;
        debugPrint(
          '[StartDiag] ${elapsed}ms still waiting ($stage) '
          'state=${p.processingState} buf=${buffered}ms pos=${posMs}ms',
        );
      }
      if (playing || elapsed > 15000) {
        t.cancel();
        if (!slowReported) return;
        final first = firstAudioAtMs < 0 ? 'none' : '${firstAudioAtMs}ms';
        debugPrint(
          '[StartDiag] slow start ${elapsed}ms ($stage): '
          'audio ahead at $first, buf=${buffered}ms',
        );
      }
    });
  }

  /// The chapter index of the current skip "entry". When playback crosses into
  /// a different chapter (prev/next nav, or re-entering an already-played
  /// chapter) this changes, which resets the two skip flags below so the
  /// intro/outro skip re-applies once for that new entry. Within the SAME
  /// chapter the flags stay set, so rewinding inside a chapter never re-fires.
  int? _skipEntryChapterIdx;
  bool _introSkippedThisEntry = false;
  bool _outroSkippedThisEntry = false;

  /// Fast poll (120ms) run while playback is inside the outro window. The
  /// shared position stream only evaluates the skip on a 500-1000ms cadence,
  /// so the boundary crossing could be recognized up to ~1s late (a whole
  /// period) depending on where the last tick landed - the outro jumped with
  /// a bit of the tail still audible. Polling just those last few seconds
  /// brings the worst case down to ~one poll interval.
  Timer? _chapterSkipWatchTimer;
  bool _chapterSkipWatchBusy = false;

  // TEMP latency diagnostics: remove after the start/remove investigation.
  Stopwatch? _startTrace;

  /// Pending `/play` requests owned by the current start. Closing the client
  /// aborts a stale request when the user switches books or stops.
  final Set<http.Client> _pendingSessionClients = {};
  final Set<NetBodyGate> _pendingSessionGates = {};

  /// Item GET clients owned by the current start. Without this, a start that
  /// the UI already timed out kept downloading a multi-MB item for another
  /// 10-30s and competed with the book the user actually selected.
  final Set<http.Client> _pendingStartClients = {};

  Future<Map<String, dynamic>?> _startSessionRequest({
    required ApiService api,
    required String itemId,
    String? episodeId,
    bool forceTranscode = false,
    void Function(int bytes)? onProgress,
    NetBodyGate? bodyGate,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final client = http.Client();
    _pendingSessionClients.add(client);
    if (bodyGate != null) _pendingSessionGates.add(bodyGate);
    final future = api.startPlaybackSessionCancellable(
      itemId,
      client,
      episodeId: episodeId,
      forceTranscode: forceTranscode,
      onProgress: onProgress,
      bodyGate: bodyGate,
      timeout: timeout,
    );
    return future.whenComplete(() {
      _pendingSessionClients.remove(client);
      if (bodyGate != null) {
        _pendingSessionGates.remove(bodyGate);
        bodyGate.open();
      }
      client.close();
    });
  }

  void _cancelPendingSessionClients() {
    if (_pendingSessionGates.isNotEmpty) {
      // A gated body could otherwise sit forever after its client is closed.
      for (final gate in _pendingSessionGates) {
        gate.open();
      }
      _pendingSessionGates.clear();
    }
    if (_pendingSessionClients.isEmpty) return;
    debugPrint(
      '[Player] Cancelling ${_pendingSessionClients.length} pending session '
      'request(s)',
    );
    for (final client in _pendingSessionClients) {
      client.close();
    }
    _pendingSessionClients.clear();
  }

  void _trackStartClient(http.Client client) => _pendingStartClients.add(client);

  void _releaseStartClient(http.Client client) {
    if (_pendingStartClients.remove(client)) client.close();
  }

  void _cancelStartClients() {
    if (_pendingStartClients.isEmpty) return;
    debugPrint(
      '[Player] Cancelling ${_pendingStartClients.length} pending item '
      'request(s)',
    );
    for (final client in _pendingStartClients) {
      client.close();
    }
    _pendingStartClients.clear();
  }

  /// Deliberate same-chapter rewind (prev button). [._skipEntryChapterIdx] and
  /// the skip flags live per-ITEM and get wiped by
  /// [_resetChapterSkipHandledIfNewItem] when the track swap re-keys the
  /// current episode (multi-track books), which would otherwise re-arm the
  /// intro skip and drag the landing forward again. This marker survives that
  /// reset so the arrival tick can re-assert the disarm.
  int? _disarmRewindChapterIdx;
  DateTime? _disarmRewindUntil;

  /// Snapshot of the per-book skip settings captured when the CURRENT skip
  /// entry was established. A mid-entry settings change (opening the sheet and
  /// adjusting the sliders) therefore does NOT retroactively re-evaluate the
  /// chapter already playing - otherwise someone 1:38 into a chapter who sets
  /// intro/outro skip to 10s would get their progress yanked back/forward. The
  /// new values apply from the NEXT chapter entry on.
  double _entryIntroSkip = 0;
  double _entryOutroSkip = 0;
  bool _entrySkipEnabled = false;

  /// Key (`itemId` or `itemId-episodeId`) the skip markers belong to, so they
  /// are cleared when a different item starts playing.
  String? _chapterSkipTrackedItemKey;

  /// If a seek happened recently, returns the seek target.
  /// Otherwise returns null (use the stream position).
  double? get activeSeekTarget {
    if (_lastSeekTargetSeconds == null || _lastSeekTime == null) return null;
    final elapsed = DateTime.now().difference(_lastSeekTime!).inMilliseconds;
    if (elapsed > 8000) {
      // The 8s timer alone can expire BEFORE a slow-network chapter jump
      // actually lands (the target track/file is still buffering). Dropping
      // the target then makes chapter resolution fall back to the stale
      // pre-seek position — the book's tail — which maps to the LAST
      // chapter's title. Keep the target until the stream position has truly
      // caught up (forward: reached within a small band; backward: has been
      // pulled down to it), with a generous hard cap so a dropped/aborted
      // seek still recovers to the live position instead of pinning forever.
      final pos = position.inMilliseconds / 1000.0;
      final target = _lastSeekTargetSeconds!;
      // Landed = the playhead has reached the target. The lower band allows
      // the known "seeks lands a hair before the metadata start" drift
      // (same drift `_latchChapterJumpTarget` compensates for); the upper
      // band rejects stale/bogus composite positions so we keep pinning the
      // intended chapter instead of flashing a wrong one.
      final caughtUp = pos >= target - 3.0 && pos <= target + 30.0;
      if (caughtUp || elapsed > 60000) {
        _lastSeekTargetSeconds = null;
        _lastSeekTime = null;
        // While a start is loading, its pending position is the chapter the
        // card should keep showing; zeroing it there flashed chapter 1.
        if (!_isLoadingNewItem) _pendingStartSec = 0;
        return null;
      }
      return target;
    }
    return _lastSeekTargetSeconds;
  }

  /// Clear the seek target once the stream has caught up.
  void clearSeekTarget() {
    _lastSeekTargetSeconds = null;
    _lastSeekTime = null;
  }

  /// Absolute seconds used to resolve the current chapter. While a new item
  /// is loading, the stream position is stale, so resolve against the pending
  /// start instead — otherwise the UI shows the previous/last chapter during
  /// a slow load and flickers when the real position catches up.
  double get chapterResolvePosSec {
    if (_isLoadingNewItem) return activeSeekTarget ?? _pendingStartSec;
    final t = activeSeekTarget;
    if (t != null) return t;
    final p = position.inMilliseconds / 1000.0;
    // The stream position can lag a long way behind after a slow item/seek
    // switch: a stale value from the previous book (often its tail) maps
    // past the new book's last chapter and the UI falls back to the LAST
    // chapter's title. Treat anything absurdly past the book end as "not
    // ready yet" and resolve against the pending start instead.
    if (_totalDuration > 0 && p > _totalDuration + 30.0) {
      return _pendingStartSec;
    }
    // Natural track-advance gap: for a moment after the index flips to the new
    // file, the engine can still report the OLD file's near-tail local
    // position (or the whole concatenation's tail), which composed with the
    // NEW track's offset lands just inside the book end — past the tailGuard
    // above and inside the last-chapter grace window, flashing the LAST
    // chapter's title on the card. Such a local value cannot belong to the
    // current file (it is longer than the file), so resolve against the new
    // track's absolute start instead of trusting the composition. Only when
    // the current file's own duration is known (a 0 duration means we can't
    // judge staleness and a mid-file position must not snap to the start).
    if (_trackStartOffsets.length > 1 &&
        _currentTrackIndex < _trackStartOffsets.length - 1) {
      final trackDur = _trackDurationAt(_currentTrackIndex);
      // `_player` is null only while no item is loaded, in which case this
      // branch is unreachable — but a `!` here would turn a future ordering
      // change into a red screen instead of a stale label.
      final engine = _player;
      final local = engine == null
          ? null
          : engine.position.inMilliseconds / 1000.0;
      if (trackDur > 0 && local != null && local > trackDur + 5.0) {
        return _trackStartOffsets[_currentTrackIndex];
      }
    }
    return p;
  }

  final _progressSync = ProgressSyncService();
  final _downloadService = DownloadService();
  final _history = PlaybackHistoryService();

  /// Log a playback event to history.
  void _logEvent(
    PlaybackEventType type, {
    String? detail,
    double? overridePosition,
  }) {
    if (_currentItemId == null) return;
    _history.log(
      itemId: _currentItemId!,
      type: type,
      positionSeconds: overridePosition ?? position.inMilliseconds / 1000.0,
      detail: detail,
    );
  }

  static String _formatPos(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0)
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String? get currentItemId => _currentItemId;
  String? get currentTitle => _currentTitle;
  String? get currentAuthor => _currentAuthor;
  String? get currentCoverUrl => _currentCoverUrl;
  double get totalDuration => _totalDuration;
  double get displayDuration =>
      _metaDuration > 0 ? _metaDuration : _totalDuration;
  List<dynamic> get chapters => _chapters;

  /// GH #298: how every "now playing" surface (lock screen, CarPlay, Android
  /// Auto, home widget) labels the current item — the chapter goes on the
  /// primary line and the book sits beside the author ("Author · Book").
  /// Chapterless content (podcasts, books with no chapters) keeps the
  /// book/episode on the primary line.
  static ({String title, String subtitle}) nowPlayingLabels(
    String primaryTitle,
    String author,
    String? chapter,
  ) {
    final ch = chapter?.trim() ?? '';
    if (ch.isEmpty) return (title: primaryTitle, subtitle: author);
    final a = author.trim();
    final String subtitle;
    if (a.isEmpty) {
      subtitle = primaryTitle;
    } else if (primaryTitle.isEmpty) {
      subtitle = a;
    } else {
      subtitle = '$a · $primaryTitle';
    }
    return (title: ch, subtitle: subtitle);
  }

  /// Both lines of the media controls for the current item at its current
  /// position, in the layout the user picked, so the home screen widgets
  /// read the same as the lock screen, Android Auto and CarPlay.
  ({String title, String subtitle}) get nowPlayingLines {
    final posSec = position.inMilliseconds / 1000.0;
    final chapterIndex = _chapterIndexAt(_chapters, posSec);
    return _nowPlayingLines(
      title: _currentTitle ?? '',
      author: _currentAuthor ?? '',
      chapter: chapterIndex >= 0
          ? (_chapters[chapterIndex] as Map<String, dynamic>)['title'] as String?
          : null,
      chapterIndex: chapterIndex,
      chapterCount: _chapters.length,
      posSec: posSec,
      totalDuration: totalDuration,
      narrator: _currentNarrator,
      series: _currentSeries,
    );
  }

  /// The top line of the media controls for the current item.
  String get nowPlayingTitle => nowPlayingLines.title;

  /// The second line of the media controls for the current item.
  String get nowPlayingSubtitle => nowPlayingLines.subtitle;

  /// Adopts a chapter list for the item being played, ignoring one that matches
  /// what is already loaded.
  ///
  /// Returns true when [chapters] was actually adopted, so callers can skip
  /// rebuilding their own list on the many server updates that don't touch
  /// chapters at all.
  ///
  /// Safe to call while audio is running: a held jump latch indexes into the
  /// chapter array, so swapping the array under it would re-point the current-
  /// chapter highlight at a different chapter. The latch is therefore re-derived
  /// against the incoming list whenever the chapter count changed - a pure
  /// retitle leaves index identity intact and keeps the latch as-is.
  bool adoptServerChapters(List<dynamic> chapters) {
    if (ChapterLookup.equivalent(_chapters, chapters)) return false;
    final countChanged = chapters.length != _chapters.length;
    _chapters = chapters;
    _handler?.updateChaptersQueue(chapters);
    if (countChanged && _chapterJumpLatchIndex >= 0) {
      // The latched index may no longer mean the same chapter. Re-anchor it to
      // whatever now contains the playback position, and drop it entirely if the
      // position falls outside every chapter.
      _chapterJumpLatchIndex = _resolveChapterIndex(chapterResolvePosSec) ?? -1;
    }
    notifyListeners();
    return true;
  }

  bool get hasBook => _currentItemId != null;

  /// True when a loaded item is in an active session - playing OR paused.
  /// stop() drops the engine to idle while keeping _currentItemId, so this is
  /// false for a stopped session even though [hasBook] stays true.
  bool get hasActiveSession =>
      _currentItemId != null &&
      (_player?.processingState ?? ProcessingState.idle) !=
          ProcessingState.idle;
  bool get isPlaying => _player?.playing ?? false;

  /// True while [playItem] is setting up a new audio source.
  bool _isLoadingNewItem = false;
  bool get isLoadingNewItem => _isLoadingNewItem;

  /// A [play] the service is still working through: a resume that had to
  /// rebuild the player or its dead server session first. The engine itself
  /// can report `ready` the whole time (nothing has been asked of it yet), so
  /// without this the UI shows nothing at all and the press reads as ignored.
  /// Bounded by the same cap the tap guard uses, so a wedged path can never
  /// leave a spinner up forever.
  bool get isStartInFlight {
    final since = _playInFlightSince;
    return since != null && DateTime.now().difference(since) < _playInFlightCap;
  }

  bool get isLoadingOrBuffering {
    if (_isLoadingNewItem || isStartInFlight) return true;
    final s = _player?.processingState;
    return s == ProcessingState.loading || s == ProcessingState.buffering;
  }

  bool get isOfflineMode => _isOfflineMode;
  double get volume => _player?.volume ?? 1.0;
  Future<void> setVolume(double v) async => _player?.setVolume(v);

  static const _eqChannelForDiag = MethodChannel('com.absorb.equalizer');
  static const _queueAdvancerChannel = MethodChannel(
    'com.absorb.queue_advancer',
  );
  void _resetPreBufferState() {
    _activeConcatSource = null;
    _currentBookTrackCount = 0;
    _nextBookPreloading = false;
    _preloadedNextBook = null;
    _iosResyncPending = false;
    if (Platform.isIOS) {
      _queueAdvancerChannel.invokeMethod('clear').catchError((Object e) {
        debugPrint('[QueueAdvance] clear failed: $e');
        return null;
      });
    }
  }

  void _maybePreloadNextBook() {
    if (_nextBookPreloading) return;
    if (_preloadedNextBook != null) return;
    // Never pull the next book's audio while offline (manual or dropped).
    if (_offline) return;
    if (_activeConcatSource == null) return;
    if (_currentBookTrackCount == 0) return;
    if (_totalDuration <= 0) return;
    final remaining = _totalDuration - _lastKnownPositionSec;
    if (remaining <= 0 || remaining > 15) return;
    if (_currentItemId == null) return;
    final cb = _onPeekNextItemCallback;
    if (cb == null) return;

    _nextBookPreloading = true;
    final currentId = _currentEpisodeId != null
        ? '$_currentItemId-$_currentEpisodeId'
        : _currentItemId!;
    unawaited(_preloadNextBookAsync(cb, currentId));
  }

  Future<void> _preloadNextBookAsync(
    Future<Map<String, dynamic>?> Function(String) cb,
    String currentId,
  ) async {
    try {
      final next = await cb(currentId);
      if (next == null) {
        debugPrint('[PreBuffer] No next item to preload');
        return;
      }
      final nextItemId = next['itemId'] as String?;
      if (nextItemId == null) {
        debugPrint('[PreBuffer] Next item has no itemId');
        return;
      }
      // Resolve the next book's resume position once and stash it on the map
      // so commitAdvance, Now Playing, and _onAutoQueueAdvanced all agree.
      double startS = 0;
      final progressKey = next['episodeId'] != null
          ? '$nextItemId-${next['episodeId']}'
          : nextItemId;
      double localS = 0;
      final saved = await _progressSync.getLocal(progressKey);
      if (saved != null && !(saved['isFinished'] as bool? ?? false)) {
        localS = (saved['currentTime'] as num?)?.toDouble() ?? 0;
      }
      startS = localS;
      // Local storage can be empty or behind when the progress lives on the
      // server (another device, fresh install). Server-ahead wins, same as
      // the playItem position pick.
      double serverS = 0;
      if (_api != null && !_isOfflineMode) {
        try {
          final server = await _api!
              .getItemProgress(progressKey)
              .timeout(const Duration(seconds: 5), onTimeout: () => null);
          final serverTime = (server?['currentTime'] as num?)?.toDouble() ?? 0;
          final serverFinished = server?['isFinished'] as bool? ?? false;
          if (!serverFinished) serverS = serverTime;
          if (serverS > startS) startS = serverS;
        } catch (_) {}
      }
      debugPrint(
        '[PreBuffer] Resume pick for $progressKey: '
        'local=${localS.toStringAsFixed(1)}s server=${serverS.toStringAsFixed(1)}s '
        '-> start=${startS.toStringAsFixed(1)}s',
      );
      // Pre-jump the next item's intro before any audio starts. The live skip
      // only runs after the first position event (500-1000ms in background),
      // so the opening words leaked out before it fired. Folding the same
      // per-item intro setting into the pre-play start seek means the seek
      // that already happens before play() lands past the intro, with no
      // extra audio and no change to the outro behaviour.
      final nextChapters = (next['chapters'] as List<dynamic>?) ?? const [];
      if (nextChapters.isNotEmpty) {
        final skip = await ChapterSkipSettings.loadForItem(progressKey);
        if (skip.enabled && skip.introSkipSeconds > 0) {
          final chapterStart = ChapterLookup.metaStart(nextChapters, 0);
          final chapterEnd = nextChapters.length > 1
              ? ChapterLookup.metaStart(nextChapters, 1)
              : (next['duration'] as num?)?.toDouble() ?? 0.0;
          final target = chapterStart + skip.introSkipSeconds.toDouble();
          if (startS >= chapterStart &&
              startS < target &&
              chapterEnd - target >= 1.0) {
            debugPrint(
              '[ChapterSkip] Pre-jump next item intro: '
              '${startS.toStringAsFixed(1)}s -> ${target.toStringAsFixed(1)}s',
            );
            startS = target;
          }
        }
      }
      next['startS'] = startS;

      // Build audio source for the next item.
      final localPaths = (next['localPaths'] as List<dynamic>?)?.cast<String>();
      final audioTracks = next['audioTracks'] as List<dynamic>?;
      final audioHeaders = next['audioHeaders'] as Map<String, String>?;

      List<AudioSource>? nextTrackSources;
      if (localPaths != null && localPaths.isNotEmpty) {
        nextTrackSources = localPaths.map((p) => localAudioSource(p)).toList();
      } else if (audioTracks != null && audioTracks.isNotEmpty) {
        nextTrackSources = audioTracks
            .map(
              (t) =>
                  AudioSource.uri(
                        Uri.parse((t as Map<String, dynamic>)['url'] as String),
                        headers: audioHeaders,
                        options: mp3ExtractorOptions(),
                      )
                      as AudioSource,
            )
            .toList();
      }
      if (nextTrackSources == null || nextTrackSources.isEmpty) {
        debugPrint('[PreBuffer] No playable sources for next item');
        return;
      }
      if (nextTrackSources.length != 1) {
        debugPrint(
          '[PreBuffer] Next item is multi-track, skipping (MVP supports single-track only)',
        );
        return;
      }

      if (Platform.isIOS) {
        // Native engine owns the cross-book swap. Skip concat.add entirely.
        final source = nextTrackSources.length == 1
            ? nextTrackSources.first
            : ConcatenatingAudioSource(children: nextTrackSources);
        final ok = await _player!.setNextSource(
          source,
          startPositionS: startS,
          totalDurationS: (next['duration'] as num?)?.toDouble() ?? 0,
          itemId: nextItemId,
        );
        if (!ok) {
          debugPrint('[PreBuffer] Native setNextSource failed');
          return;
        }
        _preloadedNextBook = next;
        debugPrint(
          '[PreBuffer] Pre-loaded native: ${next['title']} ($nextItemId) start=${startS.toStringAsFixed(1)}s',
        );
        return;
      }

      final concat = _activeConcatSource;
      if (concat == null) {
        debugPrint('[PreBuffer] Concat source went away mid-preload');
        return;
      }
      for (final s in nextTrackSources) {
        await concat.add(s);
      }
      _preloadedNextBook = next;
      debugPrint(
        '[PreBuffer] Pre-loaded next item: ${next['title']} ($nextItemId) '
        'start=${startS.toStringAsFixed(1)}s',
      );

      if (Platform.isIOS) {
        // Legacy native queue advancer kick (flag-off path).
        unawaited(
          _primeNativeQueueAdvancer(
            next,
            localPaths,
            audioTracks,
            audioHeaders,
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[PreBuffer] Failed: $e\n$st');
    }
    // _nextBookPreloading stays true regardless of outcome — single attempt per
    // play session. Reset happens in _resetPreBufferState on the next playItem.
  }

  Future<bool> _primeNativeQueueAdvancer(
    Map<String, dynamic> next,
    List<String>? localPaths,
    List<dynamic>? audioTracks,
    Map<String, String>? audioHeaders,
  ) async {
    try {
      String? url;
      bool isLocal = false;
      if (localPaths != null && localPaths.isNotEmpty) {
        url = localPaths.first;
        isLocal = true;
      } else if (audioTracks != null && audioTracks.isNotEmpty) {
        url = (audioTracks.first as Map<String, dynamic>)['url'] as String?;
      }
      if (url == null || url.isEmpty) return false;

      String? coverPath;
      final itemId = next['itemId'] as String?;
      if (itemId != null) {
        final local = DownloadService().getInfo(itemId).localCoverPath;
        if (local != null && local.isNotEmpty) coverPath = local;
      }

      final startS = (next['startS'] as num?)?.toDouble() ?? 0;

      // Label the pre-buffered next book like the lock screen: the same
      // layout, at its resume point.
      final nextTitle = (next['title'] as String?) ?? '';
      final nextChapters = (next['chapters'] as List<dynamic>?) ?? const [];
      final nextChapterIndex = _chapterIndexAt(nextChapters, startS);
      final nextLabels = _nowPlayingLines(
        title: nextTitle,
        author: (next['author'] as String?) ?? '',
        chapter: nextChapterIndex >= 0
            ? (nextChapters[nextChapterIndex] as Map<String, dynamic>)['title']
                  as String?
            : null,
        chapterIndex: nextChapterIndex,
        chapterCount: nextChapters.length,
        posSec: startS,
        totalDuration: (next['duration'] as num?)?.toDouble() ?? 0,
      );

      final ok = await _queueAdvancerChannel.invokeMethod<bool>('prepareNext', {
        'url': url,
        'isLocal': isLocal,
        'headers': audioHeaders ?? <String, String>{},
        'title': nextLabels.title,
        'artist': nextLabels.subtitle,
        'album': nextTitle,
        'durationS': (next['duration'] as num?)?.toDouble() ?? 0,
        'coverPath': coverPath,
        'startS': startS,
      });
      debugPrint('[PreBuffer] native prepareNext returned $ok');
      return ok ?? false;
    } catch (e) {
      debugPrint('[PreBuffer] native prepareNext failed: $e');
      return false;
    }
  }

  void _onAutoQueueAdvanced() {
    final next = _preloadedNextBook;
    if (next == null) return;
    if (_autoQueueAdvancing) return;
    // A stream retry in flight is not a finished book. Advancing here is what
    // made a stalled episode restart the queue from the next title. Only the
    // retry flag is checked: iOS native auto-advance legitimately runs while
    // the next item is loading, so blocking on the load flag would drop it.
    if (_retryInProgress) return;
    // Book finished and the queue is advancing to the next title. Fire the
    // optional cue only when the user opted into reminding during auto-advance.
    unawaited(BookFinishReminder.instance.fire(onAutoAdvance: true));
    _autoQueueAdvancing = true;
    _beginAdvanceBuffering();
    debugPrint('[PreBuffer] Auto-queue advanced to the next chapter');
    final oldTrackCount = _currentBookTrackCount;

    final oldItemId = _currentItemId;
    final oldEpisodeId = _currentEpisodeId;
    final oldKey = oldEpisodeId != null
        ? '$oldItemId-$oldEpisodeId'
        : oldItemId;

    // Promote next book's metadata to current state
    _currentItemId = next['itemId'] as String?;
    _currentSeriesId = next['seriesId'] as String?;
    _currentEpisodeId = next['episodeId'] as String?;
    _currentLibraryId = next['libraryId'] as String?;
    _resolveMissingLibraryId(_currentItemId ?? '', _currentEpisodeId);
    _syncNotifSkipCache();
    _currentTitle = next['title'] as String?;
    _currentAuthor = next['author'] as String?;
    _currentNarrator = null;
    _currentSeries = null;
    _currentCoverUrl = next['coverUrl'] as String?;
    _totalDuration = (next['duration'] as num?)?.toDouble() ?? 0;
    _metaDuration = _totalDuration;
    _chapters = (next['chapters'] as List<dynamic>?) ?? [];
    _handler?.updateChaptersQueue(_chapters);
    _trackStartOffsets = [0.0, _totalDuration];
    _trackDurations = [_totalDuration];
    _currentTrackIndex = 0;
    _playbackSessionId = null;
    final startS = (next['startS'] as num?)?.toDouble() ?? 0;
    _lastKnownPositionSec = startS;
    final newKey = _currentEpisodeId != null
        ? '$_currentItemId-$_currentEpisodeId'
        : _currentItemId;
    debugPrint(
      '[PreBuffer] Promoted $oldKey -> $newKey start=${startS.toStringAsFixed(1)}s',
    );
    _lastNotifiedChapterIndex = -1;
    _currentBookTrackCount = 1;
    _preloadedNextBook = null;
    _nextBookPreloading = false;

    // Push new media item to update Now Playing / lock screen
    final initChapter = _initChapterInfo(startS);
    _pushMediaItem(
      _currentItemId!,
      _currentTitle ?? '',
      _currentAuthor ?? '',
      _currentCoverUrl,
      _totalDuration,
      chapter: initChapter,
    );
    unawaited(
      _primeNowPlaying(
        title: _currentTitle ?? '',
        artist: _currentAuthor ?? '',
        duration: _totalDuration,
        elapsed: startS,
        chapter: initChapter,
      ),
    );

    if (Platform.isIOS) {
      unawaited(_iosAutoAdvanceKick());
    } else {
      unawaited(_finalizeAndroidAutoAdvance(oldTrackCount, startS));
    }

    // Notify LibraryProvider via auto-queue-specific callback (skipAutoAdvance
    // inside markFinishedLocally — next item is already playing, no playItem).
    if (oldKey != null) {
      final cb = _onAutoQueueAdvancedCallback;
      if (cb != null) cb(oldKey);
    }
    if (oldItemId != null && oldEpisodeId == null) {
      unawaited(ReviewService.onBookFinished(isForeground: !_isBackgrounded));
    }

    notifyListeners();
    _autoQueueAdvancing = false;
  }

  /// ExoPlayer walks into the pre-buffered book at position 0 with the
  /// finished item's tracks still in front of it in the concat, so absolute
  /// seeks map into the dead item (and clamp at its end) and the saved resume
  /// position is never applied. Drop the old tracks so the book becomes
  /// index 0, restore single-file offsets, and jump to where the user left it.
  Future<void> _finalizeAndroidAutoAdvance(
    int oldTrackCount,
    double startS,
  ) async {
    try {
      final concat = _activeConcatSource;
      if (concat != null &&
          oldTrackCount > 0 &&
          concat.length > oldTrackCount) {
        await concat.removeRange(0, oldTrackCount);
        debugPrint(
          '[PreBuffer] Dropped $oldTrackCount finished track(s); concat now ${concat.length}',
        );
      }
      _trackStartOffsets = [0.0];
      _trackDurations = [];
      _currentTrackIndex = 0;
      if (startS > 0) {
        await _seekAbsolute(startS);
        clearSeekTarget();
        debugPrint(
          '[PreBuffer] Resumed advanced book at ${startS.toStringAsFixed(1)}s',
        );
      }
    } catch (e) {
      debugPrint('[PreBuffer] Android advance finalize failed: $e');
    }
  }

  // Set when native commitAdvance swaps in a foreign AVPlayerItem. just_audio
  // sees _index = -1 from then on; we need to rebuild its source the next
  // time the app is foregrounded so position and pause work normally.
  bool _iosResyncPending = false;

  Future<void> _iosAutoAdvanceKick() async {
    final speed = _player?.speed ?? 1.0;
    try {
      await (await AudioSession.instance).setActive(true);
    } catch (e) {
      debugPrint('[QueueAdvance] setActive failed: $e');
    }
    if (_isBackgrounded) {
      try {
        final ok = await _queueAdvancerChannel.invokeMethod<bool>(
          'commitAdvance',
          {'speed': speed},
        );
        if (ok == true) {
          _iosResyncPending = true;
          debugPrint('[QueueAdvance] native commit succeeded, resync armed');
        }
      } catch (e) {
        debugPrint('[QueueAdvance] commitAdvance failed: $e');
      }
    }
    try {
      await _player?.setSpeed(speed);
    } catch (e) {
      debugPrint('[QueueAdvance] setSpeed kick failed: $e');
    }
    Future.delayed(const Duration(milliseconds: 300), () {
      _handler?.refreshPlaybackState();
    });
  }

  Future<void> _iosForegroundResyncIfNeeded() async {
    if (!_iosResyncPending) return;
    _iosResyncPending = false;
    final itemId = _currentItemId;
    final api = _api;
    if (itemId == null || api == null) {
      debugPrint('[QueueAdvance] resync: missing item or api, skipping');
      return;
    }
    double startS = 0;
    try {
      final pos = await _queueAdvancerChannel.invokeMethod<double>(
        'getPositionS',
      );
      if (pos != null && pos > 0) startS = pos;
    } catch (e) {
      debugPrint('[QueueAdvance] getPositionS failed: $e');
    }
    debugPrint(
      '[QueueAdvance] Resyncing just_audio for $itemId at ${startS.toStringAsFixed(1)}s',
    );
    try {
      await playItem(
        api: api,
        itemId: itemId,
        title: _currentTitle ?? '',
        author: _currentAuthor ?? '',
        coverUrl: _currentCoverUrl,
        totalDuration: _totalDuration,
        chapters: _chapters,
        startTime: startS,
        forceStartTime: true,
        episodeId: _currentEpisodeId,
        libraryId: _currentLibraryId,
        seriesId: _currentSeriesId,
      );
    } catch (e) {
      debugPrint('[QueueAdvance] resync playItem failed: $e');
    }
  }

  /// iOS: re-take the Now Playing claim after something may have knocked it
  /// out while paused - a stretch suspended in the background where an
  /// interruption came and went unseen, the user opening another app that
  /// played something, or the headphones being stowed. iOS deactivates the
  /// session for the interrupter, and a paused app that never re-activates
  /// quietly falls out of Now Playing candidacy: the next headset press then
  /// goes to Apple Music instead.
  ///
  /// Deliberately NOT called when an interruption ends while paused. Plenty
  /// of apps deactivate their session on pause, which arrives here as an
  /// interruption ending, and claiming at that moment would take the headset
  /// away from the app the user just paused. The foreground and
  /// route-disconnect calls pick the claim back up the next time the user
  /// comes back to Absorb.
  ///
  /// Re-activating and republishing metadata is NOT enough on its own. iOS
  /// only hands the slot to an app that has actually rendered audio, which is
  /// what build 249 got wrong and 251 fixed with a silent blip - so the claim
  /// goes through the native primer rather than being done here. Doing it in
  /// Dart looked like it worked, because setActive succeeds either way.
  ///
  /// Only runs when nothing else is audibly playing: the claim matters
  /// exactly when the next press should reach this app, and grabbing it out
  /// from under an app mid-playback would be rude. The primer re-checks that
  /// and activates the session itself, so nothing is activated from Dart and
  /// the guard and the activation stay together with no gap between them.
  Future<void> reassertIosClaimWhilePaused(String reason) async {
    if (!Platform.isIOS || !hasBook || isPlaying) return;
    try {
      final info = await _eqChannelForDiag.invokeMethod<Map<dynamic, dynamic>>(
        'getAudioDiagnostics',
      );
      if (info?['isOtherAudioPlaying'] == true ||
          info?['secondaryAudioShouldBeSilencedHint'] == true) {
        debugPrint(
          '[AudioSession] claim reassert skipped ($reason) - other audio is playing',
        );
        return;
      }
      // Publish this book before the blip, so the slot we take back shows the
      // right title rather than whatever the app that stole it left behind.
      _handler?.refreshPlaybackState();
      final started = await _eqChannelForDiag.invokeMethod<bool>(
        'reclaimNowPlaying',
        {'reason': reason},
      );
      debugPrint(
        '[AudioSession] claim reassert ($reason): blip started=$started',
      );
    } catch (e) {
      debugPrint('[AudioSession] claim reassert failed ($reason): $e');
    }
  }

  /// iOS: a headset press can cold-launch the app into the background with
  /// the native core already driving the shared engine (its remote commands
  /// arm at app launch). Dart then boots with no book loaded, so
  /// audio_service publishes a blank Now Playing over the native core's and
  /// every later press defers to a player that knows nothing - the lock
  /// screen shows audio running with no title, cover or progress. Adopt
  /// instead: restore the last-played item at the engine's own live position,
  /// which re-publishes full metadata and puts Dart in charge of the audio
  /// that is already running. Called once from main.dart after init.
  Future<void> adoptBackgroundEngineIfRunning() async {
    if (!Platform.isIOS) return;
    if (_currentItemId != null) return;
    final player = _player;
    if (player == null) return;
    try {
      var state = await player.engineState();
      // A press-launched process races this check twice over: Dart init can
      // get here before the native core has even LOADED the engine (a field
      // log had this check lose by two milliseconds), and a stream then
      // buffers for a while before isPlaying flips. Deciding on the first
      // read left Dart bookless under live audio. So poll: a press-loaded
      // engine shows up within the first second, and once it is loaded, give
      // the buffer the rest of the budget. On a normal launch nothing ever
      // loads and this waits out the budget then does nothing - harmless,
      // since the primer has the lock screen and the command center routes
      // any early press to the cold-start restore.
      var waited = 0;
      while ((state == null || !state.isLoaded || !state.isPlaying) &&
          waited < 4000) {
        await Future.delayed(const Duration(milliseconds: 500));
        waited += 500;
        // Dart started something itself while this waited - a card tap, a
        // CarPlay autoplay, a headset press routed through the handler. That
        // is Dart's own playback, not an orphaned engine: the restore below
        // is the play/pause toggle, and calling it now would pause it.
        if (_currentItemId != null) return;
        state = await player.engineState();
      }
      if (_currentItemId != null) return;
      if (state != null && state.isLoaded && state.isPlaying) {
        // Guard: only auto-adopt if the user was actually playing when the app
        // was last alive. If they paused right before the OS killed us, the
        // native engine / MediaSession may still report "playing" — resuming
        // audio on their behalf would be a phantom resume.
        final bootPrefs = await SharedPreferences.getInstance();
        final userWasPlaying =
            bootPrefs.getBool('last_user_was_playing') ?? true;
        if (!userWasPlaying) {
          debugPrint(
            '[Player] boot: native engine reports playing but last_user_was_playing=false - not adopting (user had paused)',
          );
          return;
        }
        debugPrint(
          '[Player] boot: native engine already playing at '
          '${state.globalPositionS.toStringAsFixed(1)}s with no book loaded - adopting'
          '${waited > 0 ? " (waited ${waited}ms for the stream to start)" : ""}',
        );
        if (state.globalPositionS > 0) {
          await HomeWidgetService().stashLivePosition(state.globalPositionS);
        }
        final restore = AudioPlayerService.onColdStartPlayRequested;
        if (restore != null) await restore();
        return;
      }
      // Idle engine: leave the player empty. The book only loads when the
      // user actually plays - an early headset press still works because the
      // handler routes play-with-nothing-loaded to the cold-start restore.
      // (This used to load the last played book paused as a press target,
      // which put an unasked-for book in the player on every launch.)
    } catch (e) {
      debugPrint('[Player] boot engine adopt failed: $e');
    }
  }

  /// iOS foreground reconciliation after a possible widget-driven session.
  ///
  /// The shared engine (AbsorbAudioEngine) persists across Flutter suspension,
  /// so when the user tapped the widget while we were suspended the engine kept
  /// playing the same book. On resume we must NOT reload it - that restarts the
  /// stream. Instead, if the engine is still on our current book, adopt its
  /// playing-state, track index, and global position. If the engine has been
  /// stopped or holds a different book, leave the existing paths to handle it
  /// (the idle-on-resume re-init in play(), or a fresh playItem).
  Future<void> _iosReconcileEngineOnForeground() async {
    if (!Platform.isIOS) return;
    final player = _player;
    final itemId = _currentItemId;
    if (player == null || itemId == null) return;
    final state = await player.engineState();
    if (state == null) return;
    // Engine isn't on our book (stopped, disposed, or swapped) - nothing to
    // adopt; the normal play()/idle-reinit path will rebuild if needed.
    if (!state.isLoaded || state.itemId != itemId) {
      debugPrint(
        '[Player] iOS resume: engine not on current book '
        '(engine=${state.itemId} loaded=${state.isLoaded}) - skipping adopt',
      );
      return;
    }
    // Sync our track index to whatever track the engine actually reached while
    // we were suspended, so absolute-position math is correct.
    if (_trackStartOffsets.length > 1) {
      final clamped = state.trackIndex.clamp(0, _trackStartOffsets.length - 2);
      if (clamped != _currentTrackIndex) {
        debugPrint(
          '[Player] iOS resume: track index $_currentTrackIndex -> $clamped (from engine)',
        );
        _currentTrackIndex = clamped;
      }
    }
    // Adopt the engine's playing-state without issuing a new command, then let
    // the handler re-publish so the lock screen / notification reflect reality.
    final wasPlaying = isPlaying;
    player.adoptPlayingState(state.isPlaying);
    debugPrint(
      '[Player] iOS resume: adopted engine state playing=${state.isPlaying} '
      '(was $wasPlaying) global=${state.globalPositionS.toStringAsFixed(1)}s',
    );
    // Persist the adopted position only when the engine actually moved on
    // while Flutter was suspended (a widget or lock screen session), so a
    // later save can't overwrite it with a stale value. A paused engine
    // sitting where Dart left it has nothing new to say: saving it anyway
    // re-stamped a stale position as fresh on every foreground, which blocked
    // pulling another device's newer progress and, after a session-start
    // rewind, pushed the server a few seconds backwards per relaunch.
    if (state.globalPositionS > _lastKnownPositionSec + 1.0) {
      _lastKnownPositionSec = state.globalPositionS;
      await _saveProgressLocal(
        Duration(milliseconds: (state.globalPositionS * 1000).round()),
      );
    }
    // The engine may have crossed chapters while Dart was suspended (a widget
    // or headset session driven by the native core). Chapter detection runs
    // off position ticks and a paused engine emits none, so the lock screen
    // kept the old chapter clamped at its end with no progress while the book
    // was chapters ahead. Work out the chapter for the adopted position and
    // republish.
    // Use this service's own position, which adds the track offset: when Dart
    // drives the engine one track at a time, the engine's "global" position is
    // the position within the current track (160s into track 25, not 11026s
    // into the book), and the chapter for that number is the wrong one.
    final adoptedItemId = _currentItemId;
    if (adoptedItemId != null) {
      final chapterTitle = _initChapterInfo(position.inMilliseconds / 1000.0);
      _pushMediaItem(
        adoptedItemId,
        _currentTitle ?? '',
        _currentAuthor ?? '',
        _currentCoverUrl,
        _totalDuration,
        chapter: chapterTitle,
      );
    }
    _handler?.refreshPlaybackState();
    notifyListeners();
  }

  Future<void> _primeNowPlaying({
    required String title,
    required String artist,
    required double duration,
    required double elapsed,
    String? chapter,
  }) async {
    if (!Platform.isIOS) return;
    // Match the lock screen, which uses the same layout.
    final labels = _nowPlayingLines(
      title: title,
      author: artist,
      chapter: chapter,
      chapterIndex: chapter == null ? -1 : _lastNotifiedChapterIndex,
      chapterCount: _chapters.length,
      posSec: elapsed,
      totalDuration: duration,
      narrator: _currentNarrator,
      series: _currentSeries,
    );
    try {
      await _eqChannelForDiag.invokeMethod('primeNowPlaying', {
        'title': labels.title,
        'artist': labels.subtitle,
        'album': title,
        'duration': duration,
        'elapsed': elapsed,
      });
      debugPrint(
        '[Player] primeNowPlaying title="${labels.title}" elapsed=${elapsed.toStringAsFixed(1)}',
      );
    } catch (e) {
      debugPrint('[Player] primeNowPlaying failed: $e');
    }
  }

  /// Diagnostic snapshot for the "tap play, no sound" issue. Logs both
  /// just_audio player state AND iOS AVAudioSession route/volume info so
  /// we can tell apart "player thinks it's playing but no audio reaches
  /// speakers" from "player is buffering forever" from "wrong output
  /// route" etc.
  /// The system's record of how the last process ended, for deaths the log
  /// itself cannot see coming.
  static Future<void> _reportPreviousExit() async {
    final snap = await AudioPlayerHandler._absorbDiagSnapshot();
    final info = snap?['lastExit'];
    if (info != null) debugPrint('[Init] Previous process exit: $info');
  }

  Future<void> _logAudioDiagnostics(String stage) async {
    try {
      final p = _player;
      final pos = p?.position;
      final dur = p?.duration;
      final buffered = p?.bufferedPosition;
      final pieces = <String>[
        'stage=$stage',
        'playing=${p?.playing}',
        'state=${p?.processingState.name}',
        'volume=${p?.volume.toStringAsFixed(2)}',
        'speed=${p?.speed.toStringAsFixed(2)}',
        'pos=${pos != null ? "${(pos.inMilliseconds / 1000.0).toStringAsFixed(1)}s" : "null"}',
        'dur=${dur != null ? "${(dur.inMilliseconds / 1000.0).toStringAsFixed(1)}s" : "null"}',
        'buf=${buffered != null ? "${(buffered.inMilliseconds / 1000.0).toStringAsFixed(1)}s" : "null"}',
        'item=$_currentItemId',
        'ep=$_currentEpisodeId',
      ];

      if (Platform.isAndroid) {
        // Which output the sound is actually leaving through. A player that
        // advances with nothing audible and a Bluetooth route here means the
        // audio went to a device the listener was not wearing.
        final snap = await AudioPlayerHandler._absorbDiagSnapshot();
        if (snap != null) {
          pieces.add('route=[${snap['route']}]');
          pieces.add(
            'outputs=[${AudioPlayerHandler._compactOutputs(snap['outputs'])}]',
          );
          pieces.add('musicVol=${snap['musicVolume']}');
        }
      }

      if (Platform.isIOS) {
        try {
          final info = await _eqChannelForDiag
              .invokeMethod<Map<dynamic, dynamic>>('getAudioDiagnostics');
          if (info != null) {
            final outputs =
                (info['outputs'] as List?)
                    ?.map((o) => '${(o as Map)["type"]}:${o["name"]}')
                    .join(',') ??
                '?';
            pieces.addAll([
              'ios.cat=${info["category"]}',
              'ios.mode=${info["mode"]}',
              'ios.policy=${info["routeSharingPolicy"]}',
              'ios.outVol=${info["outputVolume"]}',
              'ios.otherAudio=${info["isOtherAudioPlaying"]}',
              'ios.silenceHint=${info["secondaryAudioShouldBeSilencedHint"]}',
              'ios.route=[$outputs]',
              'ios.sampleRate=${info["sampleRate"]}',
              'ios.npHasInfo=${info["nowPlayingHasInfo"]}',
              'ios.npTitle="${info["nowPlayingTitle"]}"',
              'ios.npRate=${info["nowPlayingRate"]}',
              'ios.npElapsed=${info["nowPlayingElapsed"]}',
            ]);
          }
        } catch (e) {
          pieces.add('ios.err=$e');
        }
      }

      debugPrint('[AudioDiag] ${pieces.join(' ')}');
    } catch (e) {
      debugPrint('[AudioDiag] log failed: $e');
    }
  }

  /// Schedule a sequence of diagnostic snapshots after starting playback so
  /// we can see whether state advanced as expected ("playing then
  /// position-stuck-at-0" is a classic no-sound fingerprint).
  void _scheduleAudioDiagnostics(String startStage) {
    _logAudioDiagnostics('$startStage:t0');
    Future.delayed(
      const Duration(seconds: 1),
      () => _logAudioDiagnostics('$startStage:t1s'),
    );
    Future.delayed(
      const Duration(seconds: 3),
      () => _logAudioDiagnostics('$startStage:t3s'),
    );
    Future.delayed(
      const Duration(seconds: 10),
      () => _logAudioDiagnostics('$startStage:t10s'),
    );
  }

  Stream<Duration> get positionStream =>
      _player?.positionStream ?? const Stream.empty();
  Stream<Duration?> get durationStream =>
      _player?.durationStream ?? const Stream.empty();
  Stream<PlayerState> get playerStateStream =>
      _player?.playerStateStream ?? const Stream.empty();

  /// Absolute book position (accounts for multi-file track offsets).
  Duration get position {
    if (_player == null) return Duration.zero;
    // While swapping to a new item, return the pending start so the UI
    // doesn't flash stale progress from the previous book (also covers
    // startTime 0, where the old seek-target branch left position stale).
    if (_isLoadingNewItem) {
      return Duration(milliseconds: (_pendingStartSec * 1000).round());
    }
    final held = _heldPausedSpot;
    if (held != null) return Duration(milliseconds: (held * 1000).round());
    final trackRelative = _player!.position;
    if (_trackStartOffsets.length <= 1) return trackRelative; // single file
    final offsetMs = (_trackStartOffsets[_currentTrackIndex] * 1000).round();
    final result = trackRelative + Duration(milliseconds: offsetMs);
    // Don't log every call — this is called very frequently by sync and UI
    return result;
  }

  /// Absolute book position stream (adjusted for multi-file offsets).
  /// IMPORTANT: Always returns a mapped stream that checks offsets at event time.
  /// Do NOT short-circuit to raw positionStream — the caller may subscribe before
  /// track offsets are built, and would miss the offset transform forever.
  Stream<Duration> get absolutePositionStream {
    if (_player == null) return const Stream.empty();
    return _player!.positionStream.map((trackRelative) {
      if (_trackStartOffsets.length <= 1)
        return trackRelative; // single file, no offset
      final trackIdx = _currentTrackIndex;
      final offsetMs = (_trackStartOffsets[trackIdx] * 1000).round();
      final absolute = trackRelative + Duration(milliseconds: offsetMs);
      return absolute;
    });
  }

  Duration get duration => _player?.duration ?? Duration.zero;
  double get speed => _player?.speed ?? 1.0;

  /// Build track start offsets from audioTracks list.
  ///
  /// [absoluteStarts], when supplied and length-matched, gives each track's
  /// offset in the full book timeline (used for partial downloads, where the
  /// present files are not contiguous). Otherwise offsets are cumulative from 0.
  ///
  /// Durations deliberately come from the SERVER's per-track values and are
  /// never reconciled against the engine's estimates: Audiobookshelf derives
  /// the chapter starts from the SAME per-track durations, so this timeline
  /// is self-consistent with the chapter metadata. Mixing in the engine's
  /// bitrate-based estimates (VBR MP3 without a Xing header) moved chapter
  /// boundaries relative to the real audio — "the last seconds of episode 59
  /// played episode 60's opening".
  void _buildTrackOffsets(
    List<dynamic> audioTracks, {
    List<double>? absoluteStarts,
  }) {
    _lastSourceTracks = audioTracks;
    _trackDurations = [
      for (final t in audioTracks)
        ((t as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0,
    ];
    if (absoluteStarts != null && absoluteStarts.length == audioTracks.length) {
      _trackStartOffsets = [...absoluteStarts];
    } else {
      _trackStartOffsets = [];
      double acc = 0;
      for (final d in _trackDurations) {
        _trackStartOffsets.add(acc);
        acc += d;
      }
    }
    // Sentinel = end of the last track, so `.last` still means "timeline end"
    // for the contiguous case and callers reading the final element.
    _trackStartOffsets.add(
      _trackStartOffsets.isEmpty
          ? 0.0
          : _trackStartOffsets.last + _trackDurations.last,
    );
    // A thousand-file book made this line ~10 KB per start, which is most of
    // what filled the log. The head and tail are what actually get read; the
    // count pins the shape.
    final offsets = _trackStartOffsets;
    final preview = offsets.length <= 6
        ? '$offsets'
        : '[${offsets.take(3).join(', ')}, … , '
            '${offsets.skip(offsets.length - 2).join(', ')}]';
    debugPrint(
      '[Player] Track offsets (${offsets.length - 1} track(s)): $preview',
    );
  }

  /// Duration of track [i], falling back to the start-offset delta for the
  /// legacy sites that set [_trackStartOffsets] directly (single-file case).
  double _trackDurationAt(int i) {
    if (i >= 0 && i < _trackDurations.length) return _trackDurations[i];
    if (i >= 0 && i + 1 < _trackStartOffsets.length) {
      return _trackStartOffsets[i + 1] - _trackStartOffsets[i];
    }
    return 0;
  }

  /// Track index whose file contains [absoluteSeconds]. A position inside a gap
  /// (an un-downloaded region) snaps to the start of the next available track;
  /// positions past the last track clamp to it.
  int _trackIndexForAbsolute(double absoluteSeconds) {
    final n = _trackStartOffsets.length - 1;
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++) {
      if (absoluteSeconds < _trackStartOffsets[i] + _trackDurationAt(i))
        return i;
      if (i + 1 < n && absoluteSeconds < _trackStartOffsets[i + 1])
        return i + 1;
    }
    return n - 1;
  }

  /// Whether [absoluteSeconds] sits on a chapter boundary (within 1s tolerance).
  /// Chapter starts come from the book metadata and jump targets are passed as
  /// rounded whole seconds, so exact equality isn't expected — the point is to
  /// tell a genuine "jump to chapter N" target from an ordinary in-chapter
  /// seek that happens to land near a file boundary.
  bool _isChapterStartWithin(double absoluteSeconds) {
    if (_chapters.isEmpty) return false;
    for (final ch in _chapters) {
      final s = (ch['start'] as num?)?.toDouble() ?? 0;
      if ((absoluteSeconds - s).abs() <= 1.0) return true;
    }
    return false;
  }

  /// Whether mapping chapter i to track i is SAFE for this book: the chapter
  /// starts sit at (or, allowing cumulative metadata/file drift, near) their
  /// track's start. Equal COUNTS alone are not proof — a book can hold N
  /// files and N chapters with two chapters inside one file and a
  /// chapter-less file elsewhere, where index mapping would seek to the
  /// wrong file entirely. The grace accepts the drift that makes index
  /// mapping NECESSARY; it must stay well below a typical track length so a
  /// genuinely misplaced chapter fails the check.
  bool _chapterIndexMappingSafe() {
    final n = _trackStartOffsets.length - 1;
    if (n <= 0 || _chapters.length != n) return false;
    var total = 0.0;
    for (var i = 0; i < n; i++) {
      total += _trackDurationAt(i);
    }
    final grace = math.min(30.0, total / n * 0.25);
    var ok = 0;
    for (var i = 0; i < n; i++) {
      final s = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
      final lo = _trackStartOffsets[i] - grace;
      final hi = i + 1 < n ? _trackStartOffsets[i + 1] + grace : double.infinity;
      if (s >= lo && s < hi) ok++;
    }
    return ok * 4 >= n * 3;
  }

  /// Whether [absoluteSeconds] falls inside a downloaded track's playback
  /// range. Positions in gaps between downloaded tracks, and anywhere past the
  /// last downloaded track, are not locally playable.
  bool _positionCoveredLocally(double absoluteSeconds) {
    final n = _trackStartOffsets.length - 1;
    for (int i = 0; i < n; i++) {
      final start = _trackStartOffsets[i];
      final end = start + _trackDurationAt(i);
      if (absoluteSeconds >= start - 0.5 && absoluteSeconds < end - 0.5) {
        return true;
      }
    }
    return false;
  }

  /// Phase 1.7: snapshot the URLs and HTTP headers used to build the
  /// streaming AudioSource so the iOS native widget core can hit the same
  /// endpoints if Flutter dies. Auth is in the URL (session id or token);
  /// custom headers (Cloudflare Access etc.) ride along for reverse-proxy auth.
  void _captureStreamUrls(
    List<dynamic> audioTracks,
    ApiService api, {
    String? sessionId,
    int? playMethod,
  }) {
    final urls = <String>[];
    for (final t in audioTracks) {
      final track = t as Map<String, dynamic>;
      final contentUrl = track['contentUrl'] as String? ?? '';
      if (contentUrl.isEmpty) continue;
      urls.add(
        api.buildTrackUrl(
          contentUrl,
          sessionId: sessionId,
          trackIndex: (track['index'] as num?)?.toInt(),
          playMethod: playMethod,
        ),
      );
    }
    if (urls.isNotEmpty) {
      final u = Uri.parse(urls.first);
      final form = u.path.contains('/public/session/')
          ? 'public session'
          : (u.queryParameters.containsKey('token') ? 'tokened' : 'other');
      debugPrint('[Player] Stream URL form: $form (${u.path})');
    }
    _activeStreamUrls = urls;
    _activeStreamHeaders = Map<String, String>.from(api.playbackSessionHeaders);
  }

  /// Subscribe to track index changes for multi-file playback.
  void _subscribeTrackIndex() {
    _indexSub?.cancel();
    if (_player == null) return;
    _indexSub = _player!.currentIndexStream.listen(
      (index) {
        if (index == null) return;
        // A paused player only changes file through a seek, and a seek sets
        // the index first. Anything else is the player skipping past a file
        // it failed on, which is not where the listener stopped.
        if (index != _currentTrackIndex &&
            _playerFailedWhilePaused('moved from file $_currentTrackIndex to $index')) {
          return;
        }
        // Pre-buffer auto-advance: if the queue has grown past the current
        // book's tracks and AVQueuePlayer has stepped into the pre-loaded
        // next book's range, fire the book transition.
        if (_currentBookTrackCount > 0 &&
            index >= _currentBookTrackCount &&
            _preloadedNextBook != null) {
          debugPrint(
            '[PreBuffer] currentIndex=$index crossed book boundary at $_currentBookTrackCount',
          );
          _onAutoQueueAdvanced();
          return;
        }
        // Within-book multi-track advance (existing behavior).
        if (_trackStartOffsets.length > 1) {
          final clamped = index.clamp(0, _trackStartOffsets.length - 2);
          if (clamped != _currentTrackIndex) {
            _lastIndexAdvanceTime = DateTime.now();
            _pendingTrackAdvanceRefresh = true;
            debugPrint(
              '[Player] Track index advance: $_currentTrackIndex -> $clamped',
            );
            // 1:1 layout (one file per chapter): a track flip IS a chapter
            // flip. Pin the new chapter now so the throttled position tick
            // can't briefly flash the old title while the position stream
            // catches up to the flipped track. Don't override a jump that
            // already reserved a different chapter, and stand down while a
            // seek is still in flight: before the engine switches, the index
            // stream can re-report the PRE-seek (often the LAST) track, which
            // would pin that chapter over the jump target that the seek will
            // latch once it lands.
            final mappedChapter = _chapterIndexForTrack(clamped);
            final newChapterForAdvance = mappedChapter != null &&
                mappedChapter != _lastNotifiedChapterIndex;
            if (mappedChapter != null &&
                mappedChapter != _lastNotifiedChapterIndex &&
                _currentItemId != null &&
                _lastSeekTargetSeconds == null &&
                (_chapterJumpLatchIndex < 0 ||
                    _chapterJumpLatchIndex == mappedChapter)) {
              final ch = _chapters[mappedChapter] as Map<String, dynamic>;
              _chapterJumpLatchIndex = mappedChapter;
              _lastNotifiedChapterIndex = mappedChapter;
              _currentChapterStart = (ch['start'] as num?)?.toDouble() ?? 0;
              _currentChapterEnd =
                  (ch['end'] as num?)?.toDouble() ?? _totalDuration;
              _pushMediaItem(
                _currentItemId!,
                _currentTitle ?? '',
                _currentAuthor ?? '',
                _currentCoverUrl,
                _totalDuration,
                chapter: ch['title'] as String?,
              );
              if (_notifChapterMode) _handler?.refreshPlaybackState();
              debugPrint(
                '[Player] 1:1 pinned chapter $mappedChapter on track advance',
              );
            }
            // The pin above can be skipped because the chapter latch still
            // points at the PREVIOUS chapter; that must not also skip the
            // intro pre-jump, or the new chapter's opening words play until
            // the 120ms watcher catches up. A seek-driven index change is
            // excluded by the null target; a natural auto-advance is not.
            if (newChapterForAdvance &&
                _lastSeekTargetSeconds == null &&
                !_isLoadingNewItem &&
                DateTime.now().difference(_lastUserSeekTime).inSeconds >= 3) {
              unawaited(_autoAdvanceIntroSkip(mappedChapter));
            }
          }
          // A seek that is still settling must not have its anchor regressed:
          // before the engine applies a cross-file seek, the index stream can
          // re-report the PRE-seek track here. Adopting it would recompose the
          // absolute position as "old track's tail" — the previous chapter's
          // title with a full bar flashing over the pinned jump target while
          // the new file buffers. The seek already pre-set the intended index;
          // the stream re-fires with the landed track once it applies.
          if (_lastSeekTargetSeconds != null) {
            debugPrint(
              '[Player] Seek settling - holding track index '
              '$_currentTrackIndex (stream reported $clamped)',
            );
          } else {
            _currentTrackIndex = clamped;
            // While paused, a genuine file change re-anchors the held spot at
            // the new file's position (a failed player can otherwise walk the
            // book forward; see _playerFailedWhilePaused).
            if (_pausedAtS != null && !_playerBroken && !_player!.playing) {
              _pausedAtS = position.inMilliseconds / 1000.0;
            }
          }
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[Player] Index stream error: $e');
      },
    );
  }

  /// Resolve an absolute book position to the (track index, local offset) it
  /// lands on, including the chapter-start file-boundary snap. Shared by the
  /// seek path and fresh-session starts (setAudioSource's initialIndex and
  /// initialPosition) so a start at a chapter boundary and a later jump land
  /// identically.
  ({int index, double localOffset}) _resolveAbsolutePosition(
    double absoluteSeconds, {
    bool chapterJump = false,
  }) {
    // Single file (or unknown offsets) - no track math and no drift snap.
    if (_trackStartOffsets.length <= 1) {
      return (index: 0, localOffset: absoluteSeconds);
    }
    final nTracks = _trackStartOffsets.length - 1;
    var target = _trackIndexForAbsolute(absoluteSeconds);
    final trackStart = _trackStartOffsets[target];
    final localOffset = (absoluteSeconds - trackStart).clamp(
      0.0,
      _trackDurationAt(target),
    );
    // Chapter-start snap (only for explicit chapter jumps - the [chapterJump]
    // flag). The chapter metadata timeline and the per-file duration timeline
    // drift apart by a fraction of a second to a few seconds growing with the
    // chapter count, which can drop a "jump to chapter N" target into the tail
    // of file N-1 - landing on the metadata start alone would "play the
    // previous chapter" or pin the bar near full. The closer the NEXT file
    // boundary is, the more surely the arithmetic file pick is the drifted
    // one, so hop to that file's start. No fixed tolerance - drift is
    // book-dependent. Precise seeks (scrub, bookmarks, ...) never pass
    // [chapterJump] and land exactly where asked. The snap is DISABLED for
    // multi-file books with far more tracks than chapters (e.g. one long
    // hour-long audio file split into ~100 per-file tracks but a small chapter
    // list): file boundaries don't map to chapter boundaries there, so
    // snapping can land in the wrong chapter's file. A one-file-per-chapter
    // book (track count ≈ chapter count, ~1.5x allowance for intro/credits
    // files) snaps freely.
    if (chapterJump &&
        _isChapterStartWithin(absoluteSeconds) &&
        _chapters.isNotEmpty &&
        nTracks * 2 <= _chapters.length * 3) {
      // Exactly one chapter per file: the chapter's audio IS its file's first
      // frame, so map by INDEX. This is immune to metadata/file timeline
      // drift, which the containment pick above is not — a drifted target can
      // sit deep inside the PREVIOUS file's estimated range when per-file
      // durations are inflated (VBR without a seek index), and the seek then
      // clamps to that file's real end, reporting the PREVIOUS chapter's
      // title ("rewind snapped to the chapter start but showed the previous
      // chapter" report).
      if (nTracks == _chapters.length && _chapterIndexMappingSafe()) {
        var chapterIdx = 0;
        var bestDelta = double.infinity;
        for (var i = 0; i < _chapters.length; i++) {
          final s = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
          final delta = (s - absoluteSeconds).abs();
          if (delta < bestDelta) {
            bestDelta = delta;
            chapterIdx = i;
          }
        }
        if (chapterIdx < nTracks && bestDelta <= 1.0) {
          debugPrint(
            '[Player] Chapter-start index snap ${absoluteSeconds.toStringAsFixed(1)}s '
            '-> chapter $chapterIdx (1 file per chapter) at 0',
          );
          return (index: chapterIdx, localOffset: 0.0);
        }
      }
      if (target + 1 < nTracks) {
        final distNext = _trackStartOffsets[target + 1] - absoluteSeconds;
        final distCurrent = absoluteSeconds - _trackStartOffsets[target];
        if (distNext > 0 && distNext < distCurrent) {
          debugPrint(
            '[Player] Chapter-start snap ${absoluteSeconds.toStringAsFixed(1)}s '
            '(next boundary ${distNext.toStringAsFixed(2)}s away, containing '
            'start ${distCurrent.toStringAsFixed(2)}s ago) -> index '
            '${target + 1} at 0',
          );
          return (index: target + 1, localOffset: 0.0);
        }
        // Tail guard (same drift, opposite miss): a target can resolve into
        // the tail of the previous file without being closer to that boundary
        // than to the file's start. Landing there clamps to the previous
        // file's real end — the previous chapter's tail with its title. When
        // the resolved offset sits within ~2s of this file's estimated end,
        // the next file's first frame is the intended chapter's audio.
        if (_trackDurationAt(target) > 0 &&
            _trackDurationAt(target) - localOffset < 2.0) {
          debugPrint(
            '[Player] Chapter-start tail snap ${absoluteSeconds.toStringAsFixed(1)}s '
            '(resolved ${localOffset.toStringAsFixed(1)}s into track $target, '
            'estimated length ${_trackDurationAt(target).toStringAsFixed(1)}s) '
            '-> index ${target + 1} at 0',
          );
          return (index: target + 1, localOffset: 0.0);
        }
      }
    }
    return (index: target, localOffset: localOffset);
  }

  static const _startSeekStall = Duration(seconds: 7);
  static const _maxStartSeekRetries = 2;

  /// The first seek of a streamed start. When the server refuses the range
  /// request the seek sits in buffering with nothing loaded, and a start that
  /// awaits it never reaches play() - Play then does nothing until something
  /// else seeks. A fresh seek unsticks it, so send one; if it still hasn't
  /// landed, let the start carry on and the player keeps loading on its own.
  Future<void> _seekForStart(double seconds, int generation) async {
    for (var attempt = 0; ; attempt++) {
      final landed = await _seekAbsolute(
        seconds,
      ).then((_) => true).timeout(_startSeekStall, onTimeout: () => false);
      if (landed || _player == null || _startSuperseded(generation)) return;
      final ahead = _player!.bufferedPosition - _player!.position;
      if (ahead > const Duration(seconds: 2) ||
          attempt >= _maxStartSeekRetries) {
        debugPrint(
          '[Player] Start seek to ${seconds.toStringAsFixed(1)}s still pending '
          '(buffered ahead ${ahead.inMilliseconds}ms) - starting anyway',
        );
        return;
      }
      debugPrint(
        '[Player] Start seek to ${seconds.toStringAsFixed(1)}s stalled with '
        'nothing buffered - seeking again (${attempt + 1}/$_maxStartSeekRetries)',
      );
    }
  }

  /// Seek response timeout: a seek that lands at the very end of a file never
  /// answers on Android, and everything waiting on it hung with it (GH #428).
  static const _seekCap = Duration(seconds: 6);
  void _seekTimedOut() => debugPrint(
    '[Player] Seek got no answer in ${_seekCap.inSeconds}s - carrying on',
  );

  /// True when [absoluteSeconds] is still the LATEST seek intent — i.e. no
  /// newer seek overwrote [_lastSeekTargetSeconds] while this seek awaited the
  /// engine. A superseded seek must not re-push its stale (frequently the
  /// LAST-chapter) title over the newer jump's, which is exactly what this
  /// guard blocks.
  ///
  /// The comparison is EXACT equality, not a tolerance band: the target was
  /// stored verbatim from [absoluteSeconds] with no float drift between the
  /// store and this read, so equality is the honest predicate. A tolerance
  /// (e.g. `< 1.0`) would re-admit precisely the sub-second superseded seeks
  /// this guard exists to reject — two different-intent jumps whose targets
  /// land under a second apart, e.g. across a chapter boundary, would be
  /// misread as "the same intent" and the stale title could still re-push.
  /// `null` means the target was already cleared by the catch-up path (seek
  /// landed / intent consumed), which is always still-latest.
  bool _seekStillLatest(double absoluteSeconds) =>
      _lastSeekTargetSeconds == null ||
      _lastSeekTargetSeconds == absoluteSeconds;

  /// Seek to an absolute book position, handling multi-file offset conversion.
  Future<void> _seekAbsolute(
    double absoluteSeconds, {
    // Only explicit "jump to a chapter" actions snap to the nearest file
    // boundary. Precise-position seeks (scrubber drag, bookmarks, history,
    // relative skips, auto/sleep rewind, position adoption) must land exactly
    // where asked — a drag to a chapter's final second is NOT a chapter jump.
    bool chapterJump = false,
    // Explicit chapter index to pin as the reported chapter after the seek.
    // Used by chapter-navigation pre-jumps that land INSIDE the destination
    // chapter (intro skip) where the nearest-start latch heuristic in
    // [_latchChapterJumpTarget] cannot bind (the offset target is far from a
    // chapter start). Without it the optimistically-updated track index + a
    // stale stream position compose an inflated absolute position that can
    // fall past the last chapter's end into the trailing-grace title during
    // the engine's track switch.
    int? pinChapterIndex,
  }) async {
    if (_player == null) return;
    // Await a pending pause-time swap before seeking so the seek doesn't race
    // the engine swap (same guard the upstream seek path applies).
    final swap = _pauseSwap;
    if (swap != null) {
      _pauseSwap = null;
      try {
        await swap;
      } catch (_) {}
      if (_player == null) return;
    }
    // A scrub issued while this start is still loading is the latest intent:
    // the start's own landing seek must not pull the engine back to the
    // position captured before the drag. (The end of playItem re-applies the
    // request for starts that already loaded their source before it arrived.)
    if (_isLoadingNewItem) {
      absoluteSeconds =
          _pendingLoadSeekFor(_playbackGeneration) ?? absoluteSeconds;
    }
    // Any real seek leaves the parked-at-boundary state (play() also restarts
    // from the last downloaded chapter via its own seek).
    _parkedAtBoundary = false;
    _parkedBoundaryChapterIdx = null;
    // Any non-chapter-jump seek clears a stale latch; the position logic goes
    // back to plain metadata lookup. A seek carrying an explicit
    // [pinChapterIndex] keeps (and moves) the latch instead: it names the
    // chapter the jump MEANT, and must stay authoritative while the engine
    // switch is in flight - the landed file-timeline start can sit a hair
    // before the metadata chapter start, where a position tick would otherwise
    // resolve (and push) the PREVIOUS chapter for a moment.
    if (!chapterJump && pinChapterIndex == null) {
      _chapterJumpLatchIndex = -1;
    }

    // A fresh session used to be adopted here (a seek is interrupted audio, so
    // a rebuild could ride it) - but every chapter switch or scrub target
    // would then tear down and re-prepare the whole concatenated source before
    // audio lands, which is exactly the first-switch stall on a slow link.
    // Seek on the current source first so audio starts immediately; the
    // tokenless swap waits for the next pause, or the dead-source/retry paths.
    debugPrint(
      '[Player] Seek while a session upgrade is pending - deferring the swap '
      'to a pause (${_pendingSessionUpgrade?['id'] ?? 'none'})',
    );

    // Incomplete download: there's no audio past the decoded end, so clamp the
    // target there instead of letting the player report a phantom position
    // beyond the file (which would then get saved/bookmarked). GH #278.
    if (_shortLocalDurationSec != null &&
        absoluteSeconds > _shortLocalDurationSec!) {
      absoluteSeconds = _shortLocalDurationSec!;
    }

    // Multi-file concat (partial download, or a local book rebuilt into
    // segments): the last file has audio only up to its own end while
    // _totalDuration is the WHOLE book on the server. Clamp to the reachable
    // end of the concatenation so a request at an undownloaded/tail position
    // lands on the concat's final sample instead of pinning a raw book-end
    // target — activeSeekTarget would keep resolving every chapter lookup to
    // the LAST chapter until position catches up (which it never will),
    // flashing the wrong title and spuriously completing the book.
    if (_trackStartOffsets.length > 1) {
      final lastTrack = _trackStartOffsets.length - 2;
      final reachEnd =
          _trackStartOffsets[lastTrack] + _trackDurationAt(lastTrack);
      if (reachEnd > 0 && absoluteSeconds > reachEnd) {
        debugPrint(
          '[Player] Seek ${absoluteSeconds.toStringAsFixed(1)}s exceeds '
          'concat reach ${reachEnd.toStringAsFixed(1)}s - clamping',
        );
        absoluteSeconds = reachEnd;
      }
    }

    // A seek during the pause moves the held spot with it.
    if (_pausedAtS != null) {
      _pausedAtS = absoluteSeconds;
      _resumeAnchorS = absoluteSeconds;
    }
    // Record seek target so UI can snap immediately
    _lastSeekTargetSeconds = absoluteSeconds;
    _lastSeekTime = DateTime.now();

    // Debug aid: log the chapter the seek lands in so a slow buffering switch
    // (stale position until ready) can be verified against the log.
    if (_chapters.isNotEmpty) {
      for (final ch0 in _chapters) {
        final m = ch0 as Map<String, dynamic>;
        final s = (m['start'] as num?)?.toDouble() ?? 0;
        final e = (m['end'] as num?)?.toDouble() ?? _totalDuration;
        if (absoluteSeconds >= s && absoluteSeconds < e) {
          // Chapter bounds only: the title is the user's own content and must
          // not travel in a log they might share.
          debugPrint(
            '[Player] Seek chapter → ${s.toStringAsFixed(0)}s'
            '–${e.toStringAsFixed(0)}s',
          );
          break;
        }
      }
    }

    if (_trackStartOffsets.length <= 1) {
      // Same pre-seek pin as the multi-file branch: the chapter the seek
      // meant stays authoritative while the engine is still moving.
      if (pinChapterIndex != null) _pinChapterLatch(pinChapterIndex);
      // Single file — seek directly
      await _player!
          .seek(Duration(milliseconds: (absoluteSeconds * 1000).round()))
          .timeout(_seekCap, onTimeout: _seekTimedOut);
      // Superseded-seek guard: a newer [skipToNextChapter] / prev press updates
      // [_lastSeekTargetSeconds] (set just before THIS await) to a DIFFERENT
      // target while we were awaiting the engine. When that awaits surfaces, a
      // superseded seek's post-await pin would re-push the OLD (last-viewed =
      // "last chapter") title over the newer jump - the every-chapter-is-a-file
      // session-upgrade flash. Only the seek that is still the latest intent may
      // latch its pin.
      if (_seekStillLatest(absoluteSeconds)) {
        if (pinChapterIndex != null) _pinChapterLatch(pinChapterIndex);
      }
      notifyListeners();
      return;
    }
    // Multi-file — find the right track and local offset (gap-aware: a target
    // inside an un-downloaded region snaps to the next available track). The
    // [chapterJump] boundary snap lives in [_resolveAbsolutePosition], shared
    // with fresh-session starts so a start at a chapter boundary and a later
    // jump land identically.
    final resolved = _resolveAbsolutePosition(
      absoluteSeconds,
      chapterJump: chapterJump,
    );
    final target = resolved.index;
    final localOffset = resolved.localOffset;
    debugPrint(
      '[Player] Seek ${absoluteSeconds.toStringAsFixed(1)}s -> track $target '
      'at ${localOffset.toStringAsFixed(1)}s '
      '(${_trackStartOffsets.length - 1} tracks)',
    );
    // Update index BEFORE seeking so positionStream events use the right offset
    _currentTrackIndex = target;
    // Push the jump chapter BEFORE the engine switches. While the (possibly
    // slow) multi-file switch is underway, the optimistic target track index
    // plus the stale PRE-seek position compose an absolute position near the
    // book's tail, and nothing re-pushes the jump title until the seek lands —
    // so the lock screen lingers on the PREVIOUS (frequently the LAST) chapter,
    // longer for slower links. Latching now makes the jump target
    // authoritative immediately (same channel a post-landing latch uses); the
    // supersede-guarded block below re-asserts it only when THIS seek is still
    // the latest intent. Jumps that already carry an explicit chapter index
    // ([pinChapterIndex]: sheet taps, intro-skip pre-jumps, barrier rewinds)
    // pre-pin that chapter so a rounded-down seek target can never detune to
    // the NEXT chapter's title mid-switch - and so a landing a hair before the
    // metadata chapter start can't resolve to the PREVIOUS one.
    if (chapterJump || pinChapterIndex != null) {
      if (pinChapterIndex != null) {
        _pinChapterLatch(pinChapterIndex);
      } else {
        _latchChapterJumpTarget(absoluteSeconds);
      }
    }
    await _player!
        .seek(
          Duration(milliseconds: (localOffset * 1000).round()),
          index: target,
        )
        .timeout(_seekCap, onTimeout: _seekTimedOut);
    // Bind the reported chapter to the INTENDED chapter (not the metadata
    // mapping of the landed position, which near a drifted boundary reads the
    // previous file's chapter) so the notification/UI shows "chapter N" the
    // moment the jump lands instead of flashing "N-1" first. Same
    // superseded-seek guard as the single-file branch above: only bind when
    // THIS seek is still the latest intent — a newer jump overwriting
    // [_lastSeekTargetSeconds] while this seek was awaiting must not re-push
    // its stale (superseded, frequently last-chapter) title over the newer
    // jump's.
    if (_seekStillLatest(absoluteSeconds)) {
      if (pinChapterIndex != null) {
        _pinChapterLatch(pinChapterIndex);
      } else if (chapterJump) {
        _latchChapterJumpTarget(absoluteSeconds);
      }
    }
    notifyListeners();
    return;
  }

  /// Pin the reported chapter to the one a jump meant.
  ///
  /// After a chapter jump the engine can land a hair BEFORE the intended
  /// chapter's metadata start (metadata vs per-file timeline drift), so a
  /// position-based lookup would demote the title to the PREVIOUS chapter for
  /// a moment. A jump target is by definition a metadata chapter start
  /// (rounded to a second), so the chapter whose start is nearest is the
  /// intended one. Pin it and push it so the notification/lock screen and
  /// chapter progress bar show the right chapter immediately; the position
  /// watchers keep it until the position truly passes the chapter's end.
  /// Containment lookup is deliberately NOT used: near a drifted boundary the
  /// target can still read as the previous chapter's range.
  void _latchChapterJumpTarget(double absoluteSeconds) {
    if (_chapters.isEmpty) {
      _chapterJumpLatchIndex = -1;
      return;
    }
    int nearest = -1;
    double bestDist = double.infinity;
    for (int i = 0; i < _chapters.length; i++) {
      final s = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
      final d = (s - absoluteSeconds).abs();
      if (d < bestDist) {
        bestDist = d;
        nearest = i;
      }
    }
    if (nearest < 0 || bestDist > 1.0) {
      // Not a chapter start (miss → just leave detection to the position
      // watchers).
      _chapterJumpLatchIndex = -1;
      return;
    }
    _pinChapterLatch(nearest);
  }

  /// Pin a specific chapter index as the reported chapter; used by
  /// chapter-navigation pre-jumps whose target is offset INSIDE the
  /// destination chapter (intro skip) and by [_latchChapterJumpTarget] once
  /// the nearest-start heuristic has decided which chapter was meant.
  void _pinChapterLatch(int index) {
    if (_chapters.isEmpty || index < 0 || index >= _chapters.length) {
      _chapterJumpLatchIndex = -1;
      return;
    }
    final ch = _chapters[index] as Map<String, dynamic>;
    final s = (ch['start'] as num?)?.toDouble() ?? 0;
    final e = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
    _lastNotifiedChapterIndex = index;
    _currentChapterStart = s;
    _currentChapterEnd = e;
    _chapterJumpLatchIndex = index;
    final title = ch['title'] as String?;
    debugPrint(
      '[Player] Chapter jump latch: idx=$index "$title" '
      'start=${s.toStringAsFixed(1)}s end=${e.toStringAsFixed(1)}s',
    );
    if (_currentItemId != null) {
      _pushMediaItem(
        _mediaItemKey,
        _currentTitle ?? '',
        _currentAuthor ?? '',
        _currentCoverUrl,
        _totalDuration,
        chapter: title,
      );
      // Chapter progress mode computes the bar from the bounds set above.
      // When the live position already sits inside the pinned chapter, a
      // correction (e.g. after a boundary snap first resolved the previous
      // chapter) must re-push the PlaybackState immediately - otherwise the
      // notification keeps the stale chapter-relative position until the next
      // state push, and a previous chapter's near-end position reads as a
      // full progress bar.
      if (_notifChapterMode) {
        final posSec = position.inMilliseconds / 1000.0;
        if (posSec >= s - 0.5 && posSec < e) {
          _handler?.refreshPlaybackState();
        }
      }
    }
  }

  /// MUST be called after Activity is ready.
  static Future<void> init() async {
    if (_handler != null) return; // Already initialized
    // Reset for hot restart — previous completer may already be completed
    // while _handler was reset to null by the Dart VM restart.
    if (_initCompleter.isCompleted) {
      _initCompleter = Completer<void>();
    }
    try {
      final fwdSkip = await PlayerSettings.getForwardSkip();
      final backSkip = await PlayerSettings.getBackSkip();
      _handler = await AudioService.init<AudioPlayerHandler>(
        builder: () => AudioPlayerHandler(),
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.audiobookshelf.app.channel.audio',
          androidNotificationChannelName: 'Absorb',
          // Keep foreground service alive when paused — prevents Android from
          // killing audio after notification interruptions on locked screen.
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'drawable/ic_notification',
          fastForwardInterval: Duration(seconds: fwdSkip),
          rewindInterval: Duration(seconds: backSkip),
          androidBrowsableRootExtras: {
            AndroidContentStyle.supportedKey: true,
            AndroidContentStyle.browsableHintKey:
                AndroidContentStyle.categoryListItemHintValue,
            AndroidContentStyle.playableHintKey:
                AndroidContentStyle.gridItemHintValue,
            'android.media.browse.SEARCH_SUPPORTED': true,
          },
        ),
      );
      // Bind service so handler routes play/pause through service (for auto-rewind)
      _handler!.bindService(_instance);
      // Wire the EQ service's skip-silence toggle through to just_audio.
      // Android-only: just_audio's setSkipSilenceEnabled is a no-op on iOS.
      if (Platform.isAndroid) {
        EqualizerService().setSkipSilenceApplier((enabled) {
          try {
            _handler?.player.setSkipSilenceEnabled(enabled);
          } catch (e) {
            debugPrint('[Player] setSkipSilenceEnabled failed: $e');
          }
        });
      }
      // iOS native engine: keep the processing tap attached whenever any
      // EQ/effect is active so effects work with the band EQ off.
      if (Platform.isIOS) {
        EqualizerService().setTapApplier((active) {
          try {
            if (active) {
              _handler?.player.attachEqualizerTap();
            } else {
              _handler?.player.detachEqualizerTap();
            }
          } catch (e) {
            debugPrint('[Player] tap applier failed: $e');
          }
        });
      }
      // Initialize cached skip amounts so notification icons show the correct values
      _handler!._cachedForwardSkip = fwdSkip;
      _handler!._cachedBackSkip = backSkip;
      // Nothing is loaded yet so there's no library override to apply; the
      // per-library amounts follow from _syncNotifSkipCache once an item does.
      if (Platform.isIOS) {
        unawaited(_pushIosSkipIntervals(fwdSkip, backSkip));
      }
      _handler!._cachedNotifSpeedBookmark =
          await PlayerSettings.getMediaControlsSpeedBookmark();
      _handler!._cachedLockSeekBar = await PlayerSettings.getLockSeekBar();
      debugPrint('[Player] AudioService initialized');
      if (Platform.isIOS) unawaited(_reportPreviousBackgroundDeath());
      if (Platform.isAndroid) unawaited(_reportPreviousExit());
      unawaited(TranscriptionService.instance.reportInterruptedRun());
      // Configure streaming cache if enabled
      final cacheSizeMb = await PlayerSettings.getStreamingCacheSizeMb();
      debugPrint('[Player] Streaming cache setting: $cacheSizeMb MB');
      if (cacheSizeMb > 0) {
        try {
          await AudioPlayer.configureStreamingCache(cacheSizeMb);
          debugPrint('[Player] Streaming cache configured: $cacheSizeMb MB');
        } catch (e) {
          debugPrint('[Player] Streaming cache init failed: $e');
        }
      }
      // Load notification chapter progress setting and watch for changes
      _instance._notifChapterMode =
          await PlayerSettings.getNotificationChapterProgress();
      _instance._nowPlayingLayoutJson =
          await PlayerSettings.getNowPlayingLayout();
      _instance._nowPlayingLayout = NowPlayingLayout.fromJson(
        _instance._nowPlayingLayoutJson,
      );
      _instance._speedAdjustedTime =
          await PlayerSettings.getSpeedAdjustedTime();
      PlayerSettings.settingsChanged.addListener(_instance._onSettingsChanged);
      // Configure audio session for audiobook playback
      await _configureAudioSession();
    } catch (e, st) {
      debugPrint('[Player] AudioService.init failed: $e\n$st');
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  static StreamSubscription? _interruptSub;
  static StreamSubscription? _noisySub;
  static StreamSubscription? _devicesSub;
  // Output routes whose disappearance should pause playback. becomingNoisy only
  // fires when the LAST external output leaves (audio falling back to the phone
  // speaker). With two outputs connected at once (e.g. car stereo + earbuds),
  // dropping one just reroutes to the other and never fires it, so the book
  // plays on silently. Watching device removal covers that gap.
  // Set true when BT/headphones disconnect so the interruption handler
  // won't auto-resume playback onto the phone speaker.
  static bool _noisyPause = false;

  /// The volume to put back once a route-removed check has decided; set
  /// while the player is muted for it.
  static double? _routeMutedVolume;
  // Whether BT audio was connected when the current interruption began.
  static bool _wasOnBluetooth = false;
  static bool _duckBriefInterruptions = false;
  static double? _volumeBeforeInterruptionDuck;
  // Safety net for a duck whose matching "end" event never arrives - a known
  // flaky spot on Android, more so over Bluetooth where focus changes route
  // through an extra AVRCP arbitration layer. A duck is supposed to be brief
  // (a notification chime, a voice prompt); if it's still down after this
  // long with nothing having restored it, force it back rather than leaving
  // playback parked at 35% volume for the rest of the session.
  static Timer? _duckWatchdogTimer;
  static const _duckWatchdogTimeout = Duration(seconds: 4);

  static void _armDuckWatchdog() {
    _duckWatchdogTimer?.cancel();
    _duckWatchdogTimer = Timer(_duckWatchdogTimeout, () {
      final stuckVolume = _volumeBeforeInterruptionDuck;
      if (stuckVolume == null) return;
      _volumeBeforeInterruptionDuck = null;
      debugPrint(
        '[AudioSession] Duck watchdog: no end event after '
        '${_duckWatchdogTimeout.inSeconds}s - forcing volume back to $stuckVolume',
      );
      unawaited(_instance._player?.setVolume(stuckVolume));
    });
  }

  static void _clearDuckWatchdog() {
    _duckWatchdogTimer?.cancel();
    _duckWatchdogTimer = null;
  }

  // Last time the app entered the foreground. Used by [ClickDebug] to see
  // whether a MediaSession click's 400ms debounce window overlapped with
  // an app-foreground event — the fingerprint of an Android Auto disconnect
  // handing control back to the phone.
  static DateTime? _lastForegroundAt;
  // Last time we observed BT/AA to be the audio route while playing/pausing.
  // Stamped from interruption begin/end and from service.pause(). Used at
  // click arrival to detect the AA-disconnect phantom: BT was the route
  // recently, isn't now, click came in while bg + not playing. Some devices
  // (Pixel 10 Pro on Android 16 with Android Auto observed) never fire
  // becomingNoisy on AA disconnect, so the 5s _noisyPauseAt guard alone
  // can't catch the delayed phantom MediaButton.media event.
  static DateTime? _lastPlayedOnBtAt;
  static const _eqChannel = MethodChannel('com.absorb.equalizer');

  /// Check if BT audio (A2DP/SCO) is currently connected via native AudioManager.
  static Future<bool> _isBluetoothAudioConnected() async {
    try {
      final result = await _eqChannel.invokeMethod<bool>(
        'isBluetoothAudioConnected',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[AudioSession] BT check failed: $e');
      return false;
    }
  }

  /// Public view of the BT check, for callers that need to compensate for
  /// the delay Bluetooth adds between the playhead and your ears.
  static Future<bool> isBluetoothAudioConnected() =>
      _isBluetoothAudioConnected();

  /// True when BT/headphones just disconnected — callers can check before
  /// starting new playback to avoid blasting audio on the phone speaker.
  static bool get wasNoisyPause => _noisyPause;

  static Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    _duckBriefInterruptions =
        Platform.isAndroid && await PlayerSettings.getDuckBriefInterruptions();

    await session.configure(
      AudioSessionConfiguration(
        // iOS: playback category — no duckOthers so iOS properly recognises this
        // app as the Now Playing app and shows lock screen / Control Center controls.
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.longFormAudio,
        avAudioSessionCategoryOptions: Platform.isIOS
            ? AVAudioSessionCategoryOptions.none
            : AVAudioSessionCategoryOptions.duckOthers,
        // Android: speech content type enables OS voice-intelligibility
        // processing so audiobooks play at normal listening levels. Matches the
        // reference ABS Android client.
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: !_duckBriefInterruptions,
      ),
    );
    // Don't activate the session here — defer to first playback.
    // Activating during init creates a stale MediaSession that Android
    // can garbage-collect after hours in background, leaving bluetooth /
    // notification / widget controls permanently broken.
    // play() and startLocalPlayback() call setActive(true) before playing.

    _interruptSub?.cancel();
    _interruptSub = session.interruptionEventStream.listen(
      (event) async {
        try {
          final service = _instance;

          if (event.begin) {
            if (event.type == AudioInterruptionType.duck &&
                _duckBriefInterruptions) {
              if (service.isPlaying && _volumeBeforeInterruptionDuck == null) {
                final currentVolume = service._player?.volume ?? 1.0;
                _volumeBeforeInterruptionDuck = currentVolume;
                await service._player?.setVolume(
                  (currentVolume * 0.35).clamp(0.0, 1.0).toDouble(),
                );
                _armDuckWatchdog();
                debugPrint(
                  '[AudioSession] Interrupted (${event.type}) — ducking',
                );
              }
              return;
            }

            final duckedVolume = _volumeBeforeInterruptionDuck;
            if (duckedVolume != null) {
              _volumeBeforeInterruptionDuck = null;
              _clearDuckWatchdog();
              await service._player?.setVolume(duckedVolume);
            }
            if (service.isPlaying) {
              debugPrint(
                '[AudioSession] Interrupted (${event.type}) — pausing',
              );
              _wasOnBluetooth = await _isBluetoothAudioConnected();
              if (_wasOnBluetooth) _lastPlayedOnBtAt = DateTime.now();
              debugPrint('[AudioSession] Was on BT: $_wasOnBluetooth');
              // Pause the underlying player directly, not service.pause(), to keep
              // the interruption lightweight (service.pause() also saves and syncs,
              // which a transient duck doesn't need). Still stamp _lastPauseTime so
              // resume runs auto-rewind per the user's settings: calls and nav
              // prompts rewind like a manual pause, gated by activationDelay.
              await service._player?.pause();
              service._lastPauseTime = DateTime.now();
              service._pausedAtS = service.position.inMilliseconds / 1000.0;
              service._resumeAnchorS = service._pausedAtS;
              // Keep the spot on this phone, though: without it a server copy
              // up to a sync behind could be taken for newer (GH #440).
              unawaited(service._saveProgressLocal(service.position));
              // Android reports a permanent focus loss (another app or the
              // car's own source took the audio for good) as `unknown`; calls
              // and nav prompts come as transient `pause`/`duck`. Only a
              // transient one should come back by itself - resuming after a
              // permanent one talked over the radio the user switched to.
              final permanentLoss =
                  Platform.isAndroid &&
                  event.type == AudioInterruptionType.unknown;
              service._wasPlayingBeforeInterrupt = !permanentLoss;
              if (permanentLoss) {
                debugPrint(
                  '[AudioSession] Permanent focus loss - not resuming on its own',
                );
              }
              // The notification reads the player directly, but the home
              // widget, cards and watch only refresh on notify - without this
              // the widget kept showing "playing" and ticking its clock
              // through the whole interruption.
              service.notifyListeners();
            }
          } else {
            if (event.type == AudioInterruptionType.duck &&
                _duckBriefInterruptions) {
              final previousVolume = _volumeBeforeInterruptionDuck;
              _volumeBeforeInterruptionDuck = null;
              _clearDuckWatchdog();
              if (previousVolume != null) {
                await service._player?.setVolume(previousVolume);
                debugPrint(
                  '[AudioSession] Interruption ended — volume restored',
                );
              }
              return;
            }

            // iOS says whether the interrupter wants us back: shouldResume is
            // set after a call, Siri or an alarm, and clear when the user
            // started another app's audio. audio_session surfaces that as
            // type `pause` (resume) versus `unknown` (don't). Resuming over a
            // clear flag would cut off the app the user had just chosen - it
            // only failed to because the activation was refused while that
            // app still held the audio.
            if (Platform.isIOS &&
                event.type == AudioInterruptionType.unknown &&
                service._wasPlayingBeforeInterrupt) {
              debugPrint(
                '[AudioSession] Interruption ended without shouldResume - staying paused',
              );
              service._wasPlayingBeforeInterrupt = false;
              return;
            }
            // Don't auto-resume if the pause was caused by BT/headphone disconnect.
            // Some devices fire interruption-end AFTER becoming-noisy, which would
            // resume playback on the phone speaker.
            if (_noisyPause) {
              debugPrint(
                '[AudioSession] Interruption ended after noisy — skipping resume',
              );
              service._wasPlayingBeforeInterrupt = false;
              return;
            }
            if (service._wasPlayingBeforeInterrupt) {
              service._wasPlayingBeforeInterrupt = false;
              await Future.delayed(const Duration(milliseconds: 600));
              // Re-check: another event (like becoming-noisy) might have fired
              // during the delay.
              if (_noisyPause) return;
              // Don't double-resume: Assistant may already have called play().
              if (service._player?.playing == true) return;
              // If we were on BT when interrupted, check if BT is still connected.
              // Some car head units never send AUDIO_BECOMING_NOISY on disconnect,
              // so _noisyPause alone is not enough.
              if (_wasOnBluetooth) {
                final stillOnBt = await _isBluetoothAudioConnected();
                debugPrint(
                  '[AudioSession] Interruption ended — was BT, still BT: $stillOnBt',
                );
                if (!stillOnBt) {
                  debugPrint(
                    '[AudioSession] BT disconnected during interruption — skipping resume',
                  );
                  _noisyPause = true;
                  return;
                }
                _lastPlayedOnBtAt = DateTime.now();
              }
              debugPrint('[AudioSession] Interruption ended — resuming');
              await service.play(logDetail: 'Auto-resumed after interruption');
            }
          }
        } catch (e) {
          debugPrint('[AudioSession] Interruption handler error: $e');
        }
      },
      onError: (e) {
        debugPrint(
          '[AudioSession] Interruption stream error - re-subscribing: $e',
        );
        _configureAudioSession();
      },
    );

    // Headphones unplugged / BT disconnected — pause, no auto-resume
    _noisySub?.cancel();
    _noisySub = session.becomingNoisyEventStream.listen(
      (_) async {
        try {
          final service = _instance;
          debugPrint('[AudioSession] Becoming noisy — pausing');
          debugPrint(
            '[ClickDebug] becoming-noisy fired: bg=${service._isBackgrounded}, playing=${service.isPlaying}',
          );
          _noisyPause = true;
          service._wasPlayingBeforeInterrupt = false;
          // Cancel any pending media-button click from the BT disconnect so the
          // delayed click handler doesn't resume playback on the phone speaker.
          _handler?.cancelPendingClick();
          if (service.isPlaying) {
            await service.pause();
          }
        } catch (e) {
          debugPrint('[AudioSession] Noisy handler error: $e');
        }
      },
      onError: (e) {
        debugPrint('[AudioSession] Noisy stream error - re-subscribing: $e');
        _configureAudioSession();
      },
    );

    // Pause when an output route we could be playing through disappears, even
    // if another output stays connected - the silent-playback case becomingNoisy
    // misses. Mirrors the noisy handler. Android only; iOS already pauses on
    // route loss. Tradeoff: a rare false pause if you power off a second output
    // you weren't actually listening on, undone with a single tap on play.
    _devicesSub?.cancel();
    if (Platform.isAndroid) {
      _devicesSub = session.devicesChangedEventStream.listen(
        (event) async {
          try {
            final service = _instance;
            if (!service.isPlaying) return;
            final lost = event.devicesRemoved
                .where(
                  (d) =>
                      d.isOutput && externalAudioOutputTypes.contains(d.type),
                )
                .toSet();
            if (lost.isEmpty) return;
            debugPrint(
              '[AudioSession] Output route removed: '
              '${lost.map((d) => '${d.type.name} "${d.name}"').join(', ')}',
            );
            // Android moves the sound to the phone speaker the moment the
            // route goes, so mute right away: two seconds of the book out
            // loud in a quiet car was the whole complaint (GH #480). The
            // settle re-check below then decides between pausing and
            // carrying on: some devices drop and re-add a route when
            // playback starts or the link hiccups.
            if (_routeMutedVolume == null) {
              final current = service._player?.volume ?? 1.0;
              // Never bank a zero volume: an earlier failed settle left the
              // engine muted, and re-banking 0 would make unmute a no-op.
              _routeMutedVolume = current > 0 ? current : 1.0;
              await service._player?.setVolume(0);
            }
            Future<void> unmute() async {
              final v = _routeMutedVolume;
              if (v == null) return;
              _routeMutedVolume = null;
              await service._player?.setVolume(v);
            }
            await Future.delayed(const Duration(seconds: 2));
            if (!service.isPlaying) {
              await unmute();
              return;
            }
            final current = await session.getDevices(includeInputs: false);
            if (!lost.any((d) => !current.contains(d))) {
              debugPrint(
                '[AudioSession] Output route came back - keeping playback',
              );
              await unmute();
              return;
            }
            // Android Auto carries the audio itself, over USB or WiFi. The
            // Bluetooth link to the head unit or a helmet runs beside it and
            // can drop and come back every few minutes without the audio ever
            // stopping, and pausing on those drops stopped the book every
            // 2-3 minutes on a motorcycle head unit (#369). If Android Auto
            // goes away for real it sends its own pause.
            if (await AudioPlayerHandler._carClientRecentlySeen()) {
              debugPrint(
                '[AudioSession] Output route removed while playing - car client seen, keeping playback',
              );
              await unmute();
              return;
            }
            debugPrint(
              '[AudioSession] Output route removed while playing - pausing',
            );
            _noisyPause = true;
            service._wasPlayingBeforeInterrupt = false;
            // Short guard: this pause is ours, not a platform disconnect, so
            // a Play a couple of seconds later is the user. The full 5s threw
            // those away and Play looked dead (#369).
            _handler?.cancelPendingClick(guardMs: 1500);
            if (service.isPlaying) await service.pause();
            await unmute();
          } catch (e) {
            // An error anywhere between the mute and the settle checks must
            // still put the volume back. Clearing only the flag left the book
            // "playing" at volume 0 with no way to recover - silent playback.
            final v = _routeMutedVolume;
            _routeMutedVolume = null;
            if (v != null) {
              try {
                await _instance._player?.setVolume(v);
              } catch (_) {}
            }
            debugPrint('[AudioSession] Device-change handler error: $e');
          }
        },
        onError: (e) {
          debugPrint(
            '[AudioSession] Device-change stream error - re-subscribing: $e',
          );
          _configureAudioSession();
        },
      );
    }
  }

  /// Refresh the media session when the app returns to foreground.
  /// After a long background idle, Android can garbage-collect the stale
  /// MediaSession, leaving bluetooth / notification / widget controls dead.
  /// Re-activating the audio session and re-pushing handler state recovers it.
  static void onAppBackgrounded() {
    _instance._isBackgrounded = true;
    debugPrint('[ClickDebug] App backgrounded');
    if (Platform.isIOS) _trimMemoryForBackground();
  }

  /// iOS: a paused app in the background has no audio keeping it alive, is
  /// suspended within seconds, and is a jetsam candidate whenever memory gets
  /// tight. When iOS evicts it, the audio session goes with it, and any app
  /// Absorb interrupted earlier is told to resume - it starts playing and owns
  /// Now Playing from then on. Nothing keeps a paused app alive for hours, so
  /// the lever is footprint: drop the decoded covers (up to 100MB) on the way
  /// out. They reload lazily on return, and the screen is off meanwhile.
  static void _trimMemoryForBackground() {
    final cache = PaintingBinding.instance.imageCache;
    final beforeMb = cache.currentSizeBytes ~/ 1048576;
    cache.clear();
    cache.clearLiveImages();
    final rssMb = ProcessInfo.currentRss ~/ 1048576;
    unawaited(_logBackgroundMemory(rssMb, beforeMb));
  }

  static const _bgMarkerKey = 'ios_bg_marker';

  /// iOS memory figures from the native side: `footprint` is what jetsam
  /// judges (phys_footprint, not RSS) and `available` is how much more the
  /// process may take before it is killed. Both in MB, -1 when unavailable.
  static Future<({int footprintMb, int availableMb})> iosMemoryInfo() async {
    try {
      final info = await _eqChannelForDiag.invokeMethod<Map<dynamic, dynamic>>(
        'getMemoryInfo',
      );
      int mb(dynamic v) {
        final n = (v as num?)?.toInt() ?? -1;
        return n < 0 ? -1 : n ~/ 1048576;
      }

      return (
        footprintMb: mb(info?['footprint']),
        availableMb: mb(info?['available']),
      );
    } catch (_) {
      return (footprintMb: -1, availableMb: -1);
    }
  }

  /// Log the footprint on the way out and leave a marker that the next
  /// foreground clears. If a later launch still finds it, the process never
  /// came back from the background: iOS ended it there (or the user swiped
  /// it away).
  static Future<void> _logBackgroundMemory(int rssMb, int droppedMb) async {
    final m = await iosMemoryInfo();
    final playing = _instance.isPlaying;
    debugPrint(
      '[Memory] Backgrounded: footprint=${m.footprintMb}MB '
      'available=${m.availableMb}MB rss=${rssMb}MB playing=$playing, '
      'dropped ${droppedMb}MB of decoded covers',
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _bgMarkerKey,
        '${DateTime.now().millisecondsSinceEpoch}|${m.footprintMb}|'
        '${m.availableMb}|$playing',
      );
    } catch (_) {}
  }

  static Future<void> _logForegroundMemory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_bgMarkerKey);
    } catch (_) {}
    final m = await iosMemoryInfo();
    debugPrint(
      '[Memory] Foregrounded: footprint=${m.footprintMb}MB '
      'available=${m.availableMb}MB',
    );
  }

  static Future<void> _reportPreviousBackgroundDeath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_bgMarkerKey);
      if (raw == null) return;
      await prefs.remove(_bgMarkerKey);
      final parts = raw.split('|');
      final at = int.tryParse(parts[0]) ?? 0;
      final ago = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(at))
          .inMinutes;
      String part(int i) => parts.length > i ? parts[i] : '?';
      debugPrint(
        '[Memory] Previous process ended in the background, '
        '${ago}min after it went there (or was swiped away): '
        'footprint=${part(1)}MB available=${part(2)}MB playing=${part(3)}',
      );
    } catch (_) {}
  }

  /// Flutter forwards iOS memory warnings here (and drops its image cache on
  /// its own). Logging them with the numbers says how close to the edge the
  /// app was, before jetsam makes the decision for it.
  static void onMemoryPressure() {
    if (!Platform.isIOS) return;
    unawaited(() async {
      final m = await iosMemoryInfo();
      debugPrint(
        '[Memory] iOS memory warning: footprint=${m.footprintMb}MB '
        'available=${m.availableMb}MB',
      );
    }());
  }

  static Future<void> onAppForegrounded() async {
    final service = _instance;
    service._isBackgrounded = false;
    _lastForegroundAt = DateTime.now();
    // Warm the playback session while the user is still reaching for the
    // play button: a long background usually had the server close it, and
    // rebuilding on the tap is the slow path play() caps at 5s. No-op when
    // nothing is loaded, the session is live, we're offline, casting, or a
    // start is already loading; throttled to one attempt per cooldown.
    unawaited(service._prewarmSessionForPlay());
    if (Platform.isIOS) unawaited(_logForegroundMemory());
    // Relative timing on foreground arrival is the second half of the
    // AA-disconnect fingerprint (variant 3): raw pause, then foreground
    // within ~2s. Log sincePrevPauseMs / sincePrevPlayMs so the disconnect
    // pattern is obvious on one line.
    final handler = _handler;
    int sincePrevPauseMs = -1;
    int sincePrevPlayMs = -1;
    if (handler != null) {
      if (handler._lastHandlerPauseAt != null) {
        sincePrevPauseMs = _lastForegroundAt!
            .difference(handler._lastHandlerPauseAt!)
            .inMilliseconds;
      }
      if (handler._lastHandlerPlayAt != null) {
        sincePrevPlayMs = _lastForegroundAt!
            .difference(handler._lastHandlerPlayAt!)
            .inMilliseconds;
      }
    }
    final aaDisconnectSuspect =
        sincePrevPauseMs >= 0 && sincePrevPauseMs < 3000;
    debugPrint(
      '[ClickDebug] App foregrounded: sincePrevPauseMs=$sincePrevPauseMs, '
      'sincePrevPlayMs=$sincePrevPlayMs, aaDisconnectSuspect=$aaDisconnectSuspect',
    );
    service.resetServerSyncBackoff();
    if (Platform.isIOS && service._iosResyncPending) {
      unawaited(service._iosForegroundResyncIfNeeded());
    }
    // After a widget-driven session the shared engine may have kept playing
    // (or advanced) while Flutter was suspended. Adopt its live state rather
    // than reloading - reloading would restart the same stream (bug #285).
    if (Platform.isIOS && service.hasBook) {
      await service._iosReconcileEngineOnForeground();
    }
    if (!service.hasBook) return;
    // A device-change handler interrupted while the route was muting (app is
    // suspended mid-settle) can strand the engine at volume 0. Back in the
    // foreground the short route-mute protection is no longer needed, so
    // restore the volume and clear the stale flag before anything else.
    final strandedVolume = _routeMutedVolume;
    if (strandedVolume != null) {
      _routeMutedVolume = null;
      try {
        await service._player?.setVolume(strandedVolume);
        debugPrint(
          '[AudioSession] Foreground: restored volume to $strandedVolume',
        );
      } catch (_) {}
    }
    final sessionAlive = service._playbackSessionId != null;
    debugPrint(
      '[MediaSession] Foregrounded - refreshing (playing=${service.isPlaying}, session=$sessionAlive, item=${service._currentItemId})',
    );
    // Alpha: when session=false, the playback session was closed (pause
    // timeout) and likely handler.stop() ran too. Log handler state so we
    // can see whether the MediaSession is recoverable. Strip before beta.
    if (!sessionAlive && handler != null) {
      try {
        final ps = handler.playbackState.value;
        debugPrint(
          '[MediaSession] Recovery diagnostic: handlerPlaying=${ps.playing}, '
          'processingState=${ps.processingState.name}, '
          'playerPlaying=${handler.player.playing}, '
          'playerProcessing=${handler.player.processingState.name}',
        );
      } catch (e) {
        debugPrint('[MediaSession] Recovery diagnostic error: $e');
      }
    }
    // Flush missed UI updates from background
    service.notifyListeners();
    // Flush overdue server sync
    if (service.isPlaying && service._currentItemId != null) {
      final sinceSync = DateTime.now()
          .difference(service._lastServerSync)
          .inSeconds;
      if (sinceSync > 20) {
        service._syncToServer(service.position);
      }
    }
    // Re-activate audio session to get a fresh system token — but only while
    // actually playing. Doing it on every foreground grabbed AUDIOFOCUS_GAIN
    // even when paused/idle, pausing other apps' audio (e.g. Spotify) the
    // moment Absorb was opened without the user ever pressing play. When not
    // playing we don't need focus; the MediaSession refresh below doesn't
    // require it, and play()/startLocalPlayback reacquire focus themselves.
    if (service.isPlaying) {
      try {
        (await AudioSession.instance).setActive(true);
      } catch (_) {}
    } else if (Platform.isIOS && service.hasBook) {
      // Paused with a book loaded: an interruption while iOS had this app
      // suspended may have silently dropped the Now Playing claim. The
      // Android concern above (activation grabbing focus and pausing other
      // apps) doesn't apply - the reassert has its own other-audio guard.
      await service.reassertIosClaimWhilePaused('foreground');
    }
    // Re-push playback state so the system re-registers the MediaSession
    _handler?.refreshPlaybackState();
    // Re-push media item so notification metadata is fresh. Keep this tied
    // only to having a book: after a long background pause the title can be
    // briefly unset, and dropping the re-push left the media controls gone.
    if (service._currentItemId != null) {
      final chapterTitle =
          service._lastNotifiedChapterIndex >= 0 && service._chapters.isNotEmpty
          ? (service._chapters[service._lastNotifiedChapterIndex]
                    as Map<String, dynamic>)['title']
                as String?
          : null;
      service._pushMediaItem(
        service._mediaItemKey,
        service._currentTitle ?? '',
        service._currentAuthor ?? '',
        service._currentCoverUrl,
        service._totalDuration,
        chapter: chapterTitle,
      );
      debugPrint('[MediaSession] Re-pushed media item and playback state');
    }
  }

  String? _currentEpisodeId;
  String? get currentEpisodeId => _currentEpisodeId;

  // Which ABS library the currently-loaded item belongs to, so per-library
  // skip overrides (see PlayerSettings.getSkipOverride) can resolve. Set
  // wherever _currentItemId/_currentEpisodeId are (playItem + queue advance);
  // null when the caller didn't have it available (falls back to global skip).
  String? _currentLibraryId;
  String? get currentLibraryId => _currentLibraryId;

  /// MediaSession / AA item id. Podcast episodes use the compound
  /// `parentId-episodeId` key so AA doesn't treat them as a separate item
  /// from the initial load. Books use the plain itemId.
  String get _mediaItemKey => _currentEpisodeId != null
      ? '${_currentItemId!}-$_currentEpisodeId'
      : _currentItemId!;

  String? _currentEpisodeTitle;
  String? get currentEpisodeTitle => _currentEpisodeTitle;

  _IdleNotificationTarget? _idleNotificationTarget;
  // Starting from the idle notification: keep its state (saved position,
  // chapter duration) until the new source's first media item is ready.
  // Publishing raw player events before that made the bar jump to a
  // chapter-relative position against the wrong duration and back.
  bool _keepIdleNotificationUntilMediaPush = false;

  /// Start an item. UI starts get a hard cap so a dead or very slow server
  /// surfaces an error instead of leaving the spinner up for the full
  /// session/retry budget; background starts keep their longer budget.
  Future<String?> playItem({
    required ApiService api,
    required String itemId,
    required String title,
    required String author,
    required String? coverUrl,
    required double totalDuration,
    required List<dynamic> chapters,
    Map<String, dynamic>? itemSnapshot,
    double startTime = 0,
    bool forceStartTime = false,
    String? episodeId,
    String? episodeTitle,
    String? libraryId,
    String? seriesId,
    bool fromUi = false,
    bool loadOnly = false,
    bool clearPauseRequest = true,
  }) {
    // Bump for every start, including background ones: a UI deadline must
    // not fire after another start has taken over.
    final requestSeq = ++_playRequestSeq;
    // Tell the background pullers to stay off the pipe until this start has
    // its audio: one start can otherwise share the tunnel with a multi-MB
    // item read or a playback-session body and stall for seconds.
    PlaybackQuietGate.beginStart();
    // The gate only holds back work that STARTS after this point. An
    // offline-listening flush already downloading its multi-MB `/play` body
    // must yield too (ledger kept), or it eats the start's bandwidth.
    _progressSync.abortInFlightFlushForPlaybackStart();
    final future = _playItemImpl(
      api: api,
      itemId: itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      totalDuration: totalDuration,
      chapters: chapters,
      itemSnapshot: itemSnapshot,
      startTime: startTime,
      forceStartTime: forceStartTime,
      episodeId: episodeId,
      episodeTitle: episodeTitle,
      libraryId: libraryId,
      seriesId: seriesId,
      fromUi: fromUi,
      loadOnly: loadOnly,
      clearPauseRequest: clearPauseRequest,
    ).whenComplete(PlaybackQuietGate.endStart);
    if (!fromUi) return future;
    final timeoutError =
        _l10n()?.playerErrorConnect ??
        'Couldn\'t reach the server. Check your connection and try again.';
    final hardDeadline = DateTime.now().add(const Duration(seconds: 45));
    final deadline = Completer<String?>();
    Timer? timer;
    void arm(Duration delay) {
      timer?.cancel();
      timer = Timer(delay, () {
        if (deadline.isCompleted) return;
        if (requestSeq != _playRequestSeq) return;
        // The start already finished; let its own result through.
        if (!_isLoadingNewItem) return;
        // Audio is playing: never cut a start that succeeded.
        if (_player?.playing ?? false) return;
        final now = DateTime.now();
        // A source is loading, or this start's item/session body is still
        // receiving bytes. Give a bounded extra window instead of killing a
        // fallback that is about to play.
        final sourceLoading =
            _startSourceRequestedGeneration == _playbackGeneration;
        final requestLegLoading =
            _startRequestLegGeneration == _playbackGeneration;
        final dataFlowing =
            _startProgressGeneration == _playbackGeneration &&
            _lastStartProgressAt != null &&
            now.difference(_lastStartProgressAt!) <
                const Duration(seconds: 5);
        if ((sourceLoading || requestLegLoading || dataFlowing) &&
            now.isBefore(hardDeadline)) {
          arm(const Duration(seconds: 10));
          return;
        }
        debugPrint('[StartTrace] UI start timed out - aborting');
        cancelStartForTimeout();
        if (!deadline.isCompleted) deadline.complete(timeoutError);
      });
    }

    arm(const Duration(seconds: 20));
    return Future.any<String?>([
      future,
      deadline.future,
    ]).whenComplete(() => timer?.cancel());
  }

  int _playRequestSeq = 0;
  int? _startSourceRequestedGeneration;
  int? _startProgressGeneration;
  DateTime? _lastStartProgressAt;
  // A /play body may spend a while waiting for its headers. That wait is part
  // of a healthy start (especially after the item leg falls back), so the UI
  // watchdog must not kill it at its first check just because no bytes have
  // arrived yet.
  int? _startRequestLegGeneration;

  void _markStartSourceRequested(int generation) {
    if (generation != _playbackGeneration) return;
    _startSourceRequestedGeneration = generation;
  }

  void _markStartProgress(int generation) {
    if (generation != _playbackGeneration) return;
    _startProgressGeneration = generation;
    _lastStartProgressAt = DateTime.now();
  }

  /// Abort a start stuck past the UI deadline: invalidate its generation so
  /// late results are ignored, close pending session/prowl requests, and drop
  /// the loading state.
  void cancelStartForTimeout() {
    _playbackGeneration++;
    _isLoadingNewItem = false;
    _endAdvanceBuffering();
    _cancelPendingSessionClients();
    _cancelStartClients();
    _api?.cancelBackgroundItemTransfers();
    _player?.stop();
    _clearState();
    notifyListeners();
  }

  /// Clear the media notification after a removal, but only while the player
  /// is still idle: a start issued before stop() finished owns the session.
  Future<void> clearNowPlayingIfIdle() async {
    if (_currentItemId != null || (_player?.playing ?? false)) {
      debugPrint(
        '[RemoveTrace] clearNowPlayingIfIdle skip current=$_currentItemId '
        'playing=${_player?.playing ?? false}',
      );
      return;
    }
    debugPrint('[RemoveTrace] clearNowPlayingIfIdle clearing');
    _idleNotificationTarget = null;
    await _handler?.clearNotification();
  }

  /// Point the notification at the first remaining absorbing book while the
  /// player is idle. The notification carries the book's real saved position,
  /// seek/rewind/forward and chapter controls, and Play starts that book.
  /// Nothing is loaded into the player until Play.
  Future<void> showIdleNowPlaying({
    required String itemId,
    required String title,
    String? author,
    String? coverUrl,
    double totalDuration = 0,
    double startTime = 0,
    String? episodeId,
    String? episodeTitle,
    Map<String, dynamic>? itemSnapshot,
    List<dynamic>? chapters,
    String? libraryId,
  }) async {
    if (_currentItemId != null || (_player?.playing ?? false)) {
      debugPrint(
        '[RemoveTrace] showIdleNowPlaying skip current=$_currentItemId '
        'playing=${_player?.playing ?? false}',
      );
      return;
    }
    final handler = _handler;
    if (handler == null) return;
    final art = Platform.isAndroid
        ? 'content://$_coverAuthority/cover/$itemId'
        : coverUrl;
    final artUri = (art != null && art.isNotEmpty) ? Uri.tryParse(art) : null;
    final api = _api;
    if (api != null) {
      final clampedStart = totalDuration > 0
          ? startTime.clamp(0.0, totalDuration).toDouble()
          : (startTime > 0 ? startTime : 0.0);
      final target = _IdleNotificationTarget(
        api: api,
        itemId: itemId,
        title: title,
        author: author ?? '',
        coverUrl: coverUrl,
        artUri: artUri,
        totalDuration: totalDuration,
        chapters: List<dynamic>.from(chapters ?? const []),
        itemSnapshot: itemSnapshot,
        episodeId: episodeId,
        episodeTitle: episodeTitle,
        libraryId: libraryId,
        positionSec: clampedStart,
      );
      _idleNotificationTarget = target;
      _pushIdleMediaItem(force: true);
      if (target.chapters.isEmpty) {
        unawaited(_hydrateIdleChapters(target, itemId, episodeId));
      }
    }
    handler.showIdlePlaybackState();
    unawaited(_refreshIdleNotificationSkips(libraryId));
  }

  /// The idle bar follows the chapter (and gets the chapter's title/buttons)
  /// when the chapter-progress setting is on and the book has chapters.
  bool get idleChapterMode =>
      _notifChapterMode && (_idleNotificationTarget?.chapters.isNotEmpty ?? false);

  /// Chapter under the idle position, in metadata time.
  ({int index, String? title, double start, double end})? get idleChapterBounds {
    final target = _idleNotificationTarget;
    if (target == null || target.chapters.isEmpty) return null;
    final idx = ChapterLookup.indexAtWithGrace(
      target.chapters,
      target.positionSec,
      target.totalDuration,
    );
    if (idx == null) return null;
    final ch = target.chapters[idx];
    if (ch is! Map) return null;
    final start = (ch['start'] as num?)?.toDouble() ?? 0;
    var end = (ch['end'] as num?)?.toDouble() ?? target.totalDuration;
    if (end < start) end = start;
    if (end <= start && target.totalDuration > start) {
      end = target.totalDuration;
    }
    if (end <= start) return null;
    return (index: idx, title: ch['title'] as String?, start: start, end: end);
  }

  String _lastIdleMediaItemSignature = '';

  /// Push the idle notification's text/art. Uses the same now-playing layout
  /// as playback, so the configured chapter/percent/time-left pieces appear.
  void _pushIdleMediaItem({bool force = false}) {
    final target = _idleNotificationTarget;
    final handler = _handler;
    if (target == null || handler == null) return;
    // Match the playing notification's episode shape: episode as title, show
    // as artist, show as album.
    var linesTitle = target.title;
    var linesAuthor = target.author;
    if (target.episodeId != null &&
        target.episodeTitle != null &&
        target.episodeTitle!.isNotEmpty &&
        target.episodeTitle != target.title) {
      if (linesAuthor.isEmpty) linesAuthor = target.title;
      linesTitle = target.episodeTitle!;
    }
    final bounds = idleChapterBounds;
    final chapter = idleChapterMode ? bounds : null;
    final displayDuration = chapter != null && chapter.end > chapter.start
        ? chapter.end - chapter.start
        : target.totalDuration;
    final labels = _nowPlayingLines(
      title: linesTitle,
      author: linesAuthor,
      chapter: bounds?.title,
      chapterIndex: bounds?.index ?? -1,
      chapterCount: target.chapters.length,
      posSec: target.positionSec,
      totalDuration: target.totalDuration,
    );
    final signature = '${target.notificationKey}|${bounds?.index}|'
        '${labels.title}|${labels.subtitle}|${displayDuration.round()}';
    if (!force && signature == _lastIdleMediaItemSignature) return;
    _lastIdleMediaItemSignature = signature;
    handler.mediaItem.add(MediaItem(
      id: target.notificationKey,
      title: labels.title,
      artist: labels.subtitle,
      album: linesTitle,
      duration: displayDuration > 0
          ? Duration(milliseconds: (displayDuration * 1000).round())
          : null,
      artUri: target.artUri,
    ));
  }

  /// The shelf payload is often minified and carries no chapters. Read the
  /// small chapter cache, then the item cache, so the idle notification can
  /// offer chapter titles/progress/buttons without a network fetch.
  Future<void> _hydrateIdleChapters(
    _IdleNotificationTarget target,
    String itemId,
    String? episodeId,
  ) async {
    List<dynamic>? chapters;
    try {
      if (episodeId == null) chapters = await ChapterCache.read(itemId);
    } catch (_) {}
    if (!identical(_idleNotificationTarget, target)) return;
    if (chapters == null || chapters.isEmpty) {
      Map<String, dynamic>? cached;
      try {
        cached = await target.api.getCachedLibraryItem(itemId);
      } catch (_) {}
      if (!identical(_idleNotificationTarget, target)) return;
      final media = cached?['media'] as Map<String, dynamic>?;
      if (episodeId != null) {
        for (final ep in media?['episodes'] as List<dynamic>? ?? const []) {
          if (ep is Map<String, dynamic> && ep['id'] == episodeId) {
            chapters = ep['chapters'] as List<dynamic>?;
            break;
          }
        }
      } else {
        chapters = media?['chapters'] as List<dynamic>?;
      }
      if (chapters != null && chapters.isNotEmpty) {
        unawaited(ChapterCache.write(
          itemId,
          (cached?['updatedAt'] as num?)?.toInt(),
          chapters,
        ));
      }
    }
    if (!identical(_idleNotificationTarget, target)) return;
    if (chapters == null || chapters.isEmpty) return;
    target.chapters = List<dynamic>.from(chapters);
    _pushIdleMediaItem(force: true);
    _handler?.showIdlePlaybackState();
  }

  /// The skip buttons' icons are baked with the amount; load the amounts for
  /// the idle target's own library (the player's current library is gone).
  Future<void> _refreshIdleNotificationSkips(String? libraryId) async {
    final fwd = await PlayerSettings.getEffectiveForwardSkip(
      libraryId: libraryId,
    );
    final back = await PlayerSettings.getEffectiveBackSkip(
      libraryId: libraryId,
    );
    final handler = _handler;
    if (handler == null || _idleNotificationTarget == null) return;
    handler._cachedForwardSkip = fwd;
    handler._cachedBackSkip = back;
    handler.showIdlePlaybackState();
  }

  /// Move the idle notification's progress bar. Play starts the stored book
  /// from this position; [adjusted] also suppresses the session-start rewind
  /// so the bar and the audio agree.
  void setIdleNotificationPosition(double seconds, {bool adjusted = true}) {
    final target = _idleNotificationTarget;
    if (target == null) return;
    final max = target.totalDuration > 0 ? target.totalDuration : double.infinity;
    target.positionSec = seconds.clamp(0.0, max).toDouble();
    if (adjusted) target.positionAdjusted = true;
    _pushIdleMediaItem();
    _handler?.showIdlePlaybackState();
  }

  /// Jump the idle notification to the previous/next chapter, mirroring the
  /// playing notification's Android prev/next behavior. Returns false when
  /// there is no chapter to land on in that direction.
  bool skipIdleNotificationChapter({required bool forward}) {
    final target = _idleNotificationTarget;
    if (target == null || target.chapters.isEmpty) return false;
    final pos = target.positionSec;
    if (forward) {
      for (final chapter in target.chapters) {
        final start = (chapter as Map<String, dynamic>)['start'] as num?;
        if (start != null && start.toDouble() > pos + 1.0) {
          setIdleNotificationPosition(start.toDouble());
          return true;
        }
      }
      return false;
    }
    double? previous;
    for (final chapter in target.chapters) {
      final start = (chapter as Map<String, dynamic>)['start'] as num?;
      if (start == null) continue;
      if (start.toDouble() < pos - 3.0) {
        previous = start.toDouble();
      } else {
        break;
      }
    }
    setIdleNotificationPosition(previous ?? 0);
    return true;
  }

  Future<void> _playIdleNotificationTarget() async {
    final target = _idleNotificationTarget;
    if (target == null) return;
    final api = target.api;
    debugPrint(
      '[Handler] starting idle notification target ${target.itemId}',
    );
    final error = await playItem(
      api: api,
      itemId: target.itemId,
      title: target.title,
      author: target.author,
      coverUrl: target.coverUrl,
      totalDuration: target.totalDuration,
      chapters: target.chapters,
      itemSnapshot: target.itemSnapshot,
      startTime: target.positionSec,
      forceStartTime: target.positionAdjusted,
      episodeId: target.episodeId,
      episodeTitle: target.episodeTitle,
      libraryId: target.libraryId,
      fromUi: false,
    );
    if (error != null) {
      // Failed to start the retargeted book: keep the notification's Play
      // target alive so a second press can retry instead of falling into the
      // cold-start/history path.
      if (_currentItemId == null) {
        _idleNotificationTarget = target;
        _pushIdleMediaItem(force: true);
        _handler?.showIdlePlaybackState();
      }
      debugPrint('[Handler] idle notification play failed: $error');
    }
  }

  Future<String?> _playItemImpl({
    required ApiService api,
    required String itemId,
    required String title,
    required String author,
    required String? coverUrl,
    required double totalDuration,
    required List<dynamic> chapters,
    // The caller's shelf/library-item payload for this book. When it carries
    // per-file audio (media.audioFiles, or an episode's audioFile), playItem
    // shapes a direct-file session from it and starts immediately instead of
    // waiting on /play or an expanded item fetch.
    Map<String, dynamic>? itemSnapshot,
    double startTime = 0,
    bool forceStartTime = false,
    String? episodeId,
    String? episodeTitle,
    String? libraryId,
    String? seriesId,
    // Started from the app's own screen. Only those wait (briefly, capped)
    // for the server's saved position before audio; plays from Android
    // Auto, the widget, headphones or a cold-start restore begin at the
    // phone's own position immediately. See play().
    bool fromUi = false,
    // Load the item into the player at its resume position but leave it
    // paused, with no playback session: a headset press then always has a
    // live target and the live transcript can build its runway, without
    // deciding for the user that audio starts now. Downloaded items only -
    // a streamed item plays normally.
    bool loadOnly = false,
    // Automatic recoveries (stream retry, stall rebuild) pass false so a
    // start issued while the user had PAUSED keeps that intent: playItem
    // would otherwise clear [_pauseRequested] at this line and every load
    // path's `if (!_pauseRequested) play()` would start audio the user never
    // asked for. User-initiated starts (play/playNow, UI taps) keep the
    // default true.
    bool clearPauseRequest = true,
  }) async {
    _cancelPendingSessionClients();
    _cancelStartClients();
    // Keep an in-flight item fetch for THIS item: the start can reuse it
    // below instead of canceling it and paying for a duplicate request.
    // Every other background read is dropped so the start owns the pipe.
    final inFlightItemFetch = api.backgroundItemFetchFor(itemId);
    api.cancelBackgroundItemTransfers(
      keepItemId: inFlightItemFetch != null ? itemId : null,
    );
    // TEMP latency diagnostics.
    _startTrace = Stopwatch()..start();
    _startSourceRequestedGeneration = null;
    _startProgressGeneration = null;
    _lastStartProgressAt = null;
    debugPrint(
      '[StartTrace] 0ms playItem item=$itemId ep=$episodeId fromUi=$fromUi '
      'snapshot=${itemSnapshot != null} '
      'inFlightItem=${inFlightItemFetch != null} '
      'downloaded=${_downloadService.isDownloaded(itemId)}',
    );
    if (clearPauseRequest) _pauseRequested = false;
    _finishedHeld = false;
    _playFromUi = fromUi;
    if (_handler == null) {
      debugPrint('[Player] Handler not yet initialized, waiting…');
      await _initCompleter.future;
    }
    if (_handler == null) {
      debugPrint('[Player] Handler init failed, cannot play');
      return _l10n()?.playerErrorInit ?? 'Player failed to initialize';
    }
    final idleTarget = _idleNotificationTarget;
    final startingFromIdle = _handler?._idleNowPlayingState == true &&
        idleTarget != null &&
        idleTarget.itemId == itemId &&
        idleTarget.episodeId == episodeId;
    _keepIdleNotificationUntilMediaPush = startingFromIdle;
    if (!startingFromIdle) {
      // Keep the idle metadata alive while its own book is starting so the
      // held idle state still renders the saved position/chapter; a start of
      // anything else replaces it immediately.
      _idleNotificationTarget = null;
      _handler?.clearIdlePlaybackState();
    }

    // Don't start local playback while casting
    final cast = ChromecastService();
    if (cast.isCasting) {
      debugPrint('[Player] Cast active - skipping local playback');
      return null;
    }

    _beginAdvanceBuffering();

    final playbackGeneration = ++_playbackGeneration;

    // Stop old audio immediately so it doesn't keep playing while the new
    // source is loading (avoids briefly hearing the previous book).
    await _player?.pause();

    // Podcast episodes arrive two ways: episode-shaped (title = the episode)
    // and show-shaped continue/queue entries (title = the show, episodeTitle =
    // the episode, author often blank). Normalise to episode-as-title +
    // show-as-artist so the episode shows everywhere — notification, lock
    // screen, Android Auto, and the server listening session.
    if (episodeId != null &&
        episodeTitle != null &&
        episodeTitle.isNotEmpty &&
        episodeTitle != title) {
      if (author.isEmpty) author = title; // `title` is the show name here
      title = episodeTitle;
    }

    // Keep the caller's start on screen while the real resume position is
    // resolved below. Zeroing it made chapter resolution fall back to the
    // item's first chapter for the whole pre-load window on restarts. When an
    // idle re-init passes no start (0), the engine's current position is still
    // this same item's, so use it as the pre-load guess.
    final sameItem =
        _currentItemId == itemId && _currentEpisodeId == episodeId;
    final engineGuess = sameItem ? position.inMilliseconds / 1000.0 : 0.0;
    final resumeGuess = startTime > 0
        ? startTime
        : forceStartTime
        ? 0.0
        : (engineGuess > 0
              ? engineGuess
              : (sameItem ? _lastKnownPositionSec : 0.0));
    // Cancel the old item's listeners BEFORE the new ids/pending position are
    // published: a stale position tick landing during the awaits below would
    // save progress under the NEW item's key (usually 0 at this point) and
    // wipe the position the start is about to read.
    _syncSub?.cancel();
    _syncSub = null;
    _completionSub?.cancel();
    _completionSub = null;
    _nativeAutoAdvanceSub?.cancel();
    _nativeAutoAdvanceSub = null;
    _indexSub?.cancel();
    _indexSub = null;
    _lastKnownPositionSec = 0;
    _lastSeekTargetSec = null;
    _isCompletingBook = false;
    _lastIndexAdvanceTime = null;
    _chapterJumpLatchIndex = -1;
    _lastNotifiedChapterIndex = -1;
    _clearPendingLoadIntent(clearPlayRequest: true);
    _isLoadingNewItem = true;
    _pendingStartSec = resumeGuess;
    _lastSeekTargetSeconds = null;
    _lastSeekTime = null;
    _seekedWhilePaused = false;
    _pausedAtS = null;
    _resumeAnchorS = null;
    _api = api;
    _currentItemId = itemId;
    _currentSeriesId = seriesId;
    _currentEpisodeId = episodeId;
    _currentLibraryId = libraryId;
    debugPrint(
      '[SkipDebug] playItem libraryId=$libraryId seriesId=$seriesId (item=$itemId ep=$episodeId)',
    );
    _resolveMissingLibraryId(itemId, episodeId);
    _syncNotifSkipCache();
    // Reset local-session mode for every new play; _playFromLocal re-enables it
    // for downloaded items. Without this it leaks from a prior downloaded play
    // into a following streaming play and misroutes the listening time.
    _localSessionMode = false;
    _localSessionAccounting = false;
    _presenceSessionRetryAfter = null;
    _localPlayableChapterIndices = const [];
    _isPartialLocalPlay = false;
    _localCoverageEndSec = null;
    _parkedAtBoundary = false;
    _parkedBoundaryChapterIdx = null;
    _sourceIsNetwork = false;
    _pendingLoadOnlySession = null;
    _currentEpisodeTitle = episodeTitle;
    _currentTitle = title;
    _currentAuthor = author;
    _currentNarrator = null;
    _currentSeries = null;
    _currentCoverUrl = coverUrl;
    _totalDuration = totalDuration;
    _metaDuration = totalDuration;
    _chapters = chapters;
    _shortLocalDurationSec = null; // re-evaluated per source in _playFromLocal
    _handler?.updateChaptersQueue(chapters);
    // Cold-restart gap: minified shelf cards and chapterless session blobs
    // both arrive with no chapters, which leaves chapter switching dead until
    // the network copy of the item lands (tens of seconds on a weak link).
    // Prefer the caller's in-memory payload, then the expanded item usually
    // already on disk from the last browse. Skipped when the caller had
    // chapters.
    if (chapters.isEmpty && itemSnapshot != null) {
      final snapshotChapters = _chaptersFromItem(itemSnapshot, episodeId);
      if (snapshotChapters.isNotEmpty) {
        chapters = snapshotChapters;
        _chapters = snapshotChapters;
        _handler?.updateChaptersQueue(snapshotChapters);
      }
    }
    if (chapters.isEmpty) {
      try {
        final diskItem = await api.getCachedLibraryItem(itemId);
        final seeded = _chaptersFromItem(diskItem, episodeId);
        if (seeded.isNotEmpty) {
          chapters = seeded;
          _chapters = seeded;
          _handler?.updateChaptersQueue(seeded);
          debugPrint(
            '[Player] Seeded ${seeded.length} chapter(s) from the disk item cache',
          );
        }
      } catch (e) {
        debugPrint('[Player] Disk chapter seed failed: $e');
      }
    }
    if (_keepIdleNotificationUntilMediaPush && _chapters.isNotEmpty) {
      // The media session still shows the idle state, which reports a
      // chapter-relative position. Initialize this book's chapter bounds
      // before the state guard drops, so the first live state does not
      // subtract the wrong chapter start and swing the bar.
      _initChapterInfo(_pendingStartSec);
    }
    // New book = fresh session — clear any auto sleep dismissal
    SleepTimerService().resetDismiss();

    // Progress key: compound for episodes, plain for books
    final progressKey = playbackDownloadKey(itemId, episodeId);
    if (totalDuration > 0) {
      _progressSync.rememberServerDuration(progressKey, totalDuration);
    }

    // Notify rolling download listener that a new item is playing
    try {
      await _onPlayStartedCallback?.call(progressKey, totalDuration);
    } catch (e) {
      debugPrint('[Player] Playback-start preparation failed: $e');
    }

    // Check for local saved position (skip if startTime was forced).
    // Always prefer the local position when it's further ahead - the
    // caller's startTime may be stale (e.g. Android Auto browse tree
    // entry cached before the user listened further).
    if (forceStartTime && startTime <= 0) {
      // A forced start at zero legitimately means "begin at the top" (a
      // chapter-sheet tap on chapter 1, a book restart) — but an internal
      // recovery passing a LOST position here is exactly how a resume
      // silently became "playing episode 1". Recovery callers must pass
      // forceStartTime only when they hold a real position (see
      // _attemptStreamRetry); this log pairs with the [PlayItemEntry] stack
      // above to make any regression traceable.
      debugPrint(
        '[PlayItemEntry] Forced start at 0s — restart intent or lost position?',
      );
    }
    final localProgressAtStart = await _progressSync.getLocal(progressKey);
    final localPos =
        (localProgressAtStart?['currentTime'] as num?)?.toDouble() ?? 0;
    var localTimestampAtStart =
        (localProgressAtStart?['timestamp'] as num?)?.toInt() ?? 0;
    if (localPos > 0 && !forceStartTime) {
      if (startTime == 0 || localPos > startTime + 1.0) {
        debugPrint(
          '[Player] Resuming from local position: ${localPos}s (caller startTime was ${startTime}s)',
        );
        startTime = localPos;
      }
    }

    // The widget stash is independent of the scoped SharedPreferences cache.
    // That matters on Android Auto cold starts, where a long-lived headless
    // engine can have an older browse entry and an older preferences snapshot.
    if (!forceStartTime) {
      final stashedPos = await HomeWidgetService().getStashedNowPlayingPosition(
        itemId,
        episodeId,
      );
      final newerStashedPos = HomeWidgetService.newerStashedNowPlayingPosition(
        startTime,
        stashedPos,
      );
      if (newerStashedPos != null) {
        debugPrint(
          '[Player] Resuming from stashed widget position: ${newerStashedPos}s (was ${startTime}s)',
        );
        startTime = newerStashedPos;
        localTimestampAtStart = DateTime.now().millisecondsSinceEpoch;
      }
      // iOS: the shared engine may be playing this very item right now (the
      // native core started it from a headset press and Dart never adopted
      // it). Its position is the live truth - the stash was written once at
      // press time and local progress stopped at the last pause, so resuming
      // from either threw away everything listened since. The stash match
      // above ties the engine's content to this episode; the engine itself
      // only knows the library item.
      if (Platform.isIOS && (episodeId == null || stashedPos != null)) {
        try {
          final engine = await _player?.engineState();
          if (engine != null &&
              engine.isLoaded &&
              engine.itemId == itemId &&
              engine.globalPositionS > startTime + 1.0) {
            debugPrint(
              '[Player] Resuming from live engine position: '
              '${engine.globalPositionS.toStringAsFixed(1)}s (was ${startTime}s)',
            );
            startTime = engine.globalPositionS;
            localTimestampAtStart = DateTime.now().millisecondsSinceEpoch;
          }
        } catch (_) {}
      }
    }

    // Set seek target early so the UI doesn't flash chapter 1 while loading.
    // Remember the pending start for the whole load so chapter resolution
    // doesn't fall back to the stale previous-book position. A scrub issued
    // while the position above was resolving is newer than that resolution
    // and must keep the target/label; only its value feeds the load below.
    final earlyLoadSeek = _pendingLoadSeekFor(playbackGeneration);
    _pendingStartSec = earlyLoadSeek ?? startTime;
    if (_pendingStartSec > 0) {
      _lastSeekTargetSeconds = _pendingStartSec;
      _lastSeekTime = DateTime.now();
    }
    notifyListeners();

    // Check if downloaded — play locally
    String? result;
    if (episodeId == null &&
        !api.isBookOrbit &&
        NarratedBooks.contains(itemId) &&
        !_downloadService.isDownloaded(progressKey)) {
      // An Audiobookshelf EPUB that reads itself aloud: its audio files play
      // straight out of the EPUB on the server, and otherwise like a download.
      final prefs = await SharedPreferences.getInstance();
      final offline =
          (prefs.getBool('manual_offline_mode') ?? false) || _knownOffline;
      final stream = offline
          ? null
          : await NarrationStream.instance.open(
              api,
              itemId,
              startTime: startTime,
            );
      if (_startSuperseded(playbackGeneration)) {
        return _abandonStart(null, null, 'narration, after opening the stream');
      }
      if (stream == null) {
        debugPrint('[Player] $itemId is narration that is not downloaded and '
            '${offline ? 'this phone is offline' : 'could not be streamed'} - not starting');
        _endAdvanceBuffering();
        _clearState();
        return 'Download this book to play its narration';
      }
      // The stream's timeline is laid on the audio's real lengths.
      totalDuration = stream.duration;
      _totalDuration = stream.duration;
      if (stream.chapters.isNotEmpty) {
        chapters = stream.chapters;
        _chapters = stream.chapters;
        _handler?.updateChaptersQueue(stream.chapters);
      }
      if (inFlightItemFetch != null) api.cancelBackgroundItemTransfer(itemId);
      _startTraceLog('path=local-narration');
      result = await _playFromLocal(
        progressKey,
        title,
        author,
        coverUrl,
        totalDuration,
        chapters,
        startTime,
        forceStartTime,
        loadOnly,
        playbackGeneration,
        stream,
      );
    } else if (_downloadService.isDownloaded(progressKey)) {
      if (inFlightItemFetch != null) api.cancelBackgroundItemTransfer(itemId);
      _startTraceLog('path=local');
      result = await _playFromLocal(
        progressKey,
        title,
        author,
        coverUrl,
        totalDuration,
        chapters,
        startTime,
        forceStartTime,
        loadOnly,
        playbackGeneration,
      );
    } else {
      // Check offline — don't stream from server. Covers both the manual
      // offline toggle and *real* network loss: with no reachable server a
      // non-downloaded play is never going to stream, so fail fast instead of
      // spinning on timeouts; a downloaded book already took the local path
      // above.
      final prefs = await SharedPreferences.getInstance();
      final manualOffline = prefs.getBool('manual_offline_mode') ?? false;
      if (_startSuperseded(playbackGeneration)) {
        return _abandonStart(null, null, 'before choosing a stream path');
      }
      if (manualOffline || _offline) {
        debugPrint(
          '[Player] Offline (manual=$manualOffline, known=$_knownOffline) '
          '— cannot stream non-downloaded item',
        );
        _endAdvanceBuffering();
        _clearState();
        return _l10n()?.playerErrorNotDownloadedOffline ??
            'This item isn\'t downloaded and offline mode is on';
      }
      // Try to play from cached session metadata first (instant start). When
      // no session has been cached yet, fall back to the last disk-cached
      // library item so a first play can also start instantly from its
      // per-file URLs while the real /play session is opened in the
      // background. Disk-only and short-circuited: repeat plays that already
      // have a session cache pay for no extra read.
      // Cheapest first: the session cache (a /play response's track list), the
      // manifest (file ids only, written whenever the item itself was cached),
      // then the whole disk item. All three build direct file URLs, so none of
      // them needs a playback session. The label rides into the start trace so
      // a slow start can be attributed to the path that produced it.
      Map<String, dynamic>? cachedSession;
      var cacheSource = 'cached-session';
      cachedSession = await SessionCache.load(
        itemId: itemId,
        episodeId: episodeId,
      );
      if (cachedSession == null) {
        cacheSource = 'manifest';
        cachedSession = await _sessionShapeFromManifest(
          itemId,
          episodeId,
          newerThan: itemSnapshot,
        );
      }
      if (cachedSession == null) {
        cacheSource = 'item-cache';
        cachedSession = await _sessionShapeFromCachedItem(
          itemId,
          episodeId,
          newerThan: itemSnapshot,
        );
      }
      if (cachedSession != null) {
        // A session cache can outlive a server-side re-upload or the auth
        // token used by its direct file URLs. Starting from it then costs a
        // 401 + a fresh /play body before audio. Invalidate it up front when
        // the item changed after the save, or when the cache is old enough
        // that a tokened file URL is no longer trustworthy.
        final savedAt = (cachedSession['savedAt'] as num?)?.toInt();
        final itemUpdatedAt = (itemSnapshot?['updatedAt'] as num?)?.toInt();
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        const maxSessionCacheAge = Duration(minutes: 45);
        final tooOld =
            savedAt != null && nowMs - savedAt > maxSessionCacheAge.inMilliseconds;
        final itemChanged = savedAt != null &&
            itemUpdatedAt != null &&
            itemUpdatedAt > savedAt + 60000;
        if (tooOld || itemChanged) {
          debugPrint(
            '[CacheTrace] session cache stale item=$itemId '
            'savedAt=$savedAt itemUpdatedAt=$itemUpdatedAt '
            'ageMs=${nowMs - savedAt} '
            '${itemChanged ? 'item-changed' : 'expired'}',
          );
          unawaited(SessionCache.clear(itemId: itemId, episodeId: episodeId));
          cachedSession = null;
        }
      }
      if (cachedSession != null) {
        // The cached start is instant; the item fetch is not needed.
        if (inFlightItemFetch != null) api.cancelBackgroundItemTransfer(itemId);
        _startTraceLog('path=$cacheSource');
        // Race the real session against the cache. When the server answers
        // inside the window (LAN, good WiFi) the play starts through the
        // fresh path with tokenless session URLs - immune to token expiry -
        // and its saved position; only a slow server falls back to the
        // instant cached start. Every caller keeps the short window so a slow
        // /play cannot hold audio back; the background refresh still opens the
        // session and logs cross-device progress after play has begun. The
        // in-flight POST is handed to the background refresh either way so a
        // second session is never opened.
        //
        // Started ONLY when the server compresses its API JSON. An uncompressed
        // server answers /play with several MB (measured: 4.2 MB on a
        // 1122-track book), and on a slow tunnel that body steals the pipe from
        // the first audio bytes: a cached start that should be instant sat 16s
        // in setAudioSource while two /play bodies downloaded. With `false`
        // recorded by the compression probe, the cache wins outright and the
        // session is opened afterwards by _refreshServerSession, once audio is
        // already running.
        final raceSession = api.serverCompressionSupported != false;
        // A session may already be opening (a launch restore's resume refresh,
        // a rebuild, another start): join it instead of paying for a second
        // multi-MB /play that only competes with the first audio bytes.
        final sharedInFlight =
            _sharedSessionStarts[_sessionStartKey(itemId, episodeId)];
        final sessionGate = NetBodyGate();
        final pendingSession =
            sharedInFlight ??
            (raceSession
                ? _startSessionRequest(
                    api: api,
                    itemId: itemId,
                    episodeId: episodeId,
                    onProgress: (_) => _markStartProgress(playbackGeneration),
                    bodyGate: sessionGate,
                    timeout: const Duration(seconds: 40),
                  )
                : null);
        // Only a request opened here may be held back by the gate; a shared one
        // is already downloading for another caller.
        final ownsPendingSession = sharedInFlight == null && pendingSession != null;
        // Both UI and external starts keep the short window: a slow /play
        // must not hold cached audio back. The background refresh still opens
        // the session (and logs cross-device progress) after play has begun.
        const raceWindow = _sessionRaceWindow;
        Map<String, dynamic>? racedSession;
        try {
          racedSession = pendingSession == null
              ? null
              : await pendingSession.timeout(raceWindow);
        } catch (_) {
          racedSession = null;
        }
        if (racedSession != null) {
          debugPrint(
            '[Player] Session answered within the race window - using fresh path',
          );
          result = await _playFromServer(
            api,
            itemId,
            title,
            author,
            coverUrl,
            totalDuration,
            chapters,
            startTime,
            forceStartTime: forceStartTime,
            preFetchedSession: racedSession,
            generation: playbackGeneration,
          );
        } else {
          // Cached audio won (or the race was skipped because this server's
          // /play body is multi-MB). Hold the already-open /play body here:
          // it must not compete with the first audio bytes. The same request
          // resumes after playback starts (or immediately if the cached source
          // fails and needs its fresh tracks).
          if (ownsPendingSession) {
            sessionGate.close();
            debugPrint(
              '[Player] Cached start won race - deferring /play body until audio',
            );
          }
          result = await _playFromSessionCache(
            api,
            itemId,
            title,
            author,
            coverUrl,
            totalDuration,
            chapters,
            startTime,
            cachedSession,
            localTimestampAtStart,
            playbackGeneration,
            forceStartTime,
            pendingSession,
            ownsPendingSession ? sessionGate : null,
          );
          // Fall through to normal server path if cache was stale/invalid.
          // The cached path never consumed the in-flight POST on this route,
          // so hand its result over instead of opening a second session.
          if (result == 'cache-miss') {
            Map<String, dynamic>? lateSession;
            if (pendingSession != null) {
              try {
                lateSession = await pendingSession;
              } catch (_) {}
            }
            result = await _playFromServer(
              api,
              itemId,
              title,
              author,
              coverUrl,
              totalDuration,
              chapters,
              startTime,
              forceStartTime: forceStartTime,
              preFetchedSession: lateSession,
              generation: playbackGeneration,
            );
          }
        }
      } else {
        // A cold continue-listening entry has no disk session or item. When
        // the screen that started the play already holds the item (the card
        // on screen does), shape the per-file tracks from it and start
        // immediately. Waiting for /play or the expanded item fetch here is
        // what made a first play take up to half a minute on a weak link.
        final snapshotSession = itemSnapshot == null
            ? null
            : _sessionShapeFromItem(progressKey, itemSnapshot, api);
        if (snapshotSession != null) {
          // The shelf snapshot is enough to start; the background item fetch
          // is no longer needed.
          if (inFlightItemFetch != null) {
            api.cancelBackgroundItemTransfer(itemId);
          }
          _startTraceLog('path=snapshot');
          // The snapshot already carries the tracks. Do not start /play here:
          // one source path at a time, and the background refresh can open the
          // session after audio has started.
          result = await _playFromSessionCache(
            api,
            itemId,
            title,
            author,
            coverUrl,
            totalDuration,
            chapters,
            startTime,
            snapshotSession,
            localTimestampAtStart,
            playbackGeneration,
            forceStartTime,
            null,
          );
          // Snapshot shaped but unusable (e.g. no playable URL): fall back to
          // the normal server path sequentially, never alongside the source.
          if (result == 'cache-miss') {
            result = await _playFromServer(
              api,
              itemId,
              title,
              author,
              coverUrl,
              totalDuration,
              chapters,
              startTime,
              forceStartTime: forceStartTime,
              generation: playbackGeneration,
            );
          }
        } else {
          final compressionSupported =
              api.serverCompressionSupported == true;
          if (inFlightItemFetch != null) {
            // An item read is already consuming the pipe. Use it instead of
            // adding /play on top of it.
            _startTraceLog('path=item-only prefetch=true');
            result = await _playFromItemOnly(
              api,
              itemId,
              title,
              author,
              coverUrl,
              totalDuration,
              chapters,
              startTime,
              progressKey,
              localTimestampAtStart,
              playbackGeneration,
              forceStartTime: forceStartTime,
              prefetchedItem: inFlightItemFetch,
            );
          } else if (compressionSupported) {
            // Compressed servers make /play cheap and give us a public
            // session track; do not also fetch the item.
            _startTraceLog('path=server-only');
            result = await _playFromServer(
              api,
              itemId,
              title,
              author,
              coverUrl,
              totalDuration,
              chapters,
              startTime,
              forceStartTime: forceStartTime,
              generation: playbackGeneration,
            );
          } else {
            // Uncompressed servers still return multi-MB /play JSON; start
            // from the item only, and fall back to /play only if that path
            // fails.
            _startTraceLog('path=item-only prefetch=false');
            result = await _playFromItemOnly(
              api,
              itemId,
              title,
              author,
              coverUrl,
              totalDuration,
              chapters,
              startTime,
              progressKey,
              localTimestampAtStart,
              playbackGeneration,
              forceStartTime: forceStartTime,
            );
          }
        }
      }
    }

    // A start that lost leaves the loading flags to the one that won, which
    // may still be loading.
    if (_startSuperseded(playbackGeneration)) return null;

    final intentTarget = _pendingLoadSeekGeneration == playbackGeneration
        ? _pendingLoadSeekSec
        : null;
    final intentApply = intentTarget != null ? _pendingLoadSeekApply : null;
    final intentAutoPlay = _pendingLoadAutoPlay;
    final playRequested = _playRequestedDuringLoad;
    _clearPendingLoadIntent(clearPlayRequest: true);
    if (result == null && intentTarget != null) {
      // Keep the UI pinned to the requested position while the re-seek below
      // is issued.
      _pendingStartSec = intentTarget;
      _lastSeekTargetSeconds = intentTarget;
      _lastSeekTime = DateTime.now();
    }
    _isLoadingNewItem = false;
    if (result != null) {
      _endAdvanceBuffering();
      _lastSeekTargetSeconds = null;
      _lastSeekTime = null;
      // The failed load can leave the engine stuck in `loading` with no start
      // behind it - the UI then spins until some later tap replaces the source
      // (the "loading, then suddenly paused" report). Settle it to idle now so
      // the failure is visible immediately. Skip if a newer start already
      // claimed the service; its source is not ours to stop.
      if (_currentItemId == null || _currentItemId == itemId) {
        try {
          await _player?.stop();
        } catch (_) {}
      }
    }
    notifyListeners();

    // The start loaded its own source/position after the user's seek, so the
    // request has to be re-applied now that the engine is ready — otherwise
    // playback continues from the pre-seek spot (often the next chapter when
    // the old position sat on a boundary, or chapter 1 when the start landed
    // at 0).
    if (result == null && intentTarget != null) {
      debugPrint(
        '[Player] Applying the load-time seek to '
        '${intentTarget.toStringAsFixed(1)}s',
      );
      if (intentApply != null) {
        await intentApply();
      } else {
        await seekTo(Duration(milliseconds: (intentTarget * 1000).round()));
      }
    }

    // A pause issued while the start was loading must win over the start's
    // own play() and over any queued jump's auto-play. Use the full pause path
    // so the timer/session bookkeeping matches a normal pause too.
    if (_pauseRequested) {
      await pause();
    } else if (result == null &&
        (intentAutoPlay || playRequested) &&
        _player != null &&
        !_player!.playing) {
      debugPrint('[Player] Playing after load — requested while loading');
      await play(logDetail: 'requested while loading', fromUi: true);
    }
    // A seek that belonged to this start is settled now; a later pause/resume
    // must decide its own auto-rewind/adoption.
    if (_player?.playing ?? false) _seekedWhilePaused = false;

    if (result == null &&
        playbackGeneration == _playbackGeneration &&
        !_pauseRequested) {
      _onPlaybackStateChangedCallback?.call(true);
      unawaited(_persistLastUserPlaying(true));
      // Auto-navigate to Absorbing tab when an episode starts playing.
      if (episodeId != null) _onEpisodePlayStartedCallback?.call();
      if (fromUi && episodeId == null) onAppPlay?.call(itemId);
      // Advanced chapter-track alignment: fires only when this book's chapter
      // count differs from its track count (server updated tracks without
      // rebuilding chapters); see alignChaptersWithTracksIfStale for the
      // fetch budget — zero requests in the common case, a POST only on a
      // real mismatch.
      unawaited(alignChaptersWithTracksIfStale());
    }
    return result;
  }

  /// Session-start rewind (setting): pull a new session's start position back
  /// by maxRewind so playback opens with a little re-orientation. Scaled by
  /// speed so the perceived amount is the same at 1.5x, and capped at the
  /// chapter start when the barrier is on. Applied to the start position
  /// BEFORE the first seek - it used to run after play() and audibly jumped
  /// 50-90ms into live audio. Callers pass the speed they're about to set.
  Future<double> _sessionStartRewound(
    double startTime, {
    required bool forceStartTime,
    required double speed,
  }) async {
    if (forceStartTime || startTime <= 0) return startTime;
    final rewindSettings = await AutoRewindSettings.load();
    if (!rewindSettings.enabled || !rewindSettings.sessionStartRewind) {
      return startTime;
    }
    final rewindSeconds = rewindSettings.maxRewind;
    if (rewindSeconds <= 0.5) return startTime;
    var newPos = startTime - (rewindSeconds * speed);
    if (newPos < 0) newPos = 0;
    if (rewindSettings.chapterBarrier && _chapters.isNotEmpty) {
      for (final ch in _chapters) {
        final start = (ch['start'] as num?)?.toDouble() ?? 0;
        final end = (ch['end'] as num?)?.toDouble() ?? 0;
        if (startTime >= start && startTime < end) {
          if (newPos < start) newPos = start;
          break;
        }
      }
    }
    final actualDelta = startTime - newPos;
    if (actualDelta <= 0) return startTime;
    final detail = speed == 1.0
        ? '${rewindSeconds.toStringAsFixed(1)}s (session start)'
        : '${rewindSeconds.toStringAsFixed(1)}s (${actualDelta.toStringAsFixed(1)}s at ${speed.toStringAsFixed(2)}x, session start)';
    _logEvent(PlaybackEventType.autoRewind, detail: detail);
    debugPrint(
      '[Player] Session-start rewind ${rewindSeconds.toStringAsFixed(1)}s '
      '(${actualDelta.toStringAsFixed(1)}s at ${speed.toStringAsFixed(2)}x) '
      '-> starting at ${newPos.toStringAsFixed(1)}s',
    );
    return newPos;
  }

  /// Fold the per-item intro skip into a start position that would land inside
  /// the intro window, so the opening words never play at all.
  ///
  /// The live skip only runs once the engine reports position ticks, and only
  /// outside the 3s window that protects a deliberate seek - so a start at a
  /// chapter's beginning played a few seconds of intro and then jumped to the
  /// configured mark. The pre-buffered next item already folds the same setting
  /// into its start before the first byte ([_preloadNextBookAsync]); an item's
  /// OWN start had no such pre-jump. The guards mirror the live skip: the
  /// setting is on with a real length, and the target still leaves audio inside
  /// the chapter (a chapter shorter than the intro must not be skipped over).
  Future<double> _introSkipPreJump(double startSec, double totalDuration) async {
    if (_chapters.isEmpty || _currentItemId == null) return startSec;
    final idx = ChapterLookup.indexAtWithGrace(
      _chapters,
      startSec,
      totalDuration > 0 ? totalDuration : _metaDuration,
    );
    if (idx == null) return startSec;
    final chapterStart = ChapterLookup.metaStart(_chapters, idx);
    if (startSec < chapterStart) return startSec;
    final settings = await ChapterSkipSettings.loadForItem(_mediaItemKey);
    if (!settings.enabled || settings.introSkipSeconds <= 0) return startSec;
    final introSkip = settings.introSkipSeconds.toDouble();
    final target = chapterStart + introSkip;
    // Already at or past the mark, or never inside the window.
    if (startSec >= target || startSec - chapterStart >= introSkip) {
      return startSec;
    }
    // The chapter's end in the same (metadata) timeline the saved position
    // lives on: the next chapter's start when there is one, else the book's.
    final chapterEnd = idx + 1 < _chapters.length
        ? ChapterLookup.metaStart(_chapters, idx + 1)
        : ((_chapters[idx] as Map)['end'] as num?)?.toDouble() ??
              (totalDuration > 0 ? totalDuration : _metaDuration);
    if (chapterEnd > chapterStart && chapterEnd - target < 1.0) {
      debugPrint(
        '[ChapterSkip] Start pre-jump suppressed: chapter '
        '${chapterStart.toStringAsFixed(1)}-${chapterEnd.toStringAsFixed(1)}s '
        'leaves nothing after ${target.toStringAsFixed(1)}s',
      );
      return startSec;
    }
    debugPrint(
      '[ChapterSkip] Start pre-jump intro: ${startSec.toStringAsFixed(1)}s -> '
      '${target.toStringAsFixed(1)}s (chapter $idx, intro '
      '${settings.introSkipSeconds}s)',
    );
    return target;
  }

  // A finished download waiting for a quiet moment to take over from the
  // stream: the progress key of the item, and the start it belongs to.
  String? _pendingLocalSwapKey;
  int _pendingLocalSwapGeneration = -1;
  /// A download finished for [itemId]. Moving a playing stream onto the files
  /// means reloading the source, a short gap in the middle of a sentence, and
  /// nothing is wrong with the stream, so while audio is running the move
  /// waits for the next pause or seek, where a reload cannot be heard. Paused,
  /// it happens now. A stream that errors before then restarts through
  /// playItem, which picks the files up by itself.
  Future<bool> switchToLocal(String itemId) async {
    final currentItemId = _currentItemId;
    if (currentItemId == null ||
        playbackDownloadKey(currentItemId, _currentEpisodeId) != itemId) {
      return false;
    }
    if (!_downloadService.isDownloaded(itemId)) return false;
    if (_player == null || _localSessionMode) return false;

    _pendingLocalSwapKey = itemId;
    _pendingLocalSwapGeneration = _playbackGeneration;
    if (_player!.playing) {
      debugPrint(
        '[Player] Download finished - holding the move to local files for the next pause or seek',
      );
      return true;
    }
    return _applyPendingLocalSwap(resumeAfter: false);
  }

  /// Where a source rebuild should land. While paused the engine's own
  /// reading can already be the reset value the swap is trying to hide, so
  /// the pause anchor wins whenever no explicit target was supplied.
  double _sourceSwapTarget(double? seekToSeconds, {
    required bool resumeAfter,
  }) {
    if (seekToSeconds != null) {
      return seekToSeconds.clamp(0.0, double.infinity).toDouble();
    }
    final live = position.inMilliseconds / 1000.0;
    final anchor = _resumeAnchorS;
    if (!resumeAfter && anchor != null) {
      if ((live - anchor).abs() > 2.0) {
        debugPrint(
          '[Player] Source swap while paused: engine reported '
          '${live.toStringAsFixed(1)}s but the pause spot is '
          '${anchor.toStringAsFixed(1)}s - using the pause spot',
        );
      }
      return anchor;
    }
    return live;
  }

  /// Move the source onto the finished download. Called only where playback
  /// is already interrupted (paused, mid-seek, or a source that has to be
  /// rebuilt anyway), so the reload rides inside that interruption. The files
  /// load straight at [seekToSeconds] (or the current position) - no start at
  /// zero followed by a seek. Returns true when the move happened and already
  /// landed there; the caller must then skip its own seek.
  Future<bool> _applyPendingLocalSwap({
    double? seekToSeconds,
    bool resumeAfter = false,
  }) async {
    final key = _pendingLocalSwapKey;
    if (key == null || _player == null) return false;
    final currentItemId = _currentItemId;
    if (_pendingLocalSwapGeneration != _playbackGeneration ||
        currentItemId == null ||
        playbackDownloadKey(currentItemId, _currentEpisodeId) != key ||
        _localSessionMode ||
        !_downloadService.isDownloaded(key)) {
      _pendingLocalSwapKey = null;
      return false;
    }
    // While casting, the local player isn't the real output - keep the move
    // for when local playback matters again.
    if (ChromecastService().isCasting) return false;
    final localPaths = _downloadService.getLocalPaths(key);
    if (localPaths == null || localPaths.isEmpty) {
      _pendingLocalSwapKey = null;
      return false;
    }
    _pendingLocalSwapKey = null; // one-shot, success or not

    final currentSpeed = _player!.speed;
    // Audio that ran up to this moment is still owed to the stream session.
    // Paused, the pause sync already reported the tail and the span since is
    // idle time, not listening.
    final finalStreamingSeconds = !resumeAfter
        ? 0
        : DateTime.now().difference(_lastServerSync).inSeconds.clamp(0, 300);
    final target = _sourceSwapTarget(seekToSeconds, resumeAfter: resumeAfter);
    debugPrint(
      '[Player] Moving to local files at ${target.toStringAsFixed(1)}s (resume=$resumeAfter)',
    );

    // Track durations from the download's stored session, for multi-file
    // seeking. Same book, so the offsets match the stream's; without them
    // the stream's own are kept when they fit the files.
    final cachedJson = _downloadService.getCachedSessionData(key);
    List<dynamic>? audioTracks;
    List<double>? absoluteStarts;
    if (cachedJson != null) {
      try {
        final session = jsonDecode(cachedJson) as Map<String, dynamic>;
        audioTracks = session['audioTracks'] as List<dynamic>?;
        absoluteStarts = (session['trackStartOffsets'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList();
        _applyTrackToChapterFromSession(session);
      } catch (_) {}
    }
    // A PARTIAL download that doesn't include where the listener actually is
    // must not hot-swap: the replacement source would only contain the
    // downloaded subset, so the preserved position would clamp past its end and
    // playback would collapse onto the first downloaded chapter (e.g. playing
    // chapter 11 while chapter 1's download finishes → clamp to chapter 1's end
    // → auto-advance to "next" / pause with the wrong title). Only swap when
    // the target position falls inside a downloaded track's playback range;
    // whole-item downloads always qualify.
    if (audioTracks != null &&
        absoluteStarts != null &&
        absoluteStarts.length == audioTracks.length) {
      var covered = false;
      for (var i = 0; i < audioTracks.length; i++) {
        final start = absoluteStarts[i];
        final dur =
            ((audioTracks[i] as Map<String, dynamic>)['duration'] as num?)
                ?.toDouble() ??
            0;
        if (target >= start - 0.5 && target < start + dur - 0.5) {
          covered = true;
          break;
        }
      }
      if (!covered) {
        debugPrint(
          '[Player] Skip hot-swap: download does not cover current position '
          '${target.toStringAsFixed(1)}s (partial download of another chapter)',
        );
        return false;
      }
    }

    // Rebuild track offsets for local files
    if (audioTracks != null && audioTracks.length == localPaths.length) {
      _buildTrackOffsets(audioTracks, absoluteStarts: absoluteStarts);
    } else if (_trackStartOffsets.length - 1 != localPaths.length) {
      _trackStartOffsets = [0.0];
      _trackDurations = [];
    }

    var oldSourceGone = false;
    try {
      var idx = 0;
      for (int i = 0; i < _trackStartOffsets.length - 1; i++) {
        if (target < _trackStartOffsets[i + 1] ||
            i == _trackStartOffsets.length - 2) {
          idx = i;
          break;
        }
      }
      final trackStart = idx < _trackStartOffsets.length
          ? _trackStartOffsets[idx]
          : 0.0;
      final localPos = Duration(
        milliseconds: ((target - trackStart) * 1000).round(),
      );
      // Stamp the seek target so position readers (UI, progress save) hold at
      // the target while the files load instead of flashing 0.
      _lastSeekTargetSeconds = target;
      _lastSeekTime = DateTime.now();

      final trackSources = localPaths.map((p) => localAudioSource(p)).toList();
      final source = ConcatenatingAudioSource(children: trackSources);
      _pendingSessionUpgrade = null; // going local, its URLs no longer matter
      _resetPreBufferState();
      // Update index BEFORE loading so positionStream events use the right offset
      _currentTrackIndex = idx;
      oldSourceGone = true;
      await _player!.setAudioSource(
        source,
        initialIndex: idx,
        initialPosition: localPos,
        itemId: _currentItemId,
      );
      _activeConcatSource = source;
      _currentBookTrackCount = trackSources.length;
      _subscribeTrackIndex();
      await _player!.setSpeed(currentSpeed);
      if (resumeAfter) _player!.play();

      await _switchHotSwapReportingToLocal(
        position: Duration(milliseconds: (target * 1000).round()),
        streamingSeconds: finalStreamingSeconds,
      );

      _logEvent(PlaybackEventType.play, detail: 'Switched to local playback');
      debugPrint('[Player] Now playing from local files');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[Player] Move to local files failed: $e');
      if (!oldSourceGone) return false;
      // The stream's source went with the failed load, so there is nothing
      // left for the caller to seek. When audio should be running, restart
      // through the normal path at the spot this was heading for; it falls
      // back to the server if the files really are unreadable. Paused, the
      // next play re-initialises the idle player.
      _lastKnownPositionSec = target;
      if (resumeAfter) unawaited(_attemptStreamRetry(e));
      return true;
    }
  }

  Future<void> _switchHotSwapReportingToLocal({
    required Duration position,
    required int streamingSeconds,
  }) async {
    if (_localSessionMode || _currentItemId == null) return;

    final api = _api;
    final streamingSessionId = _playbackSessionId;
    final progressKey = playbackDownloadKey(_currentItemId!, _currentEpisodeId);
    final currentTime = position.inMilliseconds / 1000.0;

    try {
      await LocalSessionService().beginSession(
        progressKey: progressKey,
        libraryItemId: _currentItemId!,
        episodeId: _currentEpisodeId,
        mediaType: _currentEpisodeId != null ? 'podcast' : 'book',
        duration: _totalDuration,
        startTime: currentTime,
        displayTitle: _currentTitle,
        displayAuthor: _currentAuthor,
      );
    } catch (e) {
      debugPrint('[Player] Failed to start LOCAL reporting after hot-swap: $e');
      return;
    }

    _logEvent(PlaybackEventType.sessionEnd, detail: 'stream hot-swap');
    _localSessionMode = true;
    // The stream was swapped for local files: the source no longer touches
    // the network, so offline guards must stop treating it as remote.
    _sourceIsNetwork = false;
    _playbackSessionId = null;
    _activeStreamUrls = const [];
    _activeStreamHeaders = const {};
    _lastServerSync = DateTime.now();
    _lastAccrual = _lastServerSync;
    _lastAccrualPos = null;
    _logEvent(PlaybackEventType.sessionStart, detail: 'local hot-swap');

    if (api == null || streamingSessionId == null) return;

    try {
      final pendingBefore = await _progressSync.getStreamingPendingTime(
        progressKey,
      );
      final synced = await api.syncPlaybackSession(
        streamingSessionId,
        currentTime: currentTime,
        duration: _totalDuration,
        timeListened: streamingSeconds,
      );
      if (synced) {
        if (streamingSeconds > 0) {
          unawaited(
            _progressSync.addTimeSaved(streamingSeconds, _player?.speed ?? 1.0),
          );
          unawaited(
            HomeWidgetService().addLocalListeningSeconds(streamingSeconds),
          );
        }
        if (pendingBefore > 0) {
          unawaited(
            _progressSync.reduceStreamingPendingTime(
              progressKey,
              pendingBefore,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[Player] Failed to finalize streaming hot-swap session: $e');
    }

    try {
      await api.closePlaybackSession(streamingSessionId);
    } catch (_) {}
  }

  Future<String?> _playFromLocal(
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime, [
    bool forceStartTime = false,
    bool loadOnly = false,
    int? generation,
    // A narration streamed out of its EPUB on the server: its files and
    // timeline stand in for a download's.
    NarrationStreamSource? stream,
  ]) async {
    final gen = generation ?? _playbackGeneration;
    if (_startSuperseded(gen)) return null;
    // This start's ids, read before anything awaits. The shared fields belong
    // to a newer start as soon as one begins.
    final rawItemId = _currentItemId!;
    final episodeId = _currentEpisodeId;
    debugPrint(stream != null
        ? '[Player] Streaming the narration out of the EPUB: $title'
        : '[Player] Playing from local files: $title');
    // Alpha [PodDur]: trace podcast-episode duration loading. Symptom:
    // Android Auto progress bar missing for ~60s on cold-start podcast play
    // because the first MediaItem push carries dur=0. We want to know what
    // value arrived at this function, and what's available from nearby state.
    debugPrint(
      '[PodDur] _playFromLocal entry: itemId=$itemId ep=$_currentEpisodeId totalDurationArg=${totalDuration.toStringAsFixed(1)}s _totalDuration=${_totalDuration.toStringAsFixed(1)}s chapters=${chapters.length}',
    );
    _isOfflineMode = false; // We still sync to server if possible
    _playbackSessionId = null;

    // Check if manual offline mode is on
    final prefs = await SharedPreferences.getInstance();
    final manualOffline = prefs.getBool('manual_offline_mode') ?? false;
    debugPrint('[Player] manualOffline=$manualOffline, api=${_api != null}');

    // Downloaded plays report to the server via the client-owned LOCAL session
    // model (GH #276 Local label, GH #280 per-day attribution), NOT a live
    // /play session. Position still syncs through /me/progress; here we only
    // reconcile the start position against the server's saved progress (when
    // online) the way the /play response used to, sourced from GET /me/progress.
    _localSessionMode = true;
    _sourceIsNetwork = false;
    _parkedAtBoundary = false;
    _parkedBoundaryChapterIdx = null;
    _logEvent(PlaybackEventType.sessionStart, detail: 'local-session');
    // `itemId` here is the progress key (already `id-episodeId` for a podcast),
    // so build the key from the raw parts to avoid double-appending the episode.
    final pKey = episodeId != null ? '$rawItemId-$episodeId' : rawItemId;
    // Reconcile the start position against the server's saved progress before
    // audio begins, capped at [_serverPositionCheckCap]. A play from the app
    // screen always asks. Headphone / widget / Android Auto / cold-start
    // plays of a download skip it while this phone's own save is fresh, so a
    // quick re-press needs nothing from the network (GH #321); once the save
    // is old enough for another device to have carried the book on, they ask
    // too, since starting stale then pushed the old spot over the newer one
    // on the server (GH #430). Whatever position we start with, we keep - no
    // seeking after.
    if (forceStartTime) {
      debugPrint(
        '[Player] Forced start time: ${startTime}s — skipping server/local position comparison',
      );
    } else if (_downloadService.isFromOtherAccount(rawItemId)) {
      // The server signed in now doesn't hold this book's place, and could
      // hold a different book's under the same id.
      debugPrint('[Player] Another account\'s download - playing its spot on this phone, ${startTime.toStringAsFixed(1)}s');
    } else if (!_playFromUi && startTime > 0 && await _localPositionIsFresh(pKey)) {
      debugPrint(
        '[Player] Skipping progress reconcile - not started from the app screen and the local position is fresh, playing ${startTime.toStringAsFixed(1)}s now',
      );
    } else if (_api != null && !manualOffline && !_knownOffline) {
      try {
        const checkCap = _serverPositionCheckCap;
        final serverProgress = await _api!
            .getItemProgress(pKey)
            .timeout(checkCap, onTimeout: () => null);
        final serverPos =
            (serverProgress?['currentTime'] as num?)?.toDouble() ?? 0;
        final serverLastUpdate =
            (serverProgress?['lastUpdate'] as num?)?.toInt() ?? 0;
        final localTs = await _progressSync.getSavedTimestamp(pKey);
        if (serverProgress == null) {
          debugPrint(
            '[Player] Local-play progress check: no answer within ${checkCap.inMilliseconds}ms — using local ${startTime.toStringAsFixed(1)}s',
          );
        } else if ((localTs == 0 || serverLastUpdate > localTs) &&
            serverPos > startTime + 1.0) {
          debugPrint(
            '[Player] Server position is ahead: server=${serverPos}s vs local=${startTime}s — using server',
          );
          startTime = serverPos;
          await _progressSync.saveLocal(
            itemId: itemId,
            currentTime: serverPos,
            duration: totalDuration,
            speed: 1.0,
          );
        } else if (startTime > 0) {
          // Local is ahead — verify via timestamp that this isn't stale data.
          // Skip the override if we have a pending local sync: local is the
          // truth, we just haven't shipped it to the server yet.
          bool useServer = false;
          final hasPending = await _progressSync.hasPendingSync(pKey);
          final gap = startTime - serverPos;
          if (localTs > 0 &&
              !hasPending &&
              gap <= SyncLogic.localAheadSafetySeconds &&
              serverLastUpdate > localTs) {
            debugPrint(
              '[Player] Local position is ahead but stale: local=${startTime}s (ts=$localTs) vs server=${serverPos}s (ts=$serverLastUpdate) — using server',
            );
            startTime = serverPos;
            useServer = true;
            await _progressSync.saveLocal(
              itemId: itemId,
              currentTime: serverPos,
              duration: totalDuration,
              speed: 1.0,
            );
          }
          if (!useServer) {
            if (hasPending) {
              debugPrint(
                '[Player] Local position is ahead: local=${startTime}s vs server=${serverPos}s — keeping local (pending sync)',
              );
            } else if (gap > SyncLogic.localAheadSafetySeconds) {
              debugPrint(
                '[Player] Local position is ahead: local=${startTime}s vs server=${serverPos}s — keeping local (gap ${gap.toStringAsFixed(1)}s exceeds safety threshold)',
              );
            } else {
              debugPrint(
                '[Player] Local position is ahead: local=${startTime}s vs server=${serverPos}s — keeping local',
              );
            }
          }
        } else if (serverPos > 0) {
          debugPrint('[Player] No local position, using server: ${serverPos}s');
          startTime = serverPos;
        }
      } catch (e) {
        debugPrint('[Player] Local-play progress reconcile failed: $e');
      }
    } else {
      debugPrint(
        '[Player] Skipping progress reconcile — manual offline or no API',
      );
    }

    if (_startSuperseded(gen)) {
      return _abandonStart(null, null, 'local, after the position check');
    }
    final localPaths = stream?.urls ?? _downloadService.getLocalPaths(itemId);
    if (localPaths == null || localPaths.isEmpty) {
      debugPrint('[Player] No local files found');
      _clearState();
      return _l10n()?.playerErrorDownloadsMissing ??
          'Downloaded files not found - try re-downloading';
    }

    // Get cached session data for track durations (and chapters if needed)
    final cachedJson = stream != null ? jsonEncode(stream.session) : _downloadService.getCachedSessionData(itemId);
    List<dynamic>? audioTracks;
    List<double>? absoluteStarts;
    if (cachedJson != null) {
      try {
        final session = jsonDecode(cachedJson) as Map<String, dynamic>;
        audioTracks = session['audioTracks'] as List<dynamic>?;
        absoluteStarts = (session['trackStartOffsets'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList();
        _applyTrackToChapterFromSession(session);
        _captureNowPlayingCredits(session);
        // Fall back to the cached session duration when the caller didn't have
        // one (e.g. podcast cold-start from Android Auto pushes dur=0). Replaces
        // the old /play-response duration fallback now that local plays skip it.
        if (totalDuration <= 0) {
          final cachedDur = (session['duration'] as num?)?.toDouble();
          if (cachedDur != null && cachedDur > 0) {
            totalDuration = cachedDur;
            _totalDuration = cachedDur;
          }
        }
        // Pick up chapters from cached session when not already loaded
        if (chapters.isEmpty) {
          final cachedChapters = session['chapters'] as List<dynamic>? ?? [];
          if (cachedChapters.isNotEmpty) {
            chapters = cachedChapters;
            _chapters = cachedChapters;
            _handler?.updateChaptersQueue(cachedChapters);
            debugPrint(
              '[Player] Loaded ${cachedChapters.length} chapters from cached session',
            );
          }
        }
      } catch (_) {}
    }

    try {
      if (_startSuperseded(gen)) {
        return _abandonStart(null, null, 'local, before building the source');
      }
      _currentTrackIndex = 0;

      // Build multi-file track offsets for absolute position tracking
      if (audioTracks != null) {
        _buildTrackOffsets(audioTracks, absoluteStarts: absoluteStarts);
      } else {
        _trackStartOffsets = [0.0]; // single file fallback
        _trackDurations = [];
      }

      // A partial download is missing files, so it legitimately decodes shorter
      // than the full book. Treat the layout as complete only when the persisted
      // starts begin at 0 and reach the end; otherwise local coverage stops
      // wherever the downloaded tracks do.
      final startsCoverBook =
          absoluteStarts != null &&
          absoluteStarts.isNotEmpty &&
          absoluteStarts.first <= 0.001 &&
          _trackDurations.length == absoluteStarts.length &&
          (totalDuration <= 0 ||
              absoluteStarts.last + _trackDurations.last >=
                  totalDuration - _kLocalTruncationMarginSec);
      final isPartialDownload = absoluteStarts != null && !startsCoverBook;
      final localCoverageEnd = _trackStartOffsets.length > 1
          ? _trackStartOffsets.last
          : totalDuration;
      // Boundary bookkeeping for the completion / navigation guards: reaching
      // `localCoverageEnd` ends the DOWNLOAD, not the book.
      _isPartialLocalPlay = isPartialDownload;
      _localCoverageEndSec = isPartialDownload ? localCoverageEnd : null;

      // Partial download: only the chapters whose start is covered by a
      // downloaded track can be reached by prev/next navigation. Jumping at an
      // un-downloaded chapter start seeks into a gap or past the local
      // coverage end (dead seek / phantom "last episode" title), so navigation
      // during the download stays on this subset. Empty for full plays.
      final playableChapters = <int>[];
      if (isPartialDownload && _trackStartOffsets.length > 2) {
        for (var i = 0; i < _chapters.length; i++) {
          final s = ChapterLookup.metaStart(_chapters, i);
          if (_positionCoveredLocally(s)) playableChapters.add(i);
        }
      }
      _localPlayableChapterIndices = playableChapters;
      if (playableChapters.isNotEmpty) {
        debugPrint(
          '[Player] Partial download: ${playableChapters.length}/'
          '${_chapters.length} chapters playable locally '
          '(${playableChapters.join(',')})',
        );
      }

      // Finalize the requested position before the coverage check so a queued
      // seek / near-end restart isn't judged against the older start. The
      // session-start rewind is applied later (once), after a possible
      // streaming hand-off.
      final endBoundary = isPartialDownload ? localCoverageEnd : totalDuration;
      if (endBoundary > 0 && startTime >= endBoundary - 1.0) startTime = 0;
      startTime = _pendingLoadSeekFor(gen) ?? startTime;
      _pinStartPositionForLoad(gen, startTime);

      // The requested position can sit past the last downloaded track or in a
      // gap between downloaded tracks. There is no local audio to seek to -
      // playing locally would clamp to the end of the last file, instantly
      // "complete", and save that end position over the user's real progress
      // (GH #278 in reverse). Stream instead while the server is reachable;
      // offline, fall back to the nearest downloaded track so audio still plays.
      if (isPartialDownload && !_positionCoveredLocally(startTime)) {
        final canStream = _api != null && !manualOffline && !_knownOffline;
        debugPrint(
          '[Player] Local position ${startTime.toStringAsFixed(1)}s is outside '
          'the downloaded range (covers 0-${localCoverageEnd.toStringAsFixed(1)}s) '
          '- ${canStream ? 'streaming instead' : 'clamping to nearest downloaded track'}',
        );
        if (canStream) {
          // Handing off to streaming: the download-boundary navigation subset
          // must not constrain a full-book stream (it would leave next/prev
          // locked to the downloaded chapters).
          _localPlayableChapterIndices = const [];
          return await _playFromServer(
            _api!,
            _currentItemId!,
            title,
            author,
            coverUrl,
            totalDuration,
            chapters,
            startTime,
            forceStartTime: forceStartTime,
          );
        }
        final idx = _trackIndexForAbsolute(startTime);
        startTime = _trackStartOffsets[idx];
        // The queued target has no local audio offline; keep the intent on the
        // clamped track instead of re-seeking to the uncovered spot at load end.
        if (_pendingLoadSeekFor(gen) != null) {
          _pendingLoadSeekSec = startTime;
          _pendingLoadSeekApply = null;
          _pendingStartSec = startTime;
          _lastSeekTargetSeconds = startTime;
          _lastSeekTime = DateTime.now();
        }
      }

      final trackSources = localPaths.map((p) => localAudioSource(p)).toList();
      final source = ConcatenatingAudioSource(children: trackSources);

      final speedKey = _currentItemId ?? itemId;
      final bookSpeed = await PlayerSettings.getBookSpeed(speedKey);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      // A user's queued target is a precise intent; don't session-rewind it.
      startTime =
          _pendingLoadSeekFor(gen) ??
          await _sessionStartRewound(
            startTime,
            forceStartTime: forceStartTime,
            speed: speed,
          );
      // A seek queued while the rewind was resolving is the latest intent.
      startTime = _pendingLoadSeekFor(gen) ?? startTime;
      // Fold the intro skip into the start itself: a start that lands inside
      // the window must not play the opening words while the live skip waits
      // for a position tick. Applied after the session rewind and any queued
      // seek, so the position the engine gets is the final one.
      startTime = await _introSkipPreJump(startTime, totalDuration);
      _pinStartPositionForLoad(gen, startTime);
      final chapterStart = startTime > 0 && _isChapterStartWithin(startTime);
      final landing = _resolveAbsolutePosition(
        startTime,
        chapterJump: chapterStart,
      );
      _currentTrackIndex = landing.index;
      if (chapterStart && _trackStartOffsets.length > 1) {
        _latchChapterJumpTarget(startTime);
      }
      final initialPosition = Duration(
        milliseconds: (landing.localOffset * 1000).round(),
      );

      await _configureAudioSession();
      try {
        final activated = await (await AudioSession.instance).setActive(true);
        debugPrint('[Player] Pre-source setActive(true)=$activated (local)');
      } catch (e) {
        debugPrint('[Player] Pre-source setActive failed (local): $e');
      }
      if (_startSuperseded(gen)) {
        return _abandonStart(null, null, 'local, before loading the source');
      }
      _resetPreBufferState();
      _startTraceLog('setAudioSource start (local)');
      _watchFirstBytes('local');
      _markStartSourceRequested(gen);
      final decoded = await _player!.setAudioSource(
        source,
        initialIndex: landing.index,
        initialPosition: initialPosition,
        itemId: rawItemId,
      );
      _startTraceLog('setAudioSource done (local)');
      if (_startSuperseded(gen)) {
        return _abandonStart(null, null, 'local, after loading the source');
      }
      _activeConcatSource = source;
      _currentBookTrackCount = trackSources.length;

      // Detect an incomplete/corrupt download: the audio on disk decodes to
      // materially less than the book's real length. If we trusted the
      // metadata duration we'd let the user seek past the end of the file,
      // clamp them to ~the file's end on resume, and save that over their real
      // progress (GH #278). Flag it so seeks clamp and saves are protected.
      //
      // Only valid for single-file books. On a multi-file
      // ConcatenatingAudioSource, setAudioSource returns just the first track's
      // duration (the current ExoPlayer window), not the whole book — so this
      // would flag every complete multi-file download as truncated and pin
      // playback to the first track, breaking seek and resume. The single-point
      // _shortLocalDurationSec clamp only models one truncated file anyway.
      final decodedSec = (decoded?.inMilliseconds ?? 0) / 1000.0;
      // A partial download is missing files, so the truncation heuristic must
      // not fire there — it would clamp every seek to the first present track
      // (see the coverage fallback above).
      if (!isPartialDownload &&
          trackSources.length == 1 &&
          totalDuration > 0 &&
          decodedSec > 0 &&
          decodedSec < totalDuration - _kLocalTruncationMarginSec) {
        _shortLocalDurationSec = decodedSec;
        debugPrint(
          '[Player] Local audio decodes to ${decodedSec.toStringAsFixed(1)}s '
          'but book is ${totalDuration.toStringAsFixed(1)}s — download looks '
          'incomplete; clamping seeks and protecting saved progress (GH #278)',
        );
      }

      // The initial position may sit past a truncated single file; clamp once
      // the decoded length is known (the source itself is already loaded, so
      // this is a direct engine seek rather than a load-intent seek).
      if (_shortLocalDurationSec != null &&
          startTime > _shortLocalDurationSec!) {
        await _player!
            .seek(
              Duration(milliseconds: (_shortLocalDurationSec! * 1000).round()),
            )
            .timeout(_seekCap, onTimeout: _seekTimedOut);
        _pendingStartSec = _shortLocalDurationSec!;
        _lastSeekTargetSeconds = _shortLocalDurationSec;
        _lastSeekTime = DateTime.now();
      }

      _subscribeTrackIndex();
      final initChapter = _initChapterInfo(startTime);
      // Speed must be applied before _pushMediaItem: the pushed duration is
      // speed-adjusted at push time, and nothing re-pushes it on load - so
      // pushing at the default 1.0x left the notification/AA/widget bar
      // lagging (the chapter "ended" at 1/speed) until a foreground re-push.
      await _player!.setSpeed(speed);
      _pushMediaItem(
        itemId,
        title,
        author,
        coverUrl,
        totalDuration,
        chapter: initChapter,
      );
      await _primeNowPlaying(
        title: title,
        artist: author,
        duration: totalDuration,
        elapsed: startTime,
        chapter: initChapter,
      );
      await EqualizerService().switchItem(speedKey);
      if (loadOnly) {
        // Loaded and idle at the resume position: the lock screen shows the
        // book paused, a headset press has a live target, and the transcript
        // can build its runway - but nothing plays and no session exists
        // until the user presses play, which creates the session then.
        debugPrint(
          '[Player] Loaded paused (no session) at '
          '${startTime.toStringAsFixed(0)}s',
        );
        _pendingLoadOnlySession = (
          progressKey: pKey,
          itemId: _currentItemId!,
          episodeId: _currentEpisodeId,
          duration: totalDuration,
          title: title,
          author: author,
          streamed: stream != null,
        );
        _handler?.refreshPlaybackState();
        notifyListeners();
        return null;
      }
      debugPrint('[Player] Starting local playback at ${speed}x');
      _handler?.refreshPlaybackState();
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        (await AudioSession.instance).setActive(true);
      } catch (_) {}
      if (_startSuperseded(gen)) {
        return _abandonStart(null, null, 'local, before play');
      }
      if (!_pauseRequested) _enginePlayAfterLoad();
      // A long background / overnight pause can leave the playing event
      // throttled in Doze, so push state immediately from the live player flags
      // and again after load settles instead of waiting for a late event; the
      // native layer keeps the foreground notification bound on playing.
      _handler?.refreshPlaybackState();
      Future.delayed(const Duration(milliseconds: 500), () {
        _handler?.refreshPlaybackState();
      });
      _scheduleAudioDiagnostics('local');
      notifyListeners();
      _setupSync();
      await LocalSessionService().beginSession(
        progressKey: pKey,
        libraryItemId: rawItemId,
        episodeId: episodeId,
        mediaType: episodeId != null ? 'podcast' : 'book',
        duration: totalDuration,
        startTime: startTime,
        displayTitle: title,
        displayAuthor: author,
        streamed: stream != null,
      );
      Future.delayed(const Duration(milliseconds: 500), () {
        _handler?.refreshPlaybackState();
      });
      // Fresh session — reset auto sleep dismiss and check
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();

      return null;
    } catch (e, stack) {
      debugPrint('[Player] Local play error: $e\n$stack');

      if (_startSuperseded(gen)) {
        return _abandonStart(null, null, 'local, load interrupted');
      }

      // A downloaded original can still be unreadable by the device (for
      // example a very large MP4/M4B that ExoPlayer cannot parse). When the
      // server is reachable, retry once through ABS transcoding instead of
      // leaving the user stuck with an unusable local file.
      if (PlaybackErrorPolicy.shouldRetryWithTranscode(e) &&
          _api != null &&
          !manualOffline &&
          !_knownOffline &&
          _currentItemId != null) {
        debugPrint(
          '[Player] Local source failed - retrying with server transcoding',
        );
        _shortLocalDurationSec = null;
        _localSessionMode = false;
        _localSessionAccounting = false;
        final fallbackResult = await _playFromServer(
          _api!,
          rawItemId,
          title,
          author,
          coverUrl,
          totalDuration,
          chapters,
          startTime,
          forceStartTime: forceStartTime,
          forceTranscode: true,
          generation: gen,
        );
        if (fallbackResult == null) {
          // Streaming uses data the download was meant to save, so say so.
          final l = _l10n();
          showNavigatorOverlayToast(
            rootNavigatorKey.currentState,
            l?.playerDownloadStreamingInstead ??
                "This download couldn't be played, so it's streaming from the server. Downloading it again may fix it.",
            icon: Icons.cloud_download_outlined,
          );
          return null;
        }
        debugPrint(
          '[Player] Transcoded fallback after local failure did not start: $fallbackResult',
        );
        return fallbackResult;
      }

      _clearState();
      return (_l10n()?.playerErrorGeneric(e.toString().split('\n').first)) ??
          'Playback failed: ${e.toString().split('\n').first}';
    }
  }

  /// Build a session-shaped track list from the last disk-cached library item
  /// so a first play can start instantly from its per-file URLs while a real
  /// `/play` session is opened in the background (the cached-session path then
  /// hot-swaps to the tokenless session URLs at the next pause/seek). Strictly
  /// disk-only - no network - and returns null when the item has never been
  /// cached, so callers that already have a session cache never pay for it.
  Future<Map<String, dynamic>?> _sessionShapeFromCachedItem(
    String itemId,
    String? episodeId, {
    Map<String, dynamic>? newerThan,
  }) async {
    final api = _api;
    if (api == null) return null;
    final progressKey = playbackDownloadKey(itemId, episodeId);
    final item = await api.getCachedLibraryItem(
      splitEpisodeKey(progressKey).itemId,
    );
    if (item == null) return null;
    // A shelf payload can carry the server's new updatedAt while the disk
    // item still describes the previous chapters/files. Starting from that
    // stale copy is what played an old file after a server-side re-upload;
    // fall through to /play, which returns the current tracks.
    final cachedUpdatedAt = (item['updatedAt'] as num?)?.toInt();
    final shelfUpdatedAt = (newerThan?['updatedAt'] as num?)?.toInt();
    if (shelfUpdatedAt != null &&
        (cachedUpdatedAt == null || cachedUpdatedAt < shelfUpdatedAt)) {
      debugPrint(
        '[CacheTrace] cached item stale item=$itemId '
        'cached=$cachedUpdatedAt shelf=$shelfUpdatedAt - skipping',
      );
      return null;
    }
    return _sessionShapeFromItem(progressKey, item, api);
  }

  /// Build the same `{'audioTracks': [...]}` shape from the tiny per-book
  /// manifest instead of the whole library item.
  ///
  /// A book with a thousand files carries a multi-MB item payload, and a start
  /// with no snapshot and no session cache used to wait for all of it before
  /// any audio. The manifest holds just file ids and durations (tens of KB,
  /// read straight from preferences), so this path needs no network at all.
  ///
  /// Episodes are skipped: their files live under the show's episodes, which
  /// the manifest does not carry.
  Future<Map<String, dynamic>?> _sessionShapeFromManifest(
    String itemId,
    String? episodeId, {
    Map<String, dynamic>? newerThan,
  }) async {
    if (episodeId != null) return null;
    final manifest = await PlaybackManifest.load(
      itemId,
      newerThanUpdatedAt: (newerThan?['updatedAt'] as num?)?.toInt(),
    );
    if (manifest == null) return null;
    final files = (manifest['files'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (files.isEmpty) return null;
    // `path=manifest` already reports which start used the list; the file count
    // is on the write side (`[Manifest] Saved …`).
    // Chapters live in their own per-item cache; the manifest deliberately does
    // not duplicate them (a thousand titles cost more than the file list).
    List<dynamic> chapters = const [];
    try {
      chapters = await ChapterCache.read(itemId) ?? const [];
    } catch (_) {}
    return {
      'audioTracks': [
        for (var i = 0; i < files.length; i++)
          {
            // Relative on purpose: buildTrackUrl re-signs the token on every
            // start, so a rotated token can never be baked in here.
            'contentUrl': '/api/items/$itemId/file/${files[i]['ino']}',
            'index': i,
            'duration': (files[i]['duration'] as num?)?.toDouble() ?? 0,
          },
      ],
      if (chapters.isNotEmpty) 'chapters': chapters,
      'totalDuration': (manifest['totalDuration'] as num?)?.toDouble() ?? 0,
    };
  }

  /// Shape a library-item payload into the `{'audioTracks': [...]}` form the
  /// cached-session path consumes. Shared by the disk-cache seed, the shelf
  /// snapshot and the item-only start. Returns null when the item carries no
  /// resolvable tracks.
  Map<String, dynamic>? _sessionShapeFromItem(
    String progressKey,
    Map<String, dynamic> item,
    ApiService api,
  ) {
    final tracks = BookTrackResolver.tracksFromItem(progressKey, item, api);
    if (tracks == null || tracks.isEmpty) return null;
    debugPrint(
      '[Player] Shaping instant start from item: ${tracks.length} track(s)',
    );
    // Carry the item's chapters through: _playFromSessionCache consumes a
    // `chapters` key from this blob, and without it a cold-restart start runs
    // with an empty chapter list (no switching) until the network copy of the
    // item lands.
    final itemChapters = _chaptersFromItem(
      item,
      splitEpisodeKey(progressKey).episodeId,
    );
    return {
      'audioTracks': [
        for (var i = 0; i < tracks.length; i++)
          {
            'contentUrl': tracks[i].source,
            'index': i,
            'duration': tracks[i].duration,
          },
      ],
      if (itemChapters.isNotEmpty) 'chapters': itemChapters,
    };
  }

  /// Chapters carried by a full library-item payload: `media.chapters` for a
  /// book, the matching episode's list for a podcast. Empty when the item has
  /// none (or is a minified/shelf shape without them).
  static List<dynamic> _chaptersFromItem(
    Map<String, dynamic>? item,
    String? episodeId,
  ) {
    if (item == null) return const [];
    final media = item['media'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];
    if (chapters.isNotEmpty || episodeId == null) return chapters;
    for (final ep
        in ((media['episodes'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()) {
      if (ep['id'] == episodeId) {
        return ep['chapters'] as List<dynamic>? ?? const [];
      }
    }
    return const [];
  }

  /// Per-track URIs rebuilt with whatever credential the API holds right now.
  /// Called again after a 401 so the retry cannot reuse the expired token
  /// baked into the first attempt's URLs.
  ConcatenatingAudioSource _buildTrackSource(
    ApiService api,
    List<dynamic> audioTracks,
    String itemId,
  ) {
    final audioHeaders = api.playbackSessionHeaders;
    final trackSources = <AudioSource>[];
    for (final t in audioTracks) {
      final track = t as Map<String, dynamic>;
      final contentUrl = track['contentUrl'] as String? ?? '';
      final fullUrl = api.buildTrackUrl(contentUrl);
      trackSources.add(
        AudioSource.uri(
          Uri.parse(fullUrl),
          headers: _withCacheKey(audioHeaders, itemId, fullUrl),
          options: mp3ExtractorOptions(),
        ),
      );
    }
    return ConcatenatingAudioSource(children: trackSources);
  }

  /// Play from cached session metadata. Starts playback instantly without
  /// waiting for a server round-trip. Fires _refreshServerSession() in the
  /// background to get a fresh session ID and cross-client progress check.
  Future<String?> _playFromSessionCache(
    ApiService api,
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime,
    Map<String, dynamic> cached,
    int localTimestampAtStart,
    int playbackGeneration, [
    bool forceStartTime = false,
    Future<Map<String, dynamic>?>? pendingSession,
    NetBodyGate? sessionGate,
  ]) async {
    // The session request still in flight is handed to nobody on this route;
    // close it when it lands so the server is not left with a stray one.
    void dropPendingSession() {
      pendingSession
          ?.then((s) {
            final id = s?['id'] as String?;
            if (id != null) unawaited(api.closePlaybackSession(id));
          })
          .catchError((_) {});
    }

    void releaseDeferredSession() {
      if (sessionGate == null) return;
      debugPrint('[Player] Releasing deferred /play body');
      sessionGate.open();
    }

    if (_startSuperseded(playbackGeneration)) {
      dropPendingSession();
      releaseDeferredSession();
      return _abandonStart(null, null, 'before the cached start');
    }
    debugPrint('[Player] Playing from session cache');
    final episodeIdAtStart = _currentEpisodeId;
    _isOfflineMode = false;
    _playbackSessionId =
        null; // No server session yet; _refreshServerSession will set it

    final offlineError = _abortIfOffline();
    if (offlineError != null) {
      releaseDeferredSession();
      return offlineError;
    }

    final audioTracks = cached['audioTracks'] as List<dynamic>?;
    if (audioTracks == null || audioTracks.isEmpty) {
      debugPrint('[Player] Cached session has no audio tracks - falling back');
      releaseDeferredSession();
      return 'cache-miss';
    }

    // Pick up cached chapters if the caller didn't provide any
    if (chapters.isEmpty) {
      final cachedChapters = cached['chapters'] as List<dynamic>? ?? [];
      if (cachedChapters.isNotEmpty) {
        chapters = cachedChapters;
        _chapters = cachedChapters;
        _handler?.updateChaptersQueue(cachedChapters);
      }
    }

    // Use cached duration if caller didn't have one
    if (totalDuration <= 0) {
      final cachedDur = (cached['totalDuration'] as num?)?.toDouble() ?? 0;
      if (cachedDur > 0) {
        totalDuration = cachedDur;
        _totalDuration = cachedDur;
      }
    }
    if (totalDuration > 0) {
      _progressSync.rememberServerDuration(
        episodeIdAtStart != null ? '$itemId-$episodeIdAtStart' : itemId,
        totalDuration,
      );
    }

    var authRetried = false;
    try {
      // The URLs below are rebuilt with the current token; refresh a
      // known-expired one first so the first file request is not sent with a
      // credential we already know is dead. Capped: a weak link must still
      // yield to the 401 retry instead of holding the start for a refresh
      // timeout.
      try {
        await api.ensureMediaTokenFresh().timeout(_tokenPreflightCap);
      } catch (e) {
        debugPrint(
          '[Player] Token pre-flight did not finish - starting with the '
          'current token: $e',
        );
      }
      if (_startSuperseded(playbackGeneration)) {
        dropPendingSession();
        releaseDeferredSession();
        return _abandonStart(null, null, 'cached start, before a token check');
      }
      _buildTrackOffsets(audioTracks);
      var source = _buildTrackSource(api, audioTracks, itemId);
      _captureStreamUrls(audioTracks, api);

      await _configureAudioSession();
      try {
        final activated = await (await AudioSession.instance).setActive(true);
        debugPrint(
          '[Player] Pre-source setActive(true)=$activated (cached-session)',
        );
      } catch (e) {
        debugPrint('[Player] Pre-source setActive failed (cached-session): $e');
      }
      if (_startSuperseded(playbackGeneration)) {
        dropPendingSession();
        releaseDeferredSession();
        return _abandonStart(
          null,
          null,
          'cached start, before loading the source',
        );
      }
      // If the saved position is at (or past) the end, restart from the beginning
      if (totalDuration > 0 && startTime >= totalDuration - 1.0) startTime = 0;
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      startTime = await _sessionStartRewound(
        startTime,
        forceStartTime: forceStartTime,
        speed: speed,
      );
      startTime = _pendingLoadSeekFor(playbackGeneration) ?? startTime;
      // Same pre-jump as the local/server paths: a cached start that lands
      // inside the intro window must begin past it, not play it first.
      startTime = await _introSkipPreJump(startTime, totalDuration);
      _pinStartPositionForLoad(playbackGeneration, startTime);

      // Resolve the landing track before the source is set so the cached
      // start initializes directly at the saved position's file instead of
      // pre-rolling track 0 and seeking into place (see the stream path).
      final chapterStart = startTime > 0 && _isChapterStartWithin(startTime);
      final resolved = _resolveAbsolutePosition(
        startTime,
        chapterJump: chapterStart,
      );
      _currentTrackIndex = resolved.index;
      if (chapterStart && _trackStartOffsets.length > 1) {
        _latchChapterJumpTarget(startTime);
      }
      final initialPosition = Duration(
        milliseconds: (resolved.localOffset * 1000).round(),
      );

      Future<void> loadSource() async {
        _resetPreBufferState();
        _startTraceLog('setAudioSource start (session-cache)');
        _watchFirstBytes('session-cache');
        _markStartSourceRequested(playbackGeneration);
        await _player!.setAudioSource(
          source,
          initialIndex: resolved.index,
          initialPosition: initialPosition,
          itemId: _currentItemId,
        );
      }

      try {
        await loadSource();
      } catch (e) {
        if (authRetried || !PlaybackErrorPolicy.isAuthError(e)) rethrow;
        authRetried = true;
        debugPrint(
          '[Player] Cached session 401 - refreshing the token and retrying '
          'the source once: $e',
        );
        final tokenRefreshed = await api.ensureMediaTokenFresh(force: true);
        if (!tokenRefreshed) {
          debugPrint(
            '[Player] Cached session 401 and the token could not be refreshed '
            '- leaving the fallback paths',
          );
          rethrow;
        }
        if (_startSuperseded(playbackGeneration) ||
            _currentItemId != itemId ||
            _currentEpisodeId != episodeIdAtStart) {
          dropPendingSession();
          releaseDeferredSession();
          return _abandonStart(
            null,
            null,
            'cached start, after a token refresh',
          );
        }
        source = _buildTrackSource(api, audioTracks, itemId);
        _captureStreamUrls(audioTracks, api);
        await loadSource();
      }
      _startTraceLog('setAudioSource done (session-cache)');
      _activeConcatSource = source;
      _currentBookTrackCount = source.length;

      _subscribeTrackIndex();
      final initChapter = _initChapterInfo(startTime);
      // Speed before _pushMediaItem - the pushed duration is speed-adjusted.
      await _player!.setSpeed(speed);
      _pushMediaItem(
        itemId,
        title,
        author,
        coverUrl,
        totalDuration,
        chapter: initChapter,
      );
      await _primeNowPlaying(
        title: title,
        artist: author,
        duration: totalDuration,
        elapsed: startTime,
        chapter: initChapter,
      );
      await EqualizerService().switchItem(itemId);
      debugPrint('[Player] Starting cached session playback at ${speed}x');
      _handler?.refreshPlaybackState();
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        (await AudioSession.instance).setActive(true);
      } catch (_) {}
      if (_startSuperseded(playbackGeneration)) {
        dropPendingSession();
        releaseDeferredSession();
        return _abandonStart(null, null, 'cached start, before play');
      }
      _cachedStartReconcileGeneration = playbackGeneration;
      if (!_pauseRequested) _enginePlayAfterLoad();
      _scheduleAudioDiagnostics('cached-session');
      notifyListeners();
      _setupSync();
      if (sessionGate != null) {
        Future.delayed(const Duration(seconds: 1), () {
          if (_playbackGeneration != playbackGeneration) return;
          debugPrint('[Player] Cached audio started - releasing /play body');
          sessionGate.open();
        });
      }
      Future.delayed(const Duration(milliseconds: 500), () {
        _handler?.refreshPlaybackState();
      });
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();
      // Refresh server session in background - gets fresh session ID and
      // handles cross-client progress sync without blocking playback start
      final progressKey = episodeIdAtStart != null
          ? '$itemId-$episodeIdAtStart'
          : itemId;
      _refreshServerSession(
        api,
        itemId,
        episodeIdAtStart: episodeIdAtStart,
        progressKey: progressKey,
        localTimestampAtStart: localTimestampAtStart,
        localTimeAtStart: startTime,
        playbackGeneration: playbackGeneration,
        pendingSession: pendingSession,
      );
      return null;
    } catch (e, stack) {
      debugPrint('[Player] Cached session play error: $e\n$stack');
      if (_cachedStartReconcileGeneration == playbackGeneration) {
        _cachedStartReconcileGeneration = null;
      }
      // Interrupted by a newer start, not a bad cache: leave the cache alone
      // and do not fall through to a full server start over the winner.
      if (_startSuperseded(playbackGeneration)) {
        dropPendingSession();
        releaseDeferredSession();
        return _abandonStart(null, null, 'cached start, load interrupted');
      }
      // Cache was stale or invalid - clear it and signal fallback
      SessionCache.clear(itemId: itemId, episodeId: episodeIdAtStart);
      // The cached URLs just proved stale (404/changed files). The /play
      // request opened at the start is already in flight and carries the
      // server's current tracks, so prefer it over replaying the same stale
      // item-cache files. This is what turns a failed cached start into the
      // updated book instead of another 404 from the old copy.
      releaseDeferredSession();
      if (pendingSession != null) {
        Map<String, dynamic>? lateSession;
        try {
          lateSession = await pendingSession.timeout(
            const Duration(seconds: 20),
          );
        } catch (_) {}
        if (lateSession != null) {
          debugPrint(
            '[CacheTrace] cached session stale - using the in-flight fresh '
            'session',
          );
          return _playFromServer(
            api,
            itemId,
            title,
            author,
            coverUrl,
            totalDuration,
            chapters,
            startTime,
            forceStartTime: forceStartTime,
            preFetchedSession: lateSession,
            generation: playbackGeneration,
          );
        }
      }
      // The fresh session did not answer either. A stale cached session (dead
      // file/session URLs, changed files) must not hold the start on a slow
      // /play: the item cache itself can still give per-file URLs. Try those
      // now, without any network lookup.
      final directKey = playbackDownloadKey(itemId, episodeIdAtStart);
      final cachedTracks = await BookTrackResolver.resolve(
        directKey,
        api,
        cacheOnly: true,
      );
      if (cachedTracks != null && cachedTracks.isNotEmpty) {
        debugPrint(
          '[CacheTrace] cached session and fresh session both failed - '
          'using cached item direct files',
        );
        dropPendingSession();
        final direct = await _playFromDirectFiles(
          api,
          itemId,
          title,
          author,
          coverUrl,
          totalDuration,
          chapters,
          startTime,
          forceStartTime: forceStartTime,
          cacheOnly: true,
          generation: playbackGeneration,
          progressKey: directKey,
          episodeId: episodeIdAtStart,
        );
        if (direct == null) return null;
        return direct;
      }
      releaseDeferredSession();
      return 'cache-miss';
    }
  }

  /// Re-create the server playback session in the background after starting
  /// playback from cache. Gets a fresh session ID so progress syncing works,
  /// and handles cross-client progress (seek to server position if ahead).
  void _refreshServerSession(
    ApiService api,
    String itemId, {
    required String? episodeIdAtStart,
    required String progressKey,
    required int localTimestampAtStart,
    required double localTimeAtStart,
    required int playbackGeneration,
    Future<Map<String, dynamic>?>? pendingSession,
  }) async {
    try {
      if (_isOfflineMode) return;
      // `_isLoadingNewItem` is still true when a cached start calls this right
      // after the source lands; that is THIS start, not a stale one. A
      // session-less source only needs the cheap presence session there; a
      // session-backed backend (BookOrbit) keeps the old loading-time skip.
      if (pendingSession == null &&
          ((_isLoadingNewItem && !_sourceSessionless) ||
              _playbackGeneration != playbackGeneration ||
              _currentItemId != itemId ||
              _currentEpisodeId != episodeIdAtStart)) {
        debugPrint(
          '[Player] Skipping stale background session refresh for $progressKey',
        );
        return;
      }
      // A session-less source needs no full /play: a presence-only session
      // registers it as active (the multi-MB track list is dropped). A /play
      // already racing from the start is closed when it lands.
      if (_currentItemId == itemId &&
          _currentEpisodeId == episodeIdAtStart &&
          _sourceSessionless) {
        final racing = pendingSession;
        if (racing != null) {
          racing.then((s) {
            final id = s?['id'] as String?;
            if (id != null) unawaited(api.closePlaybackSession(id));
          }).catchError((Object _) {});
        }
        await _ensureStatsSessionForSessionlessSource();
        return;
      }
      final progressRequest = api.getItemProgress(progressKey);
      // The race in playItem may already have a POST in flight - consume it
      // rather than opening a second session.
      final sessionData = await (pendingSession ??
          _startSessionRequest(
            api: api,
            itemId: itemId,
            episodeId: episodeIdAtStart,
            onProgress: (_) => _markStartProgress(playbackGeneration),
          ));
      if (sessionData == null) {
        debugPrint('[Player] Background session refresh returned null');
        return;
      }
      final serverProgress = await progressRequest;
      if (_playbackGeneration != playbackGeneration ||
          _currentItemId != itemId ||
          _currentEpisodeId != episodeIdAtStart) {
        debugPrint(
          '[Player] Ignoring stale background session refresh for $progressKey',
        );
        final staleId = sessionData['id'] as String?;
        if (staleId != null) unawaited(api.closePlaybackSession(staleId));
        return;
      }
      _playbackSessionId = sessionData['id'] as String?;
      _lastServerSync = DateTime.now();
      debugPrint('[Player] Background session refreshed: $_playbackSessionId');
      _captureNowPlayingCredits(sessionData);
      _logEvent(PlaybackEventType.sessionStart, detail: 'refresh');

      // Update cached session with fresh track data in case it changed
      final audioTracks = sessionData['audioTracks'] as List<dynamic>?;
      final sessionChapters = sessionData['chapters'] as List<dynamic>? ?? [];
      final sessionDur = (sessionData['duration'] as num?)?.toDouble() ?? 0;
      if (sessionChapters.isNotEmpty) {
        // The cached start may still show the old chapter list; the fresh
        // session is authoritative for chapter titles/counts.
        _chapters = sessionChapters;
        _handler?.updateChaptersQueue(sessionChapters);
        debugPrint(
          '[CacheTrace] adopted ${sessionChapters.length} fresh chapters '
          'from the background session',
        );
      }
      if (audioTracks != null && audioTracks.isNotEmpty) {
        SessionCache.save(
          itemId: itemId,
          episodeId: _currentEpisodeId,
          audioTracks: audioTracks,
          chapters: sessionChapters.isNotEmpty ? sessionChapters : _chapters,
          totalDuration: sessionDur > 0 ? sessionDur : _totalDuration,
        );
        // The playing source still carries the cached tokened URLs; hold this
        // session so the next pause or seek can swap to its tokenless URLs.
        _stashSessionUpgrade(sessionData);
      }

      // Audio is already running from the cached start; the server's saved
      // position is only logged here, never seeked to - a jump a few seconds
      // into playback is worse than the stale spot. An app-screen play had
      // its chance to adopt it in the pre-start race window.
      final serverPos =
          (serverProgress?['currentTime'] as num?)?.toDouble() ??
          (sessionData['currentTime'] as num?)?.toDouble() ??
          0;
      final serverTs =
          (serverProgress?['lastUpdate'] as num?)?.toInt() ??
          (localTimestampAtStart == 0
              ? (sessionData['updatedAt'] as num?)?.toInt() ?? 0
              : 0);
      final localPos = position.inMilliseconds / 1000.0;
      if (SyncLogic.shouldAdoptServerAtCachedStart(
        serverTimestamp: serverTs,
        serverTime: serverPos,
        localTimestampAtStart: localTimestampAtStart,
        localTimeAtStart: localTimeAtStart,
        currentPlaybackTime: localPos,
      )) {
        debugPrint(
          '[Player] Server is ahead on cache-start: server=${serverPos}s vs local=${localPos}s - not seeking (audio already running)',
        );
      }
    } catch (e) {
      debugPrint('[Player] Background session refresh failed: $e');
    } finally {
      if (_cachedStartReconcileGeneration == playbackGeneration) {
        _cachedStartReconcileGeneration = null;
      }
    }
  }

  /// Playback-start budget for the item leg. Short enough that a slow item
  /// read still leaves room for the sequential /play fallback before the UI
  /// start watchdog fires. Background item reads keep their 30s budget.
  static const _startItemFetchTimeout = Duration(seconds: 15);

  /// Start one path only: fetch the expanded item, shape its per-file tracks,
  /// and start from those files. If that fails, only then fall back to /play.
  /// Never runs an item fetch and /play body concurrently.
  Future<String?> _playFromItemOnly(
    ApiService api,
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime,
    String progressKey,
    int localTimestampAtStart,
    int playbackGeneration, {
    bool forceStartTime = false,
    Future<Map<String, dynamic>?>? prefetchedItem,
  }) async {
    if (_startSuperseded(playbackGeneration)) {
      return _abandonStart(api, null, 'item-only, before fetch');
    }
    Map<String, dynamic>? item;
    if (prefetchedItem != null) {
      try {
        item = await prefetchedItem.timeout(_startItemFetchTimeout);
      } on TimeoutException {
        _startTraceLog(
          'item prefetch exceeded ${_startItemFetchTimeout.inSeconds}s - '
          'cancelling before /play',
        );
        api.cancelBackgroundItemTransfer(itemId);
      } catch (e) {
        debugPrint('[Player] Item-only fetch failed: $e');
      }
    } else {
      final client = http.Client();
      _trackStartClient(client);
      try {
        item = await api.getLibraryItemCancellable(
          itemId,
          client,
          onProgress: (_) => _markStartProgress(playbackGeneration),
          timeout: _startItemFetchTimeout,
          // A timed-out item must hand over to /play, not start from a stale
          // disk copy and spend the fallback's time on old URLs. Fast failures
          // (refused, 5xx) may still use the cached copy.
          cacheOnTimeout: false,
        );
      } catch (e) {
        debugPrint('[Player] Item-only fetch failed: $e');
      }
      _releaseStartClient(client);
    }
    if (_startSuperseded(playbackGeneration)) {
      if (prefetchedItem != null) api.cancelBackgroundItemTransfer(itemId);
      return _abandonStart(api, null, 'item-only, after fetch');
    }
    final shaped = item == null
        ? null
        : _sessionShapeFromItem(progressKey, item, api);
    if (shaped != null) {
      final result = await _playFromSessionCache(
        api,
        itemId,
        title,
        author,
        coverUrl,
        totalDuration,
        chapters,
        startTime,
        shaped,
        localTimestampAtStart,
        playbackGeneration,
        forceStartTime,
        null,
      );
      if (result == null) return null;
      if (_startSuperseded(playbackGeneration)) {
        return _abandonStart(api, null, 'item-only, after source');
      }
      debugPrint(
        '[Player] Item-only path did not start ($result) - trying /play sequentially',
      );
    } else {
      _startTraceLog(
        'item-only had no usable item (${_startItemFetchTimeout.inSeconds}s '
        'budget) - trying /play sequentially',
      );
    }
    return _playFromServer(
      api,
      itemId,
      title,
      author,
      coverUrl,
      totalDuration,
      chapters,
      startTime,
      forceStartTime: forceStartTime,
      generation: playbackGeneration,
    );
  }

  /// If the library flipped offline while a server stream was being prepared,
  /// tear down instead of starting a stream from a server we were told to
  /// abandon. Returns the offline error string, or null while still online.
  String? _abortIfOffline() {
    if (!_offline) return null;
    debugPrint('[Player] Went offline during stream setup — aborting');
    _endAdvanceBuffering();
    _clearState();
    return _l10n()?.playerErrorNotDownloadedOffline ??
        'This item isn\'t downloaded and offline mode is on';
  }

  static bool _isNotFoundError(Object e) {
    final s = e.toString();
    return s.contains('404') || s.contains('InvalidResponseCodeException');
  }

  Future<String?> _playFromServer(
    ApiService api,
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime, {
    bool forceStartTime = false,
    bool forceTranscode = false,
    bool preferPublicSession = true,
    Map<String, dynamic>? preFetchedSession,
    int? generation,
    bool bypassStreamCache = false,
  }) async {
    final gen = generation ?? _playbackGeneration;
    // A session fetched ahead of time is this start's to close if it lost.
    if (_startSuperseded(gen)) {
      return _abandonStart(
        api,
        preFetchedSession?['id'] as String?,
        'before streaming',
      );
    }
    debugPrint('[Player] Streaming from server');
    _isOfflineMode = false;
    _localSessionMode = false;
    _localSessionAccounting = false;
    _sourceIsNetwork = true;
    _parkedAtBoundary = false;
    _parkedBoundaryChapterIdx = null;
    // A real stream session has no download boundary: drop the partial-play
    // bookkeeping so a hand-off stops treating streamed positions past the
    // download end as "the boundary" — the boundary override would pin the last
    // downloaded chapter's title/progress onto the streamed episode, the stale
    // short-audio clamp would snap scrubs back to the download end, and
    // navigation skips would keep gating on a coverage end that no longer
    // means anything. Mirrors playItem's clears for fresh plays.
    _isPartialLocalPlay = false;
    _localCoverageEndSec = null;
    _shortLocalDurationSec = null;
    _localPlayableChapterIndices = const [];
    // Still this start's episode: nothing has awaited since the check above.
    // Reading the shared field later asked the server for whatever a newer
    // start had set, which is how one episode got two sessions.
    final episodeId = _currentEpisodeId;

    final offlineError = _abortIfOffline();
    if (offlineError != null) return offlineError;

    // Use episode endpoint if this is a podcast episode
    Map<String, dynamic>? sessionData;
    if (preFetchedSession != null) {
      sessionData = preFetchedSession;
    } else {
      _startRequestLegGeneration = gen;
      try {
        sessionData = await _startSessionRequest(
          api: api,
          itemId: itemId,
          episodeId: episodeId,
          forceTranscode: forceTranscode,
          onProgress: (_) => _markStartProgress(gen),
        );
      } finally {
        if (_startRequestLegGeneration == gen) {
          _startRequestLegGeneration = null;
        }
      }
    }
    String? ownSessionId = sessionData?['id'] as String?;
    if (_startSuperseded(gen)) {
      return _abandonStart(api, ownSessionId, 'after the session request');
    }
    if (sessionData == null) {
      // The /play POST is the one hard dependency of streamed playback, and on
      // a slow link a long, many-file book can time it out entirely. Rather
      // than give up, stream the item's own audio files directly - the same
      // per-file URLs the bookmark preview and clip exporter already use - and
      // report listening through the client-owned LOCAL session model.
      debugPrint(
        '[Player] Failed to start playback session - falling back to direct-file streaming',
      );
      return _playFromDirectFiles(
        api,
        itemId,
        title,
        author,
        coverUrl,
        totalDuration,
        chapters,
        startTime,
        forceStartTime: forceStartTime,
        generation: gen,
        progressKey: playbackDownloadKey(itemId, episodeId),
        episodeId: episodeId,
      );
    }

    _playbackSessionId = ownSessionId;
    _captureNowPlayingCredits(sessionData);
    // Sessions know their library; adopt it when the caller couldn't provide
    // one so per-library skip amounts work for lean/merged shelf items.
    final sessionLibId = sessionData['libraryId'] as String?;
    if ((_currentLibraryId == null || _currentLibraryId!.isEmpty) &&
        sessionLibId != null &&
        sessionLibId.isNotEmpty) {
      debugPrint(
        '[SkipDebug] libraryId adopted from play session: $sessionLibId',
      );
      _currentLibraryId = sessionLibId;
      _syncNotifSkipCache();
    }
    _lastServerSync = DateTime.now();
    _logEvent(PlaybackEventType.sessionStart, detail: 'stream');
    var audioTracks = sessionData['audioTracks'] as List<dynamic>?;
    var sessionPlayMethod = (sessionData['playMethod'] as num?)?.toInt();
    if (audioTracks == null || audioTracks.isEmpty) {
      _clearState();
      return _l10n()?.playerErrorNoAudio ??
          'No audio files found - this item may be missing on the server';
    }

    // Detect Dolby Atmos / EAC-3 / AC-3 tracks. Samsung has a hardware Dolby
    // decoder and iOS AVPlayer handles EAC3 natively, so only force transcode
    // on other Android devices where the software codec often fails or outputs silence.
    if (!forceTranscode &&
        Platform.isAndroid &&
        !ApiService.deviceManufacturer.toLowerCase().contains('samsung')) {
      final needsTranscode = audioTracks.any((t) {
        final mime = ((t as Map<String, dynamic>)['mimeType'] as String? ?? '')
            .toLowerCase();
        final codec = (t['codec'] as String? ?? '').toLowerCase();
        return mime.contains('eac3') ||
            mime.contains('ac3') ||
            mime.contains('ac4') ||
            mime.contains('atmos') ||
            codec.contains('eac3') ||
            codec.contains('ac3') ||
            codec.contains('ac4') ||
            codec.contains('atmos');
      });
      if (needsTranscode) {
        debugPrint(
          '[Player] Dolby/EAC3 track detected - restarting with server transcoding',
        );
        if (ownSessionId != null) {
          try {
            await api.closePlaybackSession(ownSessionId);
          } catch (_) {}
        }
        if (_startSuperseded(gen)) {
          return _abandonStart(api, null, 'before the Dolby transcode retry');
        }
        _playbackSessionId = null;
        _startRequestLegGeneration = gen;
        Map<String, dynamic>? retrySession;
        try {
          retrySession = await _startSessionRequest(
            api: api,
            itemId: itemId,
            episodeId: episodeId,
            forceTranscode: true,
            onProgress: (_) => _markStartProgress(gen),
          );
        } finally {
          if (_startRequestLegGeneration == gen) {
            _startRequestLegGeneration = null;
          }
        }
        ownSessionId = retrySession?['id'] as String?;
        if (_startSuperseded(gen)) {
          return _abandonStart(
            api,
            ownSessionId,
            'after the Dolby transcode retry',
          );
        }
        if (retrySession == null) {
          _clearState();
          return _l10n()?.playerErrorTranscodeStart ??
              'Could not start transcoded playback';
        }
        _playbackSessionId = ownSessionId;
        // The stream is real now; the DOWNLOAD-boundary bookkeeping was already
        // cleared at the top of _playFromServer, so this transcoded retry runs
        // in the same clean full-stream state.
        audioTracks = retrySession['audioTracks'] as List<dynamic>? ?? [];
        sessionPlayMethod = (retrySession['playMethod'] as num?)?.toInt();
        if (audioTracks.isEmpty) {
          _clearState();
          return _l10n()?.playerErrorTranscodeNoAudio ??
              'No audio files in transcoded session';
        }
        final sessionChapters =
            retrySession['chapters'] as List<dynamic>? ?? [];
        if (sessionChapters.isNotEmpty) {
          chapters = sessionChapters;
          _chapters = sessionChapters;
          _handler?.updateChaptersQueue(sessionChapters);
        }
        final sessionDur = (retrySession['duration'] as num?)?.toDouble() ?? 0;
        if (sessionDur > 0) {
          totalDuration = sessionDur;
          _totalDuration = sessionDur;
        }
      }
    }

    // The session is the server's current view of this item. Adopt its
    // chapters even when the caller passed a (possibly stale shelf or cached)
    // list, so a chapter/track update on the server is visible on the first
    // play instead of after the item cache expires.
    final sessionChapters = sessionData['chapters'] as List<dynamic>? ?? [];
    if (sessionChapters.isNotEmpty) {
      chapters = sessionChapters;
      _chapters = sessionChapters;
      _handler?.updateChaptersQueue(sessionChapters);
      debugPrint(
        '[Player] Adopted ${sessionChapters.length} chapters from session',
      );
    }

    // Update totalDuration from session if it was unknown (e.g. podcast episodes
    // where the embedded recentEpisode didn't include a duration field)
    if (totalDuration <= 0) {
      final sessionDur = (sessionData['duration'] as num?)?.toDouble() ?? 0;
      if (sessionDur > 0) {
        totalDuration = sessionDur;
        _totalDuration = sessionDur;
        debugPrint(
          '[Player] Updated totalDuration from session: ${sessionDur}s',
        );
      }
    }

    // Compare server position vs local.
    // Usually the furthest position wins, but if local is ahead we also
    // check timestamps to catch stale local saves.
    // Skip all of this when startTime was forced (bookmark/chapter jump).
    // Both candidates are absolute values on whatever timeline the session
    // was saved on — when the server's tracks were changed without rebuilding
    // the chapters, both must be re-anchored onto THIS session's timeline
    // before they are compared against each other.
    startTime = await _remapStartAcrossTrackChange(startTime, audioTracks);
    final rawServerPos = (sessionData['currentTime'] as num?)?.toDouble() ?? 0;
    final serverPos =
        await _remapStartAcrossTrackChange(rawServerPos, audioTracks);
    final pKey = episodeId != null ? '$itemId-$episodeId' : itemId;
    final localTs = await _progressSync.getSavedTimestamp(pKey);
    if (forceStartTime) {
      debugPrint(
        '[Player] Forced start time: ${startTime}s — skipping server/local position comparison',
      );
    } else if (serverPos > startTime + 1.0) {
      debugPrint(
        '[Player] Server position is ahead: server=${serverPos}s vs local=${startTime}s — using server',
      );
      startTime = serverPos;
    } else if (startTime > 0) {
      // Skip the staleness override if we have a pending local sync: the
      // server's lastUpdate can be newer than the local timestamp for reasons
      // unrelated to listening progress, so trusting it would clobber offline
      // playback we haven't shipped yet. Also skip if local is meaningfully
      // ahead of server - a multi-minute gap is real listening progress, not
      // a save race.
      bool useServer = false;
      final hasPending = await _progressSync.hasPendingSync(pKey);
      final gap = startTime - serverPos;
      if (localTs > 0 &&
          !hasPending &&
          gap <= SyncLogic.localAheadSafetySeconds) {
        try {
          final serverProgress = await api.getItemProgress(pKey);
          final serverLastUpdate =
              (serverProgress?['lastUpdate'] as num?)?.toInt() ?? 0;
          if (serverLastUpdate > localTs) {
            debugPrint(
              '[Player] Local position is ahead but stale: local=${startTime}s (ts=$localTs) vs server=${serverPos}s (ts=$serverLastUpdate) — using server',
            );
            startTime = serverPos;
            useServer = true;
          }
        } catch (_) {}
      }
      if (!useServer) {
        if (hasPending) {
          debugPrint(
            '[Player] Local position is ahead: local=${startTime}s vs server=${serverPos}s — keeping local (pending sync)',
          );
        } else if (gap > SyncLogic.localAheadSafetySeconds) {
          debugPrint(
            '[Player] Local position is ahead: local=${startTime}s vs server=${serverPos}s — keeping local (gap ${gap.toStringAsFixed(1)}s exceeds safety threshold)',
          );
        } else {
          debugPrint(
            '[Player] Local position is ahead: local=${startTime}s vs server=${serverPos}s — keeping local',
          );
        }
      }
    } else if (serverPos > 0) {
      debugPrint('[Player] No local position, using server: ${serverPos}s');
      startTime = serverPos;
    }

    double? startBeforeRewind;
    try {
      // Checked before the track offsets are rebuilt: they belong to
      // whichever start is current.
      if (_startSuperseded(gen)) {
        return _abandonStart(api, ownSessionId, 'before building the source');
      }
      _currentTrackIndex = 0;
      final audioHeaders = {
        ...api.playbackSessionHeaders,
        if (bypassStreamCache) _bypassStreamCacheHeader: 'bypass',
      };

      // Build audio source - one source per track file
      _buildTrackOffsets(audioTracks);
      _captureStreamUrls(
        audioTracks,
        api,
        sessionId: _playbackSessionId,
        playMethod: sessionPlayMethod,
      );
      final trackSources = <AudioSource>[];
      for (final t in audioTracks) {
        final track = t as Map<String, dynamic>;
        final contentUrl = track['contentUrl'] as String? ?? '';
        final fullUrl = api.buildTrackUrl(
          contentUrl,
          sessionId: _playbackSessionId,
          trackIndex: (track['index'] as num?)?.toInt(),
          playMethod: sessionPlayMethod,
          preferPublicSession: preferPublicSession,
        );
        trackSources.add(
          AudioSource.uri(
            Uri.parse(fullUrl),
            headers: _withCacheKey(audioHeaders, itemId, fullUrl),
            options: mp3ExtractorOptions(),
          ),
        );
      }
      final source = ConcatenatingAudioSource(children: trackSources);

      // If the saved position is at (or past) the end, restart from the beginning
      if (totalDuration > 0 && startTime >= totalDuration - 1.0) startTime = 0;
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      // Upstream's cache-bypass reload must begin where this start WOULD have
      // begun, not where the session rewind pulled it back to.
      startBeforeRewind = startTime;
      startTime = await _sessionStartRewound(
        startTime,
        forceStartTime: forceStartTime,
        speed: speed,
      );
      startTime = _pendingLoadSeekFor(gen) ?? startTime;
      // Fold the intro skip into the start itself: a start that lands inside
      // the window must not play the opening words while the live skip waits
      // for a position tick. Applied after the session rewind and any queued
      // seek, so the position the engine gets is the final one.
      startTime = await _introSkipPreJump(startTime, totalDuration);
      _pinStartPositionForLoad(gen, startTime);

      // Resolve the landing track before the source is set so the player
      // initializes directly at the target file instead of pre-rolling
      // track 0 and seeking across the whole playlist into place (two extra
      // source transitions and a wasted first-track grab on a slow link).
      // Starting at a chapter boundary (chapter tap in the sheet's inactive
      // branch, bookmark at a chapter start) also snaps to the matching file
      // boundary and latches the intended chapter, exactly like a later jump.
      final chapterStart = startTime > 0 && _isChapterStartWithin(startTime);
      final resolved = _resolveAbsolutePosition(
        startTime,
        chapterJump: chapterStart,
      );
      _currentTrackIndex = resolved.index;
      if (chapterStart && _trackStartOffsets.length > 1) {
        _latchChapterJumpTarget(startTime);
      }
      final initialPosition = Duration(
        milliseconds: (resolved.localOffset * 1000).round(),
      );

      await _configureAudioSession();
      try {
        final activated = await (await AudioSession.instance).setActive(true);
        debugPrint('[Player] Pre-source setActive(true)=$activated (stream)');
      } catch (e) {
        debugPrint('[Player] Pre-source setActive failed (stream): $e');
      }
      if (_startSuperseded(gen)) {
        return _abandonStart(api, ownSessionId, 'before loading the source');
      }
      _resetPreBufferState();
      _startTraceLog('setAudioSource start (stream)');
      _watchFirstBytes('stream');
      _markStartSourceRequested(gen);
      await _player!.setAudioSource(
        source,
        initialIndex: resolved.index,
        initialPosition: initialPosition,
        itemId: _currentItemId,
      );
      _startTraceLog('setAudioSource done (stream)');
      if (_startSuperseded(gen)) {
        return _abandonStart(api, ownSessionId, 'after loading the source');
      }
      _activeConcatSource = source;
      _currentBookTrackCount = trackSources.length;

      // The fork finalizes the start position BEFORE loading the source and
      // hands it to setAudioSource as initialPosition, so upstream's post-load
      // rewind + _seekForStart block is intentionally not carried over - doing
      // both would seek twice and undo the fast start.
      _subscribeTrackIndex();
      final initChapter = _initChapterInfo(startTime);
      // Speed before _pushMediaItem - the pushed duration is speed-adjusted.
      await _player!.setSpeed(speed);
      _pushMediaItem(
        itemId,
        title,
        author,
        coverUrl,
        totalDuration,
        chapter: initChapter,
      );
      await _primeNowPlaying(
        title: title,
        artist: author,
        duration: totalDuration,
        elapsed: startTime,
        chapter: initChapter,
      );
      await EqualizerService().switchItem(itemId);
      debugPrint('[Player] Starting stream playback at ${speed}x');
      _handler?.refreshPlaybackState();
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        (await AudioSession.instance).setActive(true);
      } catch (_) {}
      if (_startSuperseded(gen)) {
        return _abandonStart(api, ownSessionId, 'before play');
      }
      if (!_pauseRequested) _enginePlayAfterLoad();
      _scheduleAudioDiagnostics('stream');
      notifyListeners();
      _setupSync();
      Future.delayed(const Duration(milliseconds: 500), () {
        _handler?.refreshPlaybackState();
      });
      // Fresh session — reset auto sleep dismiss and check
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();
      // Cache session metadata so next play can start instantly
      SessionCache.save(
        itemId: itemId,
        episodeId: episodeId,
        audioTracks: audioTracks,
        chapters: chapters,
        totalDuration: totalDuration,
      );
      return null;
    } catch (e, stack) {
      debugPrint('[Player] Stream error: $e\n$stack');

      // A newer start loading its source is what interrupts this one, so the
      // "error" is expected and the state now belongs to that start.
      if (_startSuperseded(gen)) {
        return _abandonStart(api, ownSessionId, 'load interrupted');
      }

      // The session's public track URL is the usual casualty of a reverse
      // proxy that does not forward /public/session. Before paying for a
      // transcode, retry the same session with tokened contentUrls.
      if (!forceTranscode &&
          preferPublicSession &&
          ownSessionId != null &&
          _isNotFoundError(e)) {
        debugPrint(
          '[Player] Public session track 404 - retrying with tokened content URLs',
        );
        return _playFromServer(
          api,
          itemId,
          title,
          author,
          coverUrl,
          totalDuration,
          chapters,
          startTime,
          forceStartTime: forceStartTime,
          preFetchedSession: sessionData,
          preferPublicSession: false,
          generation: gen,
        );
      }

      // The disk cache in front of the player turned a byte range down: the
      // length it has on record for the URL is shorter than what the file
      // asks for. The file is fine and the session is still open, so the
      // same tracks load again straight from the network, with no new
      // session request to lose on the way.
      if (!bypassStreamCache &&
          AppPlatform.isAndroid &&
          PlaybackErrorPolicy.isCacheRangeError(e)) {
        debugPrint(
          '[Player] Streaming cache refused the byte range - loading the same session again without it',
        );
        final session = Map<String, dynamic>.from(sessionData)
          ..['id'] = ownSessionId
          ..['audioTracks'] = audioTracks
          ..['playMethod'] = sessionPlayMethod;
        _cacheBypassReloadInFlight = true;
        try {
          return await _playFromServer(
            api,
            itemId,
            title,
            author,
            coverUrl,
            totalDuration,
            chapters,
            startBeforeRewind ?? startTime,
            forceStartTime: forceStartTime,
            forceTranscode: forceTranscode,
            preFetchedSession: session,
            generation: gen,
            bypassStreamCache: true,
          );
        } finally {
          _cacheBypassReloadInFlight = false;
        }
      }

      // Retry source and codec failures through ABS once. A distinct flag from
      // forceStartTime keeps bookmark/chapter seeks eligible for recovery while
      // still preventing a transcode loop.
      if (!forceTranscode && PlaybackErrorPolicy.shouldRetryWithTranscode(e)) {
        debugPrint(
          '[Player] Source or codec error detected - retrying with server transcoding',
        );
        if (ownSessionId != null) {
          try {
            await api.closePlaybackSession(ownSessionId);
          } catch (_) {}
          if (_playbackSessionId == ownSessionId) _playbackSessionId = null;
        }
        return _playFromServer(
          api,
          itemId,
          title,
          author,
          coverUrl,
          totalDuration,
          chapters,
          startTime,
          forceStartTime: forceStartTime,
          forceTranscode: true,
          generation: gen,
        );
      }

      _clearState();
      return (_l10n()?.playerErrorGeneric(e.toString().split('\n').first)) ??
          'Playback failed: ${e.toString().split('\n').first}';
    }
  }

  /// Last-resort playback when the server's `/play` session can't be opened:
  /// stream the item's own per-file URLs (built from the library item by
  /// [BookTrackResolver]) instead of session track URLs. There is no server
  /// session id, so listening is reported through the client-owned LOCAL
  /// session model - the same path downloaded playback uses - and the start
  /// position is reconciled against the server's saved progress here because
  /// there is no `/play` response to carry it.
  Future<String?> _playFromDirectFiles(
    ApiService api,
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration,
    List<dynamic> chapters,
    double startTime, {
    bool forceStartTime = false,
    bool cacheOnly = false,
    int? generation,
    String? progressKey,
    String? episodeId,
  }) async {
    final gen = generation ?? _playbackGeneration;
    if (_startSuperseded(gen)) {
      return _abandonStart(api, null, 'direct-file, before entry');
    }
    debugPrint('[Player] Playing from direct files');
    final episodeIdAtStart = episodeId ?? _currentEpisodeId;
    final progressKeyAtStart =
        progressKey ?? playbackDownloadKey(itemId, episodeIdAtStart);
    _isOfflineMode = false;
    // Full-item direct streaming is a stream session (network source, whole
    // book): the partial-download boundary bookkeeping means nothing here and
    // would re-label positions past the download end if a hand-off landed in
    // this fallback — clear it like _playFromServer does.
    _isPartialLocalPlay = false;
    _localCoverageEndSec = null;
    _shortLocalDurationSec = null;
    _localPlayableChapterIndices = const [];

    final offlineError = _abortIfOffline();
    if (offlineError != null) return offlineError;

    // Resolve per-file stream URLs from the library item. Disk copy first:
    // this fallback runs BECAUSE the network path just failed, so paying
    // another network-first getLibraryItem (30s x3, cache only after its 60s
    // deadline) would re-create the very delay we escaped. The network
    // variant only runs when the item has never been cached.
    var resolved = await BookTrackResolver.resolve(
      progressKeyAtStart,
      api,
      cacheOnly: true,
    );
    if ((resolved == null || resolved.isEmpty) && !cacheOnly) {
      resolved = await BookTrackResolver.resolve(progressKeyAtStart, api);
    }
    if (_startSuperseded(gen)) {
      return _abandonStart(api, null, 'direct-file, after resolving tracks');
    }
    if (resolved == null || resolved.isEmpty) {
      debugPrint('[Player] Direct-file fallback: no tracks resolved');
      _clearState();
      return _l10n()?.playerErrorConnect ?? 'Could not connect to server';
    }

    _localSessionMode = true;
    // Direct-file streaming REPORTS via the local session model but still
    // fetches over HTTP — the offline guard must keep treating it remote.
    _sourceIsNetwork = true;
    _playbackSessionId = null;
    _logEvent(PlaybackEventType.sessionStart, detail: 'direct-file');

    final audioTracks = <dynamic>[
      for (var i = 0; i < resolved.length; i++)
        {
          'contentUrl': resolved[i].source,
          'index': i,
          'duration': resolved[i].duration,
        },
    ];

    // No /play response means no server position, so reconcile against
    // /me/progress directly (mirrors _playFromLocal).
    if (!forceStartTime && !_knownOffline) {
      try {
        final serverProgress = await api
            .getItemProgress(progressKeyAtStart)
            .timeout(_serverPositionCheckCap, onTimeout: () => null);
        final serverPos =
            (serverProgress?['currentTime'] as num?)?.toDouble() ?? 0;
        final serverLastUpdate =
            (serverProgress?['lastUpdate'] as num?)?.toInt() ?? 0;
        final localTs = await _progressSync.getSavedTimestamp(progressKeyAtStart);
        if (serverPos > startTime + 1.0) {
          debugPrint(
            '[Player] Direct-file: server position is ahead: server=${serverPos}s vs local=${startTime}s — using server',
          );
          startTime = serverPos;
          await _progressSync.saveLocal(
            itemId: progressKeyAtStart,
            currentTime: serverPos,
            duration: totalDuration,
            speed: 1.0,
          );
        } else if (startTime > 0) {
          final hasPending = await _progressSync.hasPendingSync(
            progressKeyAtStart,
          );
          final gap = startTime - serverPos;
          if (localTs > 0 &&
              !hasPending &&
              gap <= SyncLogic.localAheadSafetySeconds &&
              serverLastUpdate > localTs) {
            debugPrint(
              '[Player] Direct-file: local position is stale — using server=${serverPos}s',
            );
            startTime = serverPos;
          }
        } else if (serverPos > 0) {
          debugPrint(
            '[Player] Direct-file: no local position, using server: ${serverPos}s',
          );
          startTime = serverPos;
        }
      } catch (e) {
        debugPrint('[Player] Direct-file progress reconcile failed: $e');
      }
    }

    if (_startSuperseded(gen)) {
      return _abandonStart(api, null, 'direct-file, after progress reconcile');
    }

    // Per-file URLs are rebuilt with the current token below; refresh a
    // known-expired one before the first request goes out. Capped so a weak
    // link falls through to the 401 retry instead of a refresh timeout.
    try {
      await api.ensureMediaTokenFresh().timeout(_tokenPreflightCap);
    } catch (e) {
      debugPrint(
        '[Player] Token pre-flight did not finish - starting with the '
        'current token: $e',
      );
    }
    if (_startSuperseded(gen)) {
      return _abandonStart(api, null, 'direct-file, after a token check');
    }

    try {
      _currentTrackIndex = 0;
      ConcatenatingAudioSource buildSource() =>
          _buildTrackSource(api, audioTracks, itemId);
      var source = buildSource();
      _buildTrackOffsets(audioTracks);
      _captureStreamUrls(audioTracks, api);

      // Finalize the landing position BEFORE loading the source so it starts
      // on the right track/offset: a post-load seek is silently dropped while
      // just_audio is still loading.
      if (totalDuration > 0 && startTime >= totalDuration - 1.0) startTime = 0;
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      startTime = await _sessionStartRewound(
        startTime,
        forceStartTime: forceStartTime,
        speed: speed,
      );
      startTime = _pendingLoadSeekFor(gen) ?? startTime;
      // Fold the intro skip into the start itself: a start that lands inside
      // the window must not play the opening words while the live skip waits
      // for a position tick. Applied after the session rewind and any queued
      // seek, so the position the engine gets is the final one.
      startTime = await _introSkipPreJump(startTime, totalDuration);
      _pinStartPositionForLoad(gen, startTime);
      final chapterStart = startTime > 0 && _isChapterStartWithin(startTime);
      final landing = _resolveAbsolutePosition(
        startTime,
        chapterJump: chapterStart,
      );
      _currentTrackIndex = landing.index;
      if (chapterStart && _trackStartOffsets.length > 1) {
        _latchChapterJumpTarget(startTime);
      }
      final initialPosition = Duration(
        milliseconds: (landing.localOffset * 1000).round(),
      );
      if (_startSuperseded(gen)) {
        return _abandonStart(api, null, 'direct-file, before local session');
      }

      try {
        await LocalSessionService().beginSession(
          progressKey: progressKeyAtStart,
          libraryItemId: itemId,
          episodeId: episodeIdAtStart,
          mediaType: episodeIdAtStart != null ? 'podcast' : 'book',
          duration: totalDuration,
          startTime: startTime,
          displayTitle: title,
          displayAuthor: author,
        );
      } catch (e) {
        debugPrint(
          '[Player] Direct-file fallback: local session begin failed: $e',
        );
      }

      await _configureAudioSession();
      try {
        await (await AudioSession.instance).setActive(true);
      } catch (_) {}
      Future<void> loadSource() async {
        _resetPreBufferState();
        _markStartSourceRequested(gen);
        _startTraceLog('setAudioSource start (direct-files)');
        _watchFirstBytes('direct-files');
        await _player!.setAudioSource(
          source,
          initialIndex: landing.index,
          initialPosition: initialPosition,
          itemId: itemId,
        );
      }

      var authRetried = false;
      try {
        await loadSource();
      } catch (e) {
        if (authRetried || !PlaybackErrorPolicy.isAuthError(e)) rethrow;
        authRetried = true;
        debugPrint(
          '[Player] Direct-file 401 - refreshing the token and retrying the '
          'source once: $e',
        );
        final tokenRefreshed = await api.ensureMediaTokenFresh(force: true);
        if (!tokenRefreshed) {
          debugPrint(
            '[Player] Direct-file 401 and the token could not be refreshed - '
            'failing the start',
          );
          rethrow;
        }
        if (_startSuperseded(gen) ||
            _currentItemId != itemId ||
            _currentEpisodeId != episodeIdAtStart) {
          return _abandonStart(api, null, 'direct-file, after a token refresh');
        }
        source = buildSource();
        _captureStreamUrls(audioTracks, api);
        await loadSource();
      }
      _activeConcatSource = source;
      _currentBookTrackCount = source.length;
      if (_startSuperseded(gen)) {
        return _abandonStart(api, null, 'direct-file, after loading the source');
      }

      _subscribeTrackIndex();
      final initChapter = _initChapterInfo(startTime);
      // Speed before _pushMediaItem - the pushed duration is speed-adjusted.
      await _player!.setSpeed(speed);
      if (_startSuperseded(gen)) {
        return _abandonStart(api, null, 'direct-file, before media push');
      }
      _pushMediaItem(
        itemId,
        title,
        author,
        coverUrl,
        totalDuration,
        chapter: initChapter,
      );
      await _primeNowPlaying(
        title: title,
        artist: author,
        duration: totalDuration,
        elapsed: startTime,
        chapter: initChapter,
      );
      await EqualizerService().switchItem(itemId);
      debugPrint('[Player] Starting direct-file playback at ${speed}x');
      _handler?.refreshPlaybackState();
      await Future.delayed(const Duration(milliseconds: 200));
      if (_startSuperseded(gen)) {
        return _abandonStart(api, null, 'direct-file, before play');
      }
      try {
        (await AudioSession.instance).setActive(true);
      } catch (_) {}
      if (!_pauseRequested) _enginePlayAfterLoad();
      _scheduleAudioDiagnostics('direct-file');
      notifyListeners();
      _setupSync();
      Future.delayed(const Duration(milliseconds: 500), () {
        _handler?.refreshPlaybackState();
      });
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();
      // Cache what we started from so the next play of this item takes the
      // instant cached path; direct-file starts previously saved nothing and
      // re-paid the whole slow path on every replay.
      SessionCache.save(
        itemId: itemId,
        episodeId: episodeIdAtStart,
        audioTracks: audioTracks,
        chapters: chapters,
        totalDuration: totalDuration,
      );
      return null;
    } catch (e, stack) {
      debugPrint('[Player] Direct-file play error: $e\n$stack');
      if (_startSuperseded(gen)) {
        return _abandonStart(api, null, 'direct-file, after an error');
      }
      _clearState();
      return (_l10n()?.playerErrorGeneric(e.toString().split('\n').first)) ??
          'Playback failed: ${e.toString().split('\n').first}';
    }
  }

  bool _transcodeRetryInFlight = false;

  /// Read by the Android player plugin, never sent to the server: the
  /// source skips the streaming cache.
  static const _bypassStreamCacheHeader = 'X-Absorb-Stream-Cache';

  // Set while a load the streaming cache turned down is redone without it,
  // so the stream retry the same error scheduled does not start over on top.
  bool _cacheBypassReloadInFlight = false;

  // Set when the player failed while paused; the next play rebuilds it
  // instead of trusting its position or its decoder.
  bool _playerBroken = false;

  // Where the book sat when it was paused, moved only by seeks made during
  // the pause. Null while playing.
  double? _pausedAtS;

  // The pause spot used to validate a resume reading. Unlike [_pausedAtS] it
  // is not re-anchored by an engine-side file change while paused, so a source
  // swap cannot quietly replace the listener's real pause point.
  double? _resumeAnchorS;

  /// The paused spot, while a failed player's own position can't be trusted.
  double? get _heldPausedSpot {
    if (!_playerBroken || _isLoadingNewItem) return null;
    if (_player?.playing ?? true) return null;
    return _pausedAtS;
  }

  /// Android can take the decoder from a paused app. The player then reports
  /// an error and may step to the start of the next file, once per failure,
  /// so a long pause can walk the book forward by hours. Keep the paused spot
  /// and rebuild on the next play. Returns whether the player was paused.
  bool _playerFailedWhilePaused(String what) {
    if (_pausedAtS == null || _isLoadingNewItem) return false;
    if (_player?.playing ?? true) return false;
    // A file that ended just as pause was pressed reports its move late.
    final pausedAt = _lastPauseTime;
    if (pausedAt == null ||
        DateTime.now().difference(pausedAt) < const Duration(seconds: 2)) {
      return false;
    }
    if (!_playerBroken) {
      debugPrint(
        '[Player] Paused player failed ($what) - keeping '
        '${_pausedAtS!.toStringAsFixed(1)}s and rebuilding on the next play',
      );
    }
    _playerBroken = true;
    return true;
  }

  /// A downloaded book needs no server to come back from a decoder failure.
  /// Android can take the decoder away from a paused app, which surfaces as
  /// a renderer error; the file is fine. Playing: start over where it was.
  /// Paused: leave it alone and rebuild on the next play, from the saved
  /// position, so the error can't send the book back to the beginning.
  Future<void> _recoverLocalPlayback(Object e) async {
    if (_currentItemId == null || _api == null) return;
    final wasPlaying = _player?.playing ?? false;
    final startS = position.inMilliseconds / 1000.0;
    debugPrint(
      '[Player] Decoder failed on a local book at ${startS.toStringAsFixed(1)}s '
      '(playing=$wasPlaying) - '
      '${wasPlaying ? "restarting from there" : "rebuilding on the next play"}: $e',
    );
    if (!wasPlaying) {
      _playerBroken = true;
      return;
    }
    await playItem(
      api: _api!,
      itemId: _currentItemId!,
      title: _currentTitle ?? '',
      author: _currentAuthor ?? '',
      coverUrl: _currentCoverUrl,
      totalDuration: _totalDuration,
      chapters: _chapters,
      startTime: startS,
      forceStartTime: startS > 0,
      episodeId: _currentEpisodeId,
      episodeTitle: _currentEpisodeTitle,
      libraryId: _currentLibraryId,
    );
  }

  Future<void> _retryWithTranscode() async {
    if (_transcodeRetryInFlight) return;
    _transcodeRetryInFlight = true;
    try {
      final api = _api;
      if (api == null || _currentItemId == null) return;
      // Android takes the decoder away from a paused app when the headphones
      // connect or disconnect, which surfaces as a renderer error with
      // nothing playing. Starting a new stream here would play a book
      // nobody asked for; the next play rebuilds the player where it was.
      if (!(_player?.playing ?? false)) {
        debugPrint(
          '[Player] Decoder failed while paused at '
          '${(position.inMilliseconds / 1000.0).toStringAsFixed(1)}s - rebuilding on the next play',
        );
        _playerBroken = true;
        return;
      }
      debugPrint(
        '[Player] Playback error in stream - retrying with server transcoding',
      );
      final itemId = _currentItemId!;
      final retryEpId = _currentEpisodeId;
      final retryEpTitle = _currentEpisodeTitle;
      final retryLibraryId = _currentLibraryId;
      final retryTitle = _currentTitle ?? '';
      final retryAuthor = _currentAuthor ?? '';
      final retryCover = _currentCoverUrl;
      final failedSessionId = _playbackSessionId;
      final startTime = position.inMilliseconds / 1000.0;
      // A start of its own: a load still in flight is about to be interrupted
      // by this one and has to see that it lost, not clear the state.
      final gen = ++_playbackGeneration;
      _isLoadingNewItem = false;
      _clearPendingLoadIntent(clearPlayRequest: true);
      _clearState();
      _currentItemId = itemId;
      _currentEpisodeId = retryEpId;
      _currentEpisodeTitle = retryEpTitle;
      _currentLibraryId = retryLibraryId;
      _currentTitle = retryTitle;
      _currentAuthor = retryAuthor;
      _currentCoverUrl = retryCover;
      _shortLocalDurationSec = null;
      _syncNotifSkipCache();
      if (failedSessionId != null) {
        try {
          await api.closePlaybackSession(failedSessionId);
        } catch (_) {}
      }
      final retrySession = await _startSessionRequest(
        api: api,
        itemId: itemId,
        episodeId: retryEpId,
        forceTranscode: true,
      );
      final ownSessionId = retrySession?['id'] as String?;
      if (_startSuperseded(gen)) {
        _abandonStart(
          api,
          ownSessionId,
          'transcode retry, after the session request',
        );
        return;
      }
      if (retrySession == null) return;
      _playbackSessionId = ownSessionId;
      final retrySessionLibId = retrySession['libraryId'] as String?;
      if ((_currentLibraryId == null || _currentLibraryId!.isEmpty) &&
          retrySessionLibId != null &&
          retrySessionLibId.isNotEmpty) {
        _currentLibraryId = retrySessionLibId;
        _syncNotifSkipCache();
      }
      _lastServerSync = DateTime.now();
      final retryTracks = retrySession['audioTracks'] as List<dynamic>?;
      final totalDuration =
          (retrySession['duration'] as num?)?.toDouble() ?? _totalDuration;
      final chapters = retrySession['chapters'] as List<dynamic>? ?? _chapters;
      _chapters = chapters;
      _totalDuration = totalDuration;
      if (retryTracks == null || retryTracks.isEmpty) return;
      _currentTrackIndex = 0;
      _buildTrackOffsets(retryTracks);
      AudioSource retrySource;
      final audioHeaders = api.playbackSessionHeaders;
      if (retryTracks.length == 1) {
        final track = retryTracks.first as Map<String, dynamic>;
        final contentUrl = track['contentUrl'] as String? ?? '';
        retrySource = AudioSource.uri(
          Uri.parse(api.buildTrackUrl(contentUrl)),
          headers: audioHeaders,
          options: mp3ExtractorOptions(),
        );
      } else {
        final sources = <AudioSource>[];
        for (final t in retryTracks) {
          final track = t as Map<String, dynamic>;
          final contentUrl = track['contentUrl'] as String? ?? '';
          sources.add(
            AudioSource.uri(
              Uri.parse(api.buildTrackUrl(contentUrl)),
              headers: audioHeaders,
              options: mp3ExtractorOptions(),
            ),
          );
        }
        retrySource = ConcatenatingAudioSource(children: sources);
      }
      await _player!.setAudioSource(retrySource, itemId: itemId);
      if (_startSuperseded(gen)) {
        _abandonStart(
          api,
          ownSessionId,
          'transcode retry, after loading the source',
        );
        return;
      }
      if (startTime > 0) await _seekForStart(startTime, gen);
      _pinStartPositionForLoad(gen, startTime);
      _subscribeTrackIndex();
      final initChapter = _initChapterInfo(startTime);
      // Speed before _pushMediaItem - the pushed duration is speed-adjusted.
      final bookSpeed = await PlayerSettings.getBookSpeed(itemId);
      final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
      await _player!.setSpeed(speed);
      _pushMediaItem(
        itemId,
        retryTitle,
        retryAuthor,
        retryCover,
        totalDuration,
        chapter: initChapter,
      );
      await EqualizerService().switchItem(itemId);
      debugPrint('[Player] Transcoded playback starting at ${speed}x');
      try {
        (await AudioSession.instance).setActive(true);
      } catch (_) {}
      if (_startSuperseded(gen)) {
        _abandonStart(api, ownSessionId, 'transcode retry, before play');
        return;
      }
      if (!_pauseRequested) _enginePlayAfterLoad();
      _scheduleAudioDiagnostics('transcoded');
      notifyListeners();
      _setupSync();
      Future.delayed(const Duration(milliseconds: 500), () {
        _handler?.refreshPlaybackState();
      });
      final sleepTimer = SleepTimerService();
      sleepTimer.resetDismiss();
      sleepTimer.checkAutoSleep();
      SessionCache.save(
        itemId: itemId,
        episodeId: retryEpId,
        audioTracks: retryTracks,
        chapters: chapters,
        totalDuration: totalDuration,
      );
    } catch (e) {
      debugPrint('[Player] Transcode retry failed: $e');
    } finally {
      _transcodeRetryInFlight = false;
    }
  }

  /// Set _currentChapterStart/End for the chapter containing [posSeconds].
  /// Index of the chapter covering [posSeconds] in an arbitrary chapter list
  /// (used for the pre-buffered next book, whose chapters aren't in
  /// [_chapters] yet), the first one when none does, or -1 with no chapters.
  int _chapterIndexAt(List<dynamic> chapters, double posSeconds) {
    if (chapters.isEmpty) return -1;
    for (var i = 0; i < chapters.length; i++) {
      final m = chapters[i] as Map<String, dynamic>;
      final start = (m['start'] as num?)?.toDouble() ?? 0;
      final end = (m['end'] as num?)?.toDouble() ?? double.infinity;
      if (posSeconds >= start && posSeconds < end) return i;
    }
    return 0;
  }

  /// Returns the chapter title (or null) so _pushMediaItem can show it.
  String? _initChapterInfo(double posSeconds) {
    if (_chapters.isEmpty) return null;
    for (int i = 0; i < _chapters.length; i++) {
      final ch = _chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
      if (posSeconds >= start && posSeconds < end) {
        _currentChapterStart = start;
        _currentChapterEnd = end;
        _lastNotifiedChapterIndex = i;
        return ch['title'] as String?;
      }
    }
    // Slightly past the last chapter still counts as the last chapter.
    // Grossly past it means the chapters don't cover the timeline (e.g.
    // duplicate audio files doubling the duration, GH #345) - report no
    // chapter rather than pinning the last one.
    final graceIdx = ChapterLookup.indexAtWithGrace(
      _chapters,
      posSeconds,
      _totalDuration,
    );
    if (graceIdx != null) {
      final ch = _chapters[graceIdx] as Map<String, dynamic>;
      _currentChapterStart = (ch['start'] as num?)?.toDouble() ?? 0;
      _currentChapterEnd = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
      _lastNotifiedChapterIndex = graceIdx;
      return ch['title'] as String?;
    }
    _currentChapterStart = 0;
    _currentChapterEnd = _totalDuration;
    _lastNotifiedChapterIndex = -1;
    return null;
  }

  /// Content provider authority. Follows the installed package, as the
  /// manifest's `${applicationId}.covers` does, so the dev flavor reaches its
  /// own provider.
  static String get _coverAuthority => '${ApiService.packageName}.covers';

  void _pushMediaItem(
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration, {
    String? chapter,
    int? coverCacheBust,
    double? positionSec,
  }) {
    // Alpha [PodDur]: trace every push-site. We want to see which callers
    // pass only the parent itemId (missing -episodeId suffix) and/or a zero
    // duration, so we can pinpoint what to fix for the AA podcast progress
    // bar. Includes the current _totalDuration so "stale 0" paths are visible.
    debugPrint(
      '[PodDur] _pushMediaItem: itemId=$itemId ep=$_currentEpisodeId argDur=${totalDuration.toStringAsFixed(1)}s _totalDuration=${_totalDuration.toStringAsFixed(1)}s',
    );
    // Android: Always use content:// URI for Now Playing artwork - some OEMs
    // (e.g. Vivo) don't load HTTP URLs in MediaSession. The CoverContentProvider
    // handles both downloaded and streamed covers.
    // iOS: prefer the local cover file for downloaded books so the lock
    // screen shows artwork even when the user is offline. Fall back to the
    // remote HTTP URL when there's no local cover (streaming).
    String? effectiveCoverUrl;
    if (Platform.isIOS) {
      final localCover = DownloadService().getInfo(itemId).localCoverPath;
      if (localCover != null && localCover.isNotEmpty) {
        effectiveCoverUrl = Uri.file(localCover).toString();
      } else {
        effectiveCoverUrl = coverUrl;
      }
    } else {
      final localCover = DownloadService().getInfo(itemId).localCoverPath;
      final streamed = localCover == null || localCover.isEmpty;
      // Some re-pushes (foreground, speed, settings) pass the episode's
      // item-episode key. A downloaded episode keeps its cover under that
      // key, but the server only has covers under the item id, so a streamed
      // episode asked for that key got the placeholder note (GH #401).
      final coverId =
          streamed &&
              _currentEpisodeId != null &&
              itemId == '$_currentItemId-$_currentEpisodeId'
          ? _currentItemId!
          : itemId;
      effectiveCoverUrl = 'content://$_coverAuthority/cover/$coverId';
      if (coverCacheBust != null) effectiveCoverUrl += '?cb=$coverCacheBust';
      // Streamed cover (no local file) won't be cached on first play - schedule
      // one cache-busted re-push so the art shows up the first time too.
      if (streamed && coverCacheBust == null && _coverRepushItem != coverId) {
        _coverRepushItem = coverId;
        _scheduleStreamedCoverRepush(itemId);
      }
    }
    _updateNotificationMediaItem(
      itemId,
      title,
      author,
      effectiveCoverUrl,
      totalDuration,
      chapter: chapter,
      positionSec: positionSec,
    );
    if (_keepIdleNotificationUntilMediaPush) {
      final belongsToStart = _currentItemId != null &&
          (itemId == _currentItemId || itemId == _mediaItemKey);
      if (belongsToStart) {
        // The new book's media item (chapter title/duration included) is now
        // live; release the idle PlaybackState and publish the pinned start
        // position in one step instead of letting intermediate player events
        // move the bar first.
        _keepIdleNotificationUntilMediaPush = false;
        _idleNotificationTarget = null;
        _lastIdleMediaItemSignature = '';
        _handler?.clearIdlePlaybackState();
        _handler?.refreshPlaybackState();
      }
    }
  }

  /// Push the media item again for the chapter already showing, e.g. when a
  /// setting or the book percentage changes.
  void _repushNotifiedMediaItem({double? positionSec}) {
    _pushMediaItem(
      _mediaItemKey,
      _currentTitle ?? '',
      _currentAuthor ?? '',
      _currentCoverUrl,
      _totalDuration,
      chapter:
          _lastNotifiedChapterIndex >= 0 &&
              _lastNotifiedChapterIndex < _chapters.length
          ? (_chapters[_lastNotifiedChapterIndex]
                    as Map<String, dynamic>)['title']
                as String?
          : null,
      positionSec: positionSec,
    );
  }

  static int _bookPercent(double posSec, double totalDuration) =>
      totalDuration > 0
      ? (posSec / totalDuration * 100).floor().clamp(0, 100)
      : -1;

  double _secondsLeft(double posSec, double totalDuration) {
    final left = math.max(0.0, totalDuration - posSec);
    final speed = _player?.speed ?? 1.0;
    return _speedAdjustedTime && speed > 0 ? left / speed : left;
  }

  /// The moving parts of the media controls text at [posSec], so the
  /// position tick only re-sends it when what it shows would change.
  String _nowPlayingTicker(double posSec, double totalDuration) {
    final layout = _nowPlayingLayout;
    final percent = layout.uses(NowPlayingPiece.percent)
        ? _bookPercent(posSec, totalDuration)
        : -1;
    final minutes = layout.uses(NowPlayingPiece.timeLeft) && totalDuration > 0
        ? (_secondsLeft(posSec, totalDuration) / 60).floor()
        : -1;
    return '$percent|$minutes';
  }

  static AppLocalizations? _l10n() {
    final ctx = rootNavigatorKey.currentContext;
    return ctx != null ? AppLocalizations.of(ctx) : null;
  }

  /// Both lines of the media controls for an item, in the layout the user
  /// picked (Settings > Media Controls > Now playing text).
  ({String title, String subtitle}) _nowPlayingLines({
    required String title,
    required String author,
    required String? chapter,
    required int chapterIndex,
    required int chapterCount,
    required double posSec,
    required double totalDuration,
    String? narrator,
    String? series,
    NowPlayingLayout? layout,
  }) {
    final l = _l10n();
    final percent = _bookPercent(posSec, totalDuration);
    final left = totalDuration > 0
        ? formatHm(_secondsLeft(posSec, totalDuration))
        : null;
    final hasChapter = chapterIndex >= 0 && chapterCount > 0;
    return (layout ?? _nowPlayingLayout).build(
      NowPlayingValues(
        title: title,
        author: author,
        chapter: chapter,
        narrator: narrator,
        series: series,
        percent: percent >= 0 ? '$percent%' : null,
        chapterNumber: hasChapter
            ? (l?.nowPlayingChapterNumber(chapterIndex + 1, chapterCount) ??
                  'Ch. ${chapterIndex + 1}/$chapterCount')
            : null,
        timeLeft: left == null
            ? null
            : (l?.nowPlayingTimeLeft(left) ?? '$left left'),
      ),
    );
  }

  /// What the media controls would show for the playing item with [layout],
  /// for the settings preview; null with nothing loaded.
  ({String title, String subtitle})? previewNowPlayingLines(
    NowPlayingLayout layout,
  ) {
    if (_currentItemId == null) return null;
    final chapterIndex =
        _lastNotifiedChapterIndex >= 0 &&
            _lastNotifiedChapterIndex < _chapters.length
        ? _lastNotifiedChapterIndex
        : -1;
    return _nowPlayingLines(
      title: _currentTitle ?? '',
      author: _currentAuthor ?? '',
      chapter: chapterIndex >= 0
          ? (_chapters[chapterIndex] as Map<String, dynamic>)['title']
                as String?
          : null,
      chapterIndex: chapterIndex,
      chapterCount: _chapters.length,
      posSec: position.inMilliseconds / 1000.0,
      totalDuration: _totalDuration,
      narrator: _currentNarrator,
      series: _currentSeries,
      layout: layout,
    );
  }

  /// Narrator and series for the media controls, from a playback session's
  /// book details. Re-sends the text when they arrive after it went out.
  void _captureNowPlayingCredits(Map<String, dynamic>? session) {
    final meta = session?['mediaMetadata'];
    if (meta is! Map) return;
    String? joined(Object? names) {
      if (names is! List) return null;
      final parts = names
          .map((n) => (n is Map ? n['name'] : n)?.toString().trim() ?? '')
          .where((n) => n.isNotEmpty);
      return parts.isEmpty ? null : parts.join(', ');
    }

    final narrator =
        joined(meta['narrators']) ??
        (meta['narratorName'] is String
            ? meta['narratorName'] as String
            : null);
    String? series;
    final seriesList = meta['series'];
    if (seriesList is List &&
        seriesList.isNotEmpty &&
        seriesList.first is Map) {
      final first = seriesList.first as Map;
      final name = first['name']?.toString().trim() ?? '';
      final sequence = first['sequence']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        series = sequence.isEmpty ? name : '$name #$sequence';
      }
    } else if (meta['seriesName'] is String) {
      series = meta['seriesName'] as String;
    }
    if (narrator == _currentNarrator && series == _currentSeries) return;
    _currentNarrator = narrator;
    _currentSeries = series;
    if (_currentItemId != null &&
        (_nowPlayingLayout.uses(NowPlayingPiece.narrator) ||
            _nowPlayingLayout.uses(NowPlayingPiece.series))) {
      _repushNotifiedMediaItem();
    }
  }

  void _scheduleStreamedCoverRepush(String itemId) {
    _coverRepushAttempt = 0;
    _scheduleNextStreamedCoverRepush(itemId);
  }

  void _scheduleNextStreamedCoverRepush(String itemId) {
    _coverRepushTimer?.cancel();
    _coverRepushTimer = null;
    if (_coverRepushAttempt >= _coverRepushDelays.length) {
      // Out of attempts. _coverRepushItem stays set so a later metadata push
      // on this item doesn't restart the campaign; _clearState clears it so
      // playing the book again tries afresh.
      return;
    }
    final delay = _coverRepushDelays[_coverRepushAttempt++];
    _coverRepushTimer = Timer(Duration(seconds: delay), () {
      // Only re-push if we're still on the same item.
      if (_currentItemId == null) return;
      if (_currentItemId != itemId && _mediaItemKey != itemId) return;
      final chapterTitle =
          _lastNotifiedChapterIndex >= 0 && _chapters.isNotEmpty
          ? (_chapters[_lastNotifiedChapterIndex]
                    as Map<String, dynamic>)['title']
                as String?
          : null;
      _pushMediaItem(
        itemId,
        _currentTitle ?? '',
        _currentAuthor ?? '',
        _currentCoverUrl,
        _totalDuration,
        chapter: chapterTitle,
        coverCacheBust: DateTime.now().millisecondsSinceEpoch,
      );
      _scheduleNextStreamedCoverRepush(itemId);
    });
  }

  void _updateNotificationMediaItem(
    String itemId,
    String title,
    String author,
    String? coverUrl,
    double totalDuration, {
    String? chapter,
    double? positionSec,
  }) {
    final posSec = positionSec ?? position.inMilliseconds / 1000.0;
    final labels = _nowPlayingLines(
      title: title,
      author: author,
      chapter: chapter,
      chapterIndex: chapter == null ? -1 : _lastNotifiedChapterIndex,
      chapterCount: _chapters.length,
      posSec: posSec,
      totalDuration: totalDuration,
      narrator: _currentNarrator,
      series: _currentSeries,
    );
    _lastNowPlayingTicker = _nowPlayingTicker(posSec, totalDuration);
    // In chapter progress mode, show chapter duration instead of full book
    final rawDuration = notifChapterMode
        ? (_currentChapterEnd - _currentChapterStart)
        : totalDuration;
    // Divide by playback speed so Android Auto / WearOS / notification
    // show "real time remaining" instead of raw content duration.
    final speed = _player?.speed ?? 1.0;
    final displayDuration = speed > 0 && speed != 1.0
        ? rawDuration / speed
        : rawDuration;
    // Alpha: confirms MediaItem metadata flowing to MediaSession for GH #172
    // (BT car display stuck on prior chapter). If this fires with fresh
    // artist/chapter text but the car still shows old, the issue is downstream
    // of audio_service's MediaSession push.
    debugPrint(
      '[Handler] mediaItem.add: item=$itemId title="${labels.title}" artist="${labels.subtitle}" dur=${displayDuration.round()}s chapter=$chapter hasHandler=${_handler != null} art=${coverUrl == null
          ? 'none'
          : coverUrl.startsWith('content:')
          ? 'content'
          : coverUrl.startsWith('file:')
          ? 'file'
          : coverUrl.startsWith('http')
          ? 'http'
          : 'other'}',
    );
    _handler!.mediaItem.add(
      MediaItem(
        id: itemId,
        title: labels.title,
        artist: labels.subtitle,
        album: title,
        duration: Duration(seconds: displayDuration.round()),
        artUri: coverUrl != null ? Uri.tryParse(coverUrl) : null,
      ),
    );
  }

  void _clearState() {
    _finishedHeld = false;
    _heldFinishAction = 'clear';
    _keepIdleNotificationUntilMediaPush = false;
    _pausedAtS = null;
    _resumeAnchorS = null;
    _currentItemId = null;
    _currentEpisodeId = null;
    _currentLibraryId = null;
    _currentEpisodeTitle = null;
    _currentTitle = null;
    _currentAuthor = null;
    _currentNarrator = null;
    _currentSeries = null;
    _currentCoverUrl = null;
    _coverRepushTimer?.cancel();
    _coverRepushItem = null;
    _coverRepushAttempt = 0;
    _chapterSkipWatchTimer?.cancel();
    _chapterSkipWatchTimer = null;
    _playbackSessionId = null;
    _isOfflineMode = false;
    _localSessionMode = false;
    _localSessionAccounting = false;
    _trackStartOffsets = [];
    _trackDurations = [];
    _lastTrackPositions.clear();
    _currentTrackIndex = 0;
    _localTrackChapterIdx = const [];
    _localPlayableChapterIndices = const [];
    _isPartialLocalPlay = false;
    _localCoverageEndSec = null;
    _parkedAtBoundary = false;
    _parkedBoundaryChapterIdx = null;
    _sourceIsNetwork = false;
    _lastNotifiedChapterIndex = -1;
    _chapterJumpLatchIndex = -1;
    _lastSeekTargetSeconds = null;
    _lastSeekTime = null;
    _clearPendingLoadIntent(clearPlayRequest: true);
    _lastIndexAdvanceTime = null;
    _iosLastTrackRecoveryAttempts = 0;
    _indexSub?.cancel();
    _indexSub = null;
    _syncSub?.cancel();
    _syncSub = null;
    _completionSub?.cancel();
    _completionSub = null;
    _nativeAutoAdvanceSub?.cancel();
    _nativeAutoAdvanceSub = null;
    _lastKnownPositionSec = 0;

    _bgSaveTimer?.cancel();
    _bgSaveTimer = null;
    _eqSessionSub?.cancel();
    _eqSessionSub = null;
    _streamRetryCount = 0;
    _retryInProgress = false;

    _stuckCheckTimer?.cancel();
    _stuckCheckTimer = null;
    _playVerifyTimer?.cancel();
    _playVerifyTimer = null;
    _resetStuckDetection();
    _noisyPause = false;
    notifyListeners();
  }

  /// Snapshot the display metadata before _clearState wipes it, so a parked
  /// finish (hold / replay) can keep the "Now listening" card on screen.
  void _snapshotHeldFinish(String action) {
    _finishedHeld = true;
    _heldFinishAction = action;
    _heldItemId = _currentItemId;
    _heldSeriesId = _currentSeriesId;
    _heldTitle = _currentTitle;
    _heldAuthor = _currentAuthor;
    _heldCoverUrl = _currentCoverUrl;
    _heldLibraryId = _currentLibraryId;
    _heldEpisodeId = _currentEpisodeId;
    _heldEpisodeTitle = _currentEpisodeTitle;
    _heldTotalDuration = _totalDuration;
    _heldChapters = List<dynamic>.from(_chapters);
  }

  /// Write the parked snapshot back onto the display fields after a full
  /// _clearState, keeping only what the card needs (engine/session/tracks
  /// were already torn down).
  void _restoreHeldSnapshot() {
    _currentItemId = _heldItemId;
    _currentSeriesId = _heldSeriesId;
    _currentTitle = _heldTitle;
    _currentAuthor = _heldAuthor;
    _currentCoverUrl = _heldCoverUrl;
    _currentLibraryId = _heldLibraryId;
    _currentEpisodeId = _heldEpisodeId;
    _currentEpisodeTitle = _heldEpisodeTitle;
    _totalDuration = _heldTotalDuration;
    _chapters = List<dynamic>.from(_heldChapters);
  }

  /// Parked on a finished book: reload via playItem (the engine was stopped at
  /// completion, so we build a fresh session rather than resume a dead source).
  /// 'replay' restarts from the very beginning; 'hold' restarts at the start of
  /// the last chapter / episode.
  Future<void> _restartHeldParked() async {
    final api = _api;
    final itemId = _heldItemId;
    if (api == null || itemId == null) {
      _finishedHeld = false;
      return;
    }
    _finishedHeld = false;
    double startSec = 0;
    if (_heldFinishAction == 'hold' && _heldChapters.isNotEmpty) {
      startSec = ChapterLookup.metaStart(
        _heldChapters,
        _heldChapters.length - 1,
      );
    }
    await playItem(
      api: api,
      itemId: itemId,
      title: _heldTitle ?? '',
      author: _heldAuthor ?? '',
      coverUrl: _heldCoverUrl,
      totalDuration: _heldTotalDuration,
      chapters: _heldChapters,
      episodeId: _heldEpisodeId,
      episodeTitle: _heldEpisodeTitle,
      libraryId: _heldLibraryId,
      seriesId: _heldSeriesId,
      fromUi: true,
      startTime: startSec,
      forceStartTime: true,
    );
  }

  // How long a cached play waits for the real session before falling back to
  // the instant cached start. Long enough for LAN/WiFi round trips, short
  // enough that a slow reverse proxy doesn't make press-play feel laggy.
  static const _sessionRaceWindow = Duration(milliseconds: 700);

  // A fresh session whose tokenless URLs the playing source should adopt at
  // the next pause or seek - the two moments a source rebuild is inaudible.
  // Set whenever a session is (re)created behind an already-playing source:
  // cached fast-starts, sync-tick recreations, resume recreations. One-shot.
  Map<String, dynamic>? _pendingSessionUpgrade;
  int _pendingUpgradeGeneration = -1;

  void _stashSessionUpgrade(Map<String, dynamic> sessionData) {
    final tracks = sessionData['audioTracks'] as List<dynamic>?;
    if (tracks == null || tracks.isEmpty) return;
    _pendingSessionUpgrade = sessionData;
    _pendingUpgradeGeneration = _playbackGeneration;
    debugPrint(
      '[StreamUpgrade] Holding session ${sessionData['id']} for a swap at the next pause/seek',
    );
  }

  /// Swap the playing source onto [_pendingSessionUpgrade]'s tokenless session
  /// URLs. Called only from moments where playback is already interrupted
  /// (paused, or mid-seek), so the rebuild rides inside that interruption.
  /// Returns true when the swap happened and already landed at
  /// [seekToSeconds] (or the current position); the caller must then skip its
  /// own seek. Any failure keeps the old, still-working source.
  Future<bool> _applyPendingSessionUpgrade({
    double? seekToSeconds,
    bool resumeAfter = false,
  }) async {
    final session = _pendingSessionUpgrade;
    if (session == null || _player == null || _api == null) return false;
    if (_pendingUpgradeGeneration != _playbackGeneration ||
        _isOfflineMode ||
        _localSessionMode) {
      _pendingSessionUpgrade = null;
      return false;
    }
    // While casting, the local player isn't the real output - keep the
    // pending session for when local playback matters again.
    if (ChromecastService().isCasting) return false;
    final sessionId = session['id'] as String?;
    final tracks = session['audioTracks'] as List<dynamic>?;
    final playMethod = (session['playMethod'] as num?)?.toInt();
    if (sessionId == null ||
        sessionId != _playbackSessionId ||
        tracks == null ||
        tracks.isEmpty) {
      // Session got replaced or closed since it was stashed - a swap onto its
      // URLs would point at a dead session.
      _pendingSessionUpgrade = null;
      return false;
    }
    _pendingSessionUpgrade = null; // one-shot, success or not
    var sourceReplaced = false;
    try {
      final api = _api!;
      var target = _sourceSwapTarget(
        seekToSeconds,
        resumeAfter: resumeAfter,
      );
      // Chapter-track misalignment remap: this swap moves the player from the
      // OLD session's timeline (which the current position belongs to) onto
      // the refreshed one — when the server changed the track set, the
      // position must be re-anchored or it lands shifted by the change.
      target = await _remapStartAcrossTrackChange(target, tracks);
      final audioHeaders = api.playbackSessionHeaders;
      final trackSources = <AudioSource>[];
      var tokenless = true;
      for (final t in tracks) {
        final track = t as Map<String, dynamic>;
        final contentUrl = track['contentUrl'] as String? ?? '';
        final fullUrl = api.buildTrackUrl(
          contentUrl,
          sessionId: sessionId,
          trackIndex: (track['index'] as num?)?.toInt(),
          playMethod: playMethod,
        );
        if (fullUrl.contains('token=')) tokenless = false;
        trackSources.add(
          AudioSource.uri(
            Uri.parse(fullUrl),
            headers: _withCacheKey(audioHeaders, _currentItemId, fullUrl),
            options: mp3ExtractorOptions(),
          ),
        );
      }
      if (!tokenless) {
        // Old server or transcode session - the swap would just re-bake a
        // token, which is what the current source already has.
        debugPrint(
          '[StreamUpgrade] Session URLs still carry a token - skipping',
        );
        return false;
      }
      // Map the absolute target onto (track, local position) for the new source.
      _buildTrackOffsets(tracks);
      final idx = _trackIndexForAbsolute(target);
      final localPos = Duration(
        milliseconds: ((target - _trackStartOffsets[idx]) * 1000).round(),
      );
      // Stamp the seek target so position readers (UI, progress save) hold at
      // the target while the new source loads instead of flashing 0.
      _lastSeekTargetSeconds = target;
      _lastSeekTime = DateTime.now();
      _captureStreamUrls(
        tracks,
        api,
        sessionId: sessionId,
        playMethod: playMethod,
      );
      final source = ConcatenatingAudioSource(children: trackSources);
      _resetPreBufferState();
      // Update index BEFORE loading so positionStream events use the right offset
      _currentTrackIndex = idx;
      sourceReplaced = true;
      // A server that refuses connections left this loading for 82s with
      // Play stuck behind it (GH #344).
      await _player!
          .setAudioSource(
            source,
            initialIndex: idx,
            initialPosition: localPos,
            itemId: _currentItemId,
          )
          .timeout(_swapLoadTimeout);
      _activeConcatSource = source;
      _currentBookTrackCount = trackSources.length;
      _subscribeTrackIndex();
      if (resumeAfter) _player!.play();
      debugPrint(
        '[StreamUpgrade] Swapped to tokenless session URLs at ${target.toStringAsFixed(1)}s '
        '(track $idx, resume=$resumeAfter)',
      );
      return true;
    } catch (e) {
      if (!sourceReplaced) {
        debugPrint('[StreamUpgrade] Swap failed - keeping current source: $e');
        return false;
      }
      // The old source is already gone, so there's nothing to keep. Leave the
      // player idle: the next play() sees that and starts the item over
      // instead of pressing play on a half-loaded source.
      debugPrint(
        '[StreamUpgrade] Swap failed after replacing the source - resetting the player: $e',
      );
      try {
        await _player?.stop();
      } catch (_) {}
      if (resumeAfter) unawaited(_attemptStreamRetry(e));
      return false;
    }
  }

  static const _swapLoadTimeout = Duration(seconds: 15);

  /// Called after any token rotation. Long-lived track URLs keep the token
  /// they were built with, so swap the source onto the current session's
  /// tokenless public URLs before the next file request can 401.
  void _onApiTokenRefreshed() {
    if (_api == null || _playbackSessionId == null) return;
    if (_activeStreamUrls.isEmpty ||
        !_activeStreamUrls.any((u) => u.contains('token='))) {
      return;
    }
    if (_localSessionMode || _isOfflineMode || _knownOffline || _manualOffline) {
      return;
    }
    if (ChromecastService().isCasting) return;
    if (_isLoadingNewItem || _retryInProgress || _cacheBypassReloadInFlight) {
      Future<void>.delayed(const Duration(seconds: 3), _maybeUpgradeTokenless);
      return;
    }
    unawaited(_upgradeSourceToTokenlessSession());
  }

  void _maybeUpgradeTokenless() {
    if (_api == null || _playbackSessionId == null) return;
    if (_isLoadingNewItem || _retryInProgress || _cacheBypassReloadInFlight) {
      return;
    }
    unawaited(_upgradeSourceToTokenlessSession());
  }

  /// Rebuild the playing source with `/public/session/<id>/track/<n>` URLs.
  /// Those carry no token (the unguessable session id is the credential), so
  /// later files cannot expire mid-book. The session is the one already
  /// opened for playback; its track list matches the source order.
  Future<void> _upgradeSourceToTokenlessSession() async {
    if (_tokenlessUpgradeInFlight) return;
    final api = _api;
    final sessionId = _playbackSessionId;
    if (api == null || sessionId == null || _player == null) return;
    if (_activeStreamUrls.isEmpty || _localSessionMode || _isLoadingNewItem) {
      return;
    }
    if (_isOfflineMode || _knownOffline || _manualOffline) return;
    if (ChromecastService().isCasting) return;
    if (!_activeStreamUrls.any((u) => u.contains('token='))) return;

    if (_pendingSessionUpgrade != null) {
      final wasPlaying = _player!.playing;
      _tokenlessUpgradeInFlight = true;
      try {
        await _applyPendingSessionUpgrade(resumeAfter: wasPlaying);
      } finally {
        _tokenlessUpgradeInFlight = false;
      }
      return;
    }

    final probe = api.buildTrackUrl(
      _activeStreamUrls.first,
      sessionId: sessionId,
      trackIndex: 0,
      playMethod: 0,
    );
    if (!probe.contains('/public/session/')) {
      debugPrint(
        '[StreamUpgrade] Tokenless session URLs unavailable - keeping token URLs',
      );
      return;
    }

    final tracks = <Map<String, dynamic>>[];
    for (var i = 0; i < _activeStreamUrls.length; i++) {
      final start = _trackStartOffsets.length > i + 1
          ? _trackStartOffsets[i]
          : 0.0;
      final end = _trackStartOffsets.length > i + 1
          ? _trackStartOffsets[i + 1]
          : start;
      tracks.add({
        'contentUrl': _activeStreamUrls[i],
        'index': i,
        'duration': end > start ? end - start : 0.0,
      });
    }
    _pendingSessionUpgrade = {
      'id': sessionId,
      'audioTracks': tracks,
      'playMethod': 0,
    };
    _pendingUpgradeGeneration = _playbackGeneration;
    _tokenlessUpgradeInFlight = true;
    final wasPlaying = _player!.playing;
    try {
      final swapped = await _applyPendingSessionUpgrade(
        resumeAfter: wasPlaying,
      );
      if (!swapped) {
        debugPrint(
          '[StreamUpgrade] Tokenless source swap skipped - keeping current source',
        );
      }
    } finally {
      _tokenlessUpgradeInFlight = false;
    }
  }

  /// Attempt to recover from a stream error by restarting playback from the
  /// last known position.  Tries up to [_maxStreamRetries] times with
  /// exponential back-off (1s, 2s, 4s).  If the item has been downloaded in
  /// the meantime, falls back to local files automatically.
  Future<void> _attemptStreamRetry(Object error) async {
    if (_retryInProgress) return;
    if (_offline) {
      debugPrint('[Player] Stream retry skipped - offline');
      return;
    }
    if (_currentItemId == null || _api == null) return;
    if (_streamRetryCount >= _maxStreamRetries) {
      debugPrint(
        '[Player] Max retries reached ($_maxStreamRetries) — giving up',
      );
      return;
    }

    _retryInProgress = true;
    _streamRetryCount++;
    final delay = Duration(seconds: 1 << (_streamRetryCount - 1)); // 1s, 2s, 4s
    final failedIndex = PlaybackErrorPolicy.sourceErrorIndex(error);
    final failedTrackPos =
        failedIndex == null ? null : _lastTrackPositions[failedIndex];
    final wasPlayingBeforeRetry = _player?.playing == true;
    debugPrint(
      '[Player] Stream error — retry $_streamRetryCount/$_maxStreamRetries in ${delay.inSeconds}s'
      '${failedIndex == null ? '' : ' (failed track $failedIndex)'}',
    );

    // ExoPlayer advances to the next file on a source error. Stop that
    // auto-advanced audio at once; the retry below goes back to the file that
    // actually failed, which may be several seconds earlier.
    if (failedIndex != null && wasPlayingBeforeRetry) {
      try {
        await _player?.pause();
      } catch (_) {}
    }

    await Future<void>.delayed(delay);

    if (_cacheBypassReloadInFlight) {
      debugPrint(
        '[Player] Skipping the stream retry - the load is being redone without the cache',
      );
      _streamRetryCount--;
      _retryInProgress = false;
      return;
    }

    // Snapshot state before retry — playItem will overwrite these
    final itemId = _currentItemId;
    final title = _currentTitle ?? '';
    final author = _currentAuthor ?? '';
    final coverUrl = _currentCoverUrl;
    final totalDuration = _totalDuration;
    final chapters = List<dynamic>.from(_chapters);
    final episodeId = _currentEpisodeId;
    final episodeTitle = _currentEpisodeTitle;
    final libraryId = _currentLibraryId;
    final api = _api!;
    // The failed file is the only position worth resuming: by the time this
    // runs ExoPlayer has usually moved _lastKnownPositionSec onto the next
    // file, which is exactly the "episode skipped" symptom.
    double? failedAbsolute;
    if (failedIndex != null &&
        failedIndex >= 0 &&
        failedIndex < _trackStartOffsets.length - 1) {
      final start = _trackStartOffsets[failedIndex];
      final end = _trackStartOffsets[failedIndex + 1];
      var local = failedTrackPos ?? 0;
      if (local <= 0) {
        final target = _lastSeekTargetSec;
        if (target != null && target >= start && target < end) {
          local = target - start;
        }
      }
      failedAbsolute = (start + local).clamp(
        start,
        end > start ? end - 0.25 : end,
      );
    }
    final retryPos = failedAbsolute ??
        (_lastKnownPositionSec > 0
            ? _lastKnownPositionSec
            : (_lastSeekTargetSec ?? 0));

    if (itemId == null) {
      _retryInProgress = false;
      return;
    }

    // A stream error usually means the cached-session URLs went bad (expired
    // baked token, dead public session). Drop the cache entry so the rebuild
    // takes the fresh-session path - tokenless public URLs with a
    // known-good credential - instead of re-baking whatever just failed.
    await SessionCache.clear(itemId: itemId, episodeId: episodeId);
    // The byte range was turned down, by the server (416) or by the cache in
    // front of the player: the length on record for the file no longer
    // matches it, and the cache keeps asking up to the old length.
    if (PlaybackErrorPolicy.isCacheRangeError(error)) {
      debugPrint('[Player] Byte range refused - clearing the streaming cache');
      try {
        await AudioPlayer.clearStreamingCache();
      } catch (e) {
        debugPrint('[Player] Streaming cache clear failed: $e');
      }
    }

    debugPrint('[Player] Retrying playback at ${retryPos.toStringAsFixed(1)}s');
    // An automatic retry must honour the pause the user made before the
    // stream died: without this, playItem's clearing of [_pauseRequested]
    // let every load path start audio on its own (the "paused, then it
    // started playing by itself" report).
    final wasPaused = !wasPlayingBeforeRetry;
    // A zero/negative position is "unknown", not "the top": forcing it would
    // restart the book at chapter 1. A failed source index is a real position
    // even when it is the first file, so it is forced below.
    final hasKnownPos = retryPos > 0 || failedIndex != null;
    if (!hasKnownPos) {
      debugPrint(
        '[Player] Retry has no known position - resolving from saved progress',
      );
    }
    if (PlaybackErrorPolicy.isAuthError(error)) {
      // Re-sign track URLs with the current access token before rebuilding.
      try {
        await api.ensureMediaTokenFresh(force: true);
      } catch (_) {}
    }
    final ok = await playItem(
      api: api,
      itemId: itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      totalDuration: totalDuration,
      chapters: chapters,
      startTime: retryPos,
      forceStartTime: hasKnownPos,
      clearPauseRequest: !wasPaused,
      episodeId: episodeId,
      episodeTitle: episodeTitle,
      libraryId: libraryId,
      seriesId: null,
    );

    _retryInProgress = false;
    if (ok == null) {
      debugPrint('[Player] Retry succeeded');
    } else {
      debugPrint('[Player] Retry failed: $ok');
    }
  }

  int _lastSyncSecond = -1;
  int _lastBgProcessedSec = -1;

  StreamSubscription? _eqSessionSub;

  void _attachEqualizer() {
    _eqSessionSub?.cancel();
    _eqSessionSub = null;
    if (_player == null) return;

    // Try immediately — works if audio source is already set
    final sessionId = _player!.androidAudioSessionId;
    if (sessionId != null && sessionId > 0) {
      EqualizerService().attachToSession(sessionId);
      return;
    }

    // Not available yet — poll briefly after playback starts
    // (safer than androidAudioSessionIdStream which may not exist in all versions)
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_player == null) return;
      final id = _player!.androidAudioSessionId;
      if (id != null && id > 0) {
        debugPrint('[Player] Got audio session ID (delayed): $id');
        EqualizerService().attachToSession(id);
      } else {
        // Try once more after another second
        Future.delayed(const Duration(seconds: 1), () {
          if (_player == null) return;
          final id2 = _player!.androidAudioSessionId;
          if (id2 != null && id2 > 0) {
            debugPrint('[Player] Got audio session ID (retry): $id2');
            EqualizerService().attachToSession(id2);
          }
        });
      }
    });
  }

  void _setupSync() {
    _syncSub?.cancel();
    _completionSub?.cancel();
    _nativeAutoAdvanceSub?.cancel();
    _bgSaveTimer?.cancel();
    _lastSyncSecond = -1;
    _lastBgProcessedSec = -1;
    _lastChapterCheckSec = -1;
    _lastKnownPositionSec = 0;
    _lastServerSync = DateTime.now();
    _lastAccrual = DateTime.now();
    _lastAccrualPos = null;
    _positionSyncInProgress = false;
    _positionSyncFailures = 0;
    _noSessionSyncRetryAt = null;
    // Cache prefs in background - not needed synchronously here
    if (_prefs == null) {
      SharedPreferences.getInstance().then((p) => _prefs = p);
    }

    // Safety-net timer for position persistence when Android throttles the
    // Dart position stream in the background. The primary positionStream
    // listener saves every 5s; this only matters when that stream goes silent.

    _bgSaveTimer = Timer.periodic(const Duration(seconds: 300), (_) async {
      if (_currentItemId == null || _player == null || !_player!.playing)
        return;
      final pos = _positionForProgressSave;
      final posSec = pos.inMilliseconds / 1000.0;
      if (posSec <= 0) return;
      await _saveProgressLocal(pos);
      // Backstop: if the position stream is frozen (Doze), this still banks
      // listening. Shares _lastAccrual so it can't double-count live ticks.
      await _accrueListening(pos);
    });

    // Attach equalizer to current audio session
    _attachEqualizer();

    // Native iOS engine fires bookAutoAdvancedStream when it has swapped to
    // the pre-buffered next book. Empty stream on Android / iOS-flag-off, so
    // this is a no-op everywhere else.
    _nativeAutoAdvanceSub?.cancel();
    _nativeAutoAdvanceSub = _player?.bookAutoAdvancedStream.listen((_) {
      if (_preloadedNextBook != null) {
        debugPrint(
          '[NativeEngine] bookAutoAdvanced received — firing auto-queue advance',
        );
        _onAutoQueueAdvanced();
      }
    });

    // ─── Primary completion detection via processingState ───
    // This fires reliably when ExoPlayer reaches STATE_ENDED, before any
    // position-reset can confuse the position-based detection.
    _completionSub = _player?.processingStateStream.listen(
      (state) {
        if (state == ProcessingState.completed &&
            _currentItemId != null &&
            _endSignalIsTrustworthy) {
          if (_preloadedNextBook != null) {
            debugPrint(
              '[PreBuffer] processingState=completed with pre-buffer loaded — firing auto-queue advance',
            );
            _onAutoQueueAdvanced();
          } else {
            _onPlaybackComplete();
          }
        }
        // Notify UI when buffering/loading state changes so spinners update.
        // Skip when backgrounded - no visible UI to rebuild; flushed on foreground.
        if (!_isBackgrounded &&
            (state == ProcessingState.ready ||
                state == ProcessingState.loading ||
                state == ProcessingState.buffering)) {
          notifyListeners();
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[Player] processingState stream error: $e');
        // Paused: no audible stream to rescue (see the position-stream guard).
        if (_player?.playing != true) return;
        _attemptStreamRetry(e);
      },
    );
    _syncSub = _player?.positionStream.listen(
      (trackRelativePos) async {
        // Reset retry counter on successful position updates
        _streamRetryCount = 0;
        final posTrack = _player?.currentIndex ?? _currentTrackIndex;
        if (posTrack >= 0) {
          _lastTrackPositions[posTrack] =
              trackRelativePos.inMilliseconds / 1000.0;
          while (_lastTrackPositions.length > 32) {
            _lastTrackPositions.remove(_lastTrackPositions.keys.first);
          }
        }
        // Convert track-relative position to absolute book position
        final absolutePos = position; // uses the getter which adds track offset
        final sec = absolutePos.inSeconds;
        final posSec = absolutePos.inMilliseconds / 1000.0;

        // After a track advance, push once now that the new position has landed
        // so the background lock screen isn't left stale until foreground.
        if (_pendingTrackAdvanceRefresh) {
          _pendingTrackAdvanceRefresh = false;
          _handler?.refreshPlaybackState();
        }

        // ─── Position-reset guard ────────────────────────────
        // ExoPlayer can seek to 0 on STATE_ENDED. If we were near the end
        // and suddenly jump to near 0 without a user seek, treat it as
        // completion rather than restarting playback.
        if (_lastKnownPositionSec > 0 && _totalDuration > 0) {
          final wasNearEnd = _lastKnownPositionSec >= _totalDuration - 5.0;
          final nowNearStart = posSec < 2.0;
          // A rebuilt/buffering source also resets to 0 after a stall. Only a
          // genuine completed engine may turn that reset into a book finish.
          if (wasNearEnd && nowNearStart &&
              _endSignalIsTrustworthy &&
              _player?.processingState == ProcessingState.completed) {
            if (_preloadedNextBook != null) {
              debugPrint(
                '[PreBuffer] Position jump near-end → 0 with pre-buffer loaded — firing auto-queue advance',
              );
              _onAutoQueueAdvanced();
              return;
            }
            debugPrint(
              '[Player] Position jumped from ${_lastKnownPositionSec.toStringAsFixed(1)}s to ${posSec.toStringAsFixed(1)}s — treating as completion',
            );
            _onPlaybackComplete();
            return;
          }
        }
        if (posSec > 0) _lastKnownPositionSec = posSec;

        _maybePreloadNextBook();

        // On iOS in background, fire the cross-book transition just before the
        // current item ends. The native handover swaps the player item in one
        // step, keeping the AVPlayer rate continuous so iOS doesn't drop the
        // background route. Foreground still uses the regular auto-advance path.
        if (Platform.isIOS &&
            _isBackgrounded &&
            _preloadedNextBook != null &&
            !_autoQueueAdvancing &&
            _totalDuration > 0 &&
            (_player?.playing ?? false)) {
          final remaining = _totalDuration - posSec;
          if (remaining > 0 && remaining <= 0.5) {
            debugPrint(
              '[PreBuffer] Proactive iOS transition at remaining=${remaining.toStringAsFixed(2)}s',
            );
            _onAutoQueueAdvanced();
            return;
          }
        }

        if (sec <= 0) return;

        // In background, only process once per second to save CPU.
        if (_isBackgrounded) {
          if (sec == _lastBgProcessedSec) return;
          _lastBgProcessedSec = sec;
        }

        // ─── Chapter change detection ──────────────────────────
        // Update notification subtitle when the chapter changes.
        // Throttled to once per second — chapters can't change faster than that.
        if (_chapters.isNotEmpty &&
            _currentItemId != null &&
            sec != _lastChapterCheckSec) {
          _lastChapterCheckSec = sec;
          int chapterIdx = -1;
          String? chapterTitle;
          double chapterStart = 0;
          double chapterEnd = _totalDuration;

          // Resolve against the load-aware position, NOT the raw stream tick:
          // while a seek awaits its engine switch, [_currentTrackIndex] already
          // points at the TARGET track but [_player.position] still reports the
          // OLD track's offset, so the composed absolute seconds sit at the
          // book's tail — mapping to the LAST chapter until the switch lands.
          // On a slow link that tail can persist for a while, surfacing as a
          // lingering "last chapter" title (the UI card already avoids this via
          // chapterResolvePosSec; mirror it here).
          final resolveSec = chapterResolvePosSec;

          // Chapter-jump latch: after a jump the engine can sit a hair before
          // the intended chapter's metadata start (metadata vs per-file
          // timeline drift); position lookup could otherwise demote the title
          // back to the PREVIOUS chapter. Merely reserving [chapterIdx] as the
          // latched index blocks the slow path — the latched chapter was
          // already pushed and [_lastNotifiedChapterIndex] set, so the change
          // guard below stays silent. Release once the position truly passes
          // the latched chapter's end.
          if (_chapterJumpLatchIndex >= 0) {
            final lEnd =
                (_chapters[_chapterJumpLatchIndex]['end'] as num?)
                    ?.toDouble() ??
                _totalDuration;
            if (resolveSec < lEnd) {
              chapterIdx = _chapterJumpLatchIndex;
              chapterTitle =
                  (_chapters[_chapterJumpLatchIndex]['title'] as String?)
                          ?.isEmpty ==
                      true
                  ? null
                  : _chapters[_chapterJumpLatchIndex]['title'] as String?;
            } else {
              _chapterJumpLatchIndex = -1;
            }
          }

          // Fast path: check if still in the cached chapter
          if (_lastNotifiedChapterIndex >= 0 &&
              _lastNotifiedChapterIndex < _chapters.length) {
            final ch =
                _chapters[_lastNotifiedChapterIndex] as Map<String, dynamic>;
            final s = (ch['start'] as num?)?.toDouble() ?? 0;
            final e = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
            if (resolveSec >= s && resolveSec < e) {
              chapterIdx = _lastNotifiedChapterIndex;
              chapterTitle = ch['title'] as String?;
              chapterStart = s;
              chapterEnd = e;
            }
          }

          // Slow path: linear scan only if cached chapter didn't match
          if (chapterIdx < 0) {
            for (int i = 0; i < _chapters.length; i++) {
              final ch = _chapters[i] as Map<String, dynamic>;
              final start = (ch['start'] as num?)?.toDouble() ?? 0;
              final end = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
              if (resolveSec >= start && resolveSec < end) {
                chapterIdx = i;
                chapterTitle = ch['title'] as String?;
                chapterStart = start;
                chapterEnd = end;
                break;
              }
            }
          }

          // Within the grace window past the last chapter, keep the last one
          if (chapterIdx < 0) {
            final g = ChapterLookup.indexAtWithGrace(
              _chapters,
              resolveSec,
              _totalDuration,
            );
            if (g != null) {
              final ch = _chapters[g] as Map<String, dynamic>;
              chapterIdx = g;
              chapterTitle = ch['title'] as String?;
              chapterStart = (ch['start'] as num?)?.toDouble() ?? 0;
              chapterEnd = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
            }
          }

          // At the download boundary: the resolve position sits exactly on
          // the next (undownloaded) chapter's start, which the scans above
          // happily report — and during the window before the async park
          // lands, nothing else would correct a push made in between. Keep
          // the last downloaded chapter on the lock screen / Android Auto
          // until the user navigates or plays on.
          final boundaryIdx = _boundaryChapterOverride(resolveSec);
          if (boundaryIdx != null) {
            final ch = _chapters[boundaryIdx] as Map<String, dynamic>;
            chapterIdx = boundaryIdx;
            chapterTitle = ch['title'] as String?;
            chapterStart = ChapterLookup.metaStart(_chapters, boundaryIdx);
            chapterEnd = (ch['end'] as num?)?.toDouble() ?? _totalDuration;
          }

          if (chapterIdx < 0 && _lastNotifiedChapterIndex >= 0) {
            // Position left the chapter span entirely - clear the stale
            // chapter so the notification stops claiming the last one
            debugPrint(
              '[Battery] Chapter cleared: ${posSec.toStringAsFixed(1)}s is outside the chapter span',
            );
            _lastNotifiedChapterIndex = -1;
            _currentChapterStart = 0;
            _currentChapterEnd = _totalDuration;
            _pushMediaItem(
              _currentItemId!,
              _currentTitle ?? '',
              _currentAuthor ?? '',
              _currentCoverUrl,
              _totalDuration,
            );
          }

          if (chapterIdx >= 0 && chapterIdx != _lastNotifiedChapterIndex) {
            debugPrint(
              '[Battery] Chapter change: idx=$chapterIdx "$chapterTitle" at ${posSec.toStringAsFixed(1)}s',
            );
            _lastNotifiedChapterIndex = chapterIdx;
            _currentChapterStart = chapterStart;
            _currentChapterEnd = chapterEnd;
            _pushMediaItem(
              _currentItemId!,
              _currentTitle ?? '',
              _currentAuthor ?? '',
              _currentCoverUrl,
              _totalDuration,
              chapter: chapterTitle,
              positionSec: posSec,
            );
            // Force PlaybackState refresh so the notification position resets
            // to 0 immediately instead of waiting for the next stream event.
            if (_notifChapterMode) _handler?.refreshPlaybackState();
          }
        }

        // ─── Chapter skip (intro/outro) ───────────────────────────
        // Check if we should skip chapter intro or outro based on settings.
        // Runs on every position tick when playing with chapters.
        if (_player?.playing == true &&
            _chapters.isNotEmpty &&
            _currentItemId != null &&
            posSec > 0) {
          await _maybeSkipChapterIntroOutro(posSec);
        }
        if (_currentItemId != null &&
            _nowPlayingTicker(posSec, _totalDuration) !=
                _lastNowPlayingTicker) {
          _repushNotifiedMediaItem(positionSec: posSec);
        }

        // ─── Completion detection (fallback) ───────────────────
        // processingStateStream is the primary signal; this is a safety net.
        // Files that run longer than the server indexed them (changed on
        // disk after a scan) play on: ending the book at the indexed length
        // tore the player down mid-audio and left it stuck (GH #428).
        if (_totalDuration > 0 &&
            posSec >= _totalDuration - 1.0 &&
            !_engineAtEnd()) {
          if (_overrunLoggedFor != _currentItemId) {
            _overrunLoggedFor = _currentItemId;
            debugPrint(
              '[Player] Audio runs past the indexed length '
              '(${_totalDuration.toStringAsFixed(0)}s) - playing on until the files end',
            );
          }
        } else if (_totalDuration > 0 &&
            posSec >= _totalDuration - 1.0 &&
            _endSignalIsTrustworthy) {
          if (_preloadedNextBook != null && _isBackgrounded && Platform.isIOS) {
            debugPrint(
              '[PreBuffer] Position-fallback near end with pre-buffer loaded — firing auto-queue advance',
            );
            _onAutoQueueAdvanced();
            return;
          }
          _onPlaybackComplete();
          return;
        }

        // Save locally every 5 seconds (always works, even offline)
        if (sec % 5 == 0 && sec != _lastSyncSecond && _currentItemId != null) {
          _lastSyncSecond = sec;
          final progressPos = _positionForProgressSave;
          _saveProgressLocal(progressPos);
          // Seeks emit position events while paused too (auto-rewind on
          // resume, scrubbing), and such a tick must not accrue or sync -
          // the clocks are stale from the pause, so it would credit the
          // paused span as listening. The pause handler already banked the
          // playing tail.
          if (_player?.playing != true) return;
          // Bank listening to durable storage every tick, decoupled from the
          // server push below, so an abrupt kill loses at most one tick.
          await _accrueListening(absolutePos);
          if (_isCachedStartReconcilePending) return;

          // Push to server every 20s regardless of foreground state, in line
          // with the other ABS clients (official 15s, web 10s). Accuracy rides
          // on the accrual above, not this cadence - this is just server
          // freshness.
          const syncInterval = 20;
          final sinceLastSync = DateTime.now()
              .difference(_lastServerSync)
              .inSeconds;
          if (sinceLastSync >= syncInterval && !_positionSyncInProgress) {
            _positionSyncInProgress = true;
            try {
              final manualOffline =
                  (_prefs ?? await SharedPreferences.getInstance()).getBool(
                    'manual_offline_mode',
                  ) ??
                  false;

              // If we're online but lost the playback session (e.g. pause-
              // timeout closed it and _resumeServerSync silently failed when
              // playback resumed), recreate it before the accumulator branch.
              // Without this the offline accumulator fills for hours and gets
              // dumped later as one phantom session with startTime==lastTime.
              // Skipped for local-session plays — they never open a /play session.
              if (!_localSessionMode &&
                  !manualOffline &&
                  !_isOfflineMode &&
                  _playbackSessionId == null &&
                  !_isLoadingNewItem &&
                  _api != null &&
                  _currentItemId != null &&
                  !_recreatingSession) {
                if (_sourceSessionless) {
                  // Presence-only session: no full /play track list.
                  await _ensureStatsSessionForSessionlessSource();
                } else {
                  await _recreateSessionInSyncTick();
                }
              }

              // Listening itself is banked every tick by _accrueListening. These
              // branches only handle the interval-rate bookkeeping (time-saved,
              // widget tick) and, for downloaded plays, pushing the local session.
              final secs = sinceLastSync.clamp(0, 300);
              if (_localSessionMode || _localSessionAccounting) {
                final online =
                    !manualOffline && !_isOfflineMode && _api != null;
                unawaited(
                  _progressSync.addTimeSaved(secs, _player?.speed ?? 1.0),
                );
                unawaited(HomeWidgetService().addLocalListeningSeconds(secs));
                if (online) await LocalSessionService().pushActive(api: _api!);
                _lastServerSync = DateTime.now();
              } else if (manualOffline ||
                  _isOfflineMode ||
                  _playbackSessionId == null) {
                unawaited(
                  _progressSync.addTimeSaved(secs, _player?.speed ?? 1.0),
                );
                // Widget ticks forward even when the server is unreachable.
                unawaited(HomeWidgetService().addLocalListeningSeconds(secs));
                _lastServerSync = DateTime.now();
              }

              // Back off when the server is unreachable to avoid hammering
              // every sync interval with requests that will just timeout.
              // The pause is timed and grows with each failure, so a bad
              // minute during a WiFi-to-cellular handover doesn't leave the
              // server stale for the rest of the listen.
              if (_positionSyncFailures >= 3 &&
                  _noSessionSyncRetryAt != null &&
                  DateTime.now().isBefore(_noSessionSyncRetryAt!)) {
                _lastServerSync = DateTime.now();
              } else if (manualOffline) {
                // Manual offline - local save only, no server sync
              } else if (!_isOfflineMode && _playbackSessionId != null) {
                // Streaming/local with session: sync via session
                _syncToServer(progressPos);
              } else if (!_isOfflineMode &&
                  _api != null &&
                  _currentItemId != null) {
                // No session but online - sync via progress update endpoint
                try {
                  final syncKey = _currentEpisodeId != null
                      ? '$_currentItemId-$_currentEpisodeId'
                      : _currentItemId!;
                  final ok = await _progressSync.syncToServer(
                    api: _api!,
                    itemId: syncKey,
                  );
                  if (ok) {
                    debugPrint('[Player] No-session sync succeeded');
                    _positionSyncFailures = 0;
                    _noSessionSyncRetryAt = null;
                  } else {
                    _noteNoSessionSyncFailure('returned false');
                  }
                } catch (e) {
                  _noteNoSessionSyncFailure('error: $e');
                }
              }
            } finally {
              _positionSyncInProgress = false;
            }
          }
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('[Player] Position stream error: $e');
        // A paused player has no audible stream to rescue: rebuilding here
        // would only churn a fresh session (and, before the pause-intent
        // guard, start audio the user had paused). The next play() sees the
        // broken source and takes the rebuild paths itself.
        if (_player?.playing != true) {
          debugPrint(
            '[Player] Paused - not retrying on the position stream error',
          );
          return;
        }
        _attemptStreamRetry(e);
      },
    );

    // Start stuck position detection (xHE-AAC/USAC iOS seek failures)
    _startStuckDetection();
  }

  /// Reset stuck detection state - call on manual seek or when position advances.
  void _resetStuckDetection() {
    _stuckConsecutiveCount = 0;
    _stuckReseekAttempts = 0;
    _stuckCheckLastPosition = -1;
  }

  /// Whether the current source is a remote stream rather than downloaded
  /// local files. A frozen position on a remote source means its URL went bad,
  /// which re-seeking cannot fix - the session/URLs have to be rebuilt.
  bool get _streamIsRemote {
    final itemId = _currentItemId;
    if (itemId == null) return false;
    return !_downloadService.isDownloaded(
      playbackDownloadKey(itemId, _currentEpisodeId),
    );
  }

  /// Verify that playback actually started after calling play().
  /// iOS USAC/xHE-AAC decoder can silently fail after a seek, leaving the
  /// player in a non-playing state with no error events. If after 3 seconds
  /// the player isn't playing and isn't loading, re-seek and retry.
  void _schedulePlayVerify() {
    _playVerifyTimer?.cancel();
    if (!Platform.isIOS) return; // only needed on iOS
    final posAtPlay = _lastKnownPositionSec;
    _playVerifyTimer = Timer(const Duration(seconds: 3), () async {
      if (_player == null || _currentItemId == null) return;
      // If playing or actively loading/buffering, all is well
      if (_player!.playing) return;
      final state = _player!.processingState;
      if (state == ProcessingState.loading ||
          state == ProcessingState.buffering)
        return;
      // Player is idle/ready but not playing — silent failure
      final currentPos = position.inMilliseconds / 1000.0;
      debugPrint(
        '[Player] Play verify failed: not playing after 3s '
        '(state=${state.name}, pos=${currentPos.toStringAsFixed(1)}s, '
        'posAtPlay=${posAtPlay.toStringAsFixed(1)}s)',
      );
      // Re-seek to current position to kick the decoder, then retry play.
      // Activate the session first: a resume right after an interruption can
      // fail with "cannot interrupt others" while the interrupter still holds
      // the audio, and a bare play() on a never-activated session stays
      // silent even once it has let go.
      await _seekAbsolute(currentPos > 0 ? currentPos : posAtPlay);
      try {
        await (await AudioSession.instance).setActive(true);
      } catch (e) {
        debugPrint('[Player] Play verify: session activate failed: $e');
      }
      _player?.play();
      notifyListeners();
    });
  }

  /// Start a periodic timer that checks if playback position is advancing.
  /// Detect a position frozen while the player claims to be playing, and
  /// recover. Two failures share this shape:
  ///  - iOS xHE-AAC/USAC decoder freeze: re-seeking the same source kicks it.
  ///  - A dead stream URL that never surfaces an error - e.g. a rotated token
  ///    on the direct-file fallback, which can sit in `buffering` forever
  ///    instead of erroring. Re-seeking the same URL is useless there, so the
  ///    session/URLs are rebuilt instead (fresh token via [_attemptStreamRetry]).
  /// Runs on every platform; Android checks less often to limit wakeups.
  void _startStuckDetection() {
    _stuckCheckTimer?.cancel();
    _resetStuckDetection();

    final interval = Platform.isIOS
        ? const Duration(seconds: 10)
        : const Duration(seconds: 15);

    _stuckCheckTimer = Timer.periodic(interval, (_) async {
      // Only check while actively playing
      if (_player == null || !_player!.playing) {
        _stuckCheckLastPosition = -1;
        _stuckConsecutiveCount = 0;
        return;
      }

      final state = _player!.processingState;
      final buffering =
          state == ProcessingState.loading ||
          state == ProcessingState.buffering;

      final currentPos = position.inMilliseconds / 1000.0;
      if (currentPos <= 0) return;

      if (_stuckCheckLastPosition >= 0) {
        // Check if position has advanced (allow small tolerance for rounding)
        final advanced = (currentPos - _stuckCheckLastPosition).abs() > 0.1;
        if (advanced) {
          // Position is moving - reset counters
          _stuckConsecutiveCount = 0;
          _stuckReseekAttempts = 0;
        } else {
          // Position hasn't moved
          _stuckConsecutiveCount++;
          // A dead URL can stay in `buffering` indefinitely, so a stall there
          // counts too - but only after a longer grace period than a plain
          // decoder freeze, sparing a legitimately slow buffer on a poor link.
          final threshold = buffering ? 4 : 2;
          if (_stuckConsecutiveCount >= threshold) {
            _stuckConsecutiveCount = 0;
            if (_streamIsRemote &&
                !_retryInProgress &&
                _streamRetryCount < _maxStreamRetries) {
              debugPrint(
                '[Player] Silent stall at ${currentPos.toStringAsFixed(1)}s '
                '(${buffering ? 'buffering' : 'ready'}) - rebuilding stream',
              );
              _logEvent(
                PlaybackEventType.sessionStart,
                detail: 'stall recovery',
              );
              await _attemptStreamRetry(
                StateError('silent stall at ${currentPos.toStringAsFixed(1)}s'),
              );
            } else if (_stuckReseekAttempts < _maxStuckReseekAttempts) {
              // Local files or retries exhausted - kick the decoder instead.
              _stuckReseekAttempts++;
              debugPrint(
                '[Player] Stuck position detected - re-seeking '
                '(attempt $_stuckReseekAttempts/$_maxStuckReseekAttempts '
                'at ${currentPos.toStringAsFixed(1)}s)',
              );
              await _seekAbsolute(currentPos);
            }
          }
        }
      }

      _stuckCheckLastPosition = currentPos;
    });
  }

  bool _isCompletingBook = false;

  String? _overrunLoggedFor;

  // ─── Chapter-track alignment (advanced setting) ─────────────────────────

  /// Per-item cooldown for the alignment, so a book the server refuses to
  /// fix doesn't get retried on every single playback start.
  static final Map<String, DateTime> _alignAttemptAt = {};

  /// The session tracks the current timeline was built from — the alignment
  /// rebuilds chapters from them (durations AND titles), so the written
  /// chapters are consistent with what the player is actually playing.
  List<dynamic>? _lastSourceTracks;

  /// Audiobookshelf updates the audio tracks when files change on disk but
  /// does NOT rebuild the chapters: a deleted episode file leaves its chapter
  /// entry behind, and playback shows the removed episode's title over the
  /// NEXT episode's audio. When the advanced toggle is on, a playback start
  /// whose chapter count differs from the track count rebuilds the chapters
  /// "one per track" from the in-memory session tracks (title = track title,
  /// start / end = the timeline's own durations) and PATCHes them back to the
  /// server via the same manual-edit endpoint the ABS web UI uses, then
  /// adopts the fixed list live. Detection is free (both lists are in
  /// memory); the common case needs NO fetch at all — a single GET for the
  /// disk filenames happens only when some track titles are missing, and a
  /// POST only when the count mismatch is being fixed. One POST per fix:
  /// after it lands, the next playback start's detection passes and nothing
  /// more is written.
  /// Public entry for the alignment — called after a successful playback
  /// start AND when a server item_updated lands for the currently playing
  /// book (the track change reaches an active listener immediately instead
  /// of waiting for the next playback start).
  Future<void> alignChaptersWithTracksIfStale() async {
    try {
      if (!(await PlayerSettings.getAlignChaptersTracks())) return;
      final api = _api;
      if (api == null || _offline) return;
      // Books only: a podcast episode's chapters live inside its own file and
      // its library item's audioFiles cover every episode — rebuilding there
      // would flatten the show into one chapter per EPISODE.
      if (_currentItemId == null || _currentEpisodeId != null) return;
      // A PARTIAL local play's timeline ends at the last downloaded file, not
      // the book — the span check below would read the missing tail as stale
      // chapters and flatten them.
      if (_isPartialLocalPlay) return;
      final trackCount = _trackDurations.length;
      if (trackCount <= 0 || _chapters.isEmpty) return;
      // A single whole-file book can never be rebuilt meaningfully: "one
      // chapter per track" would collapse to a single chapter, and its
      // embedded/auto-detected chapters are time MARKERS on that file, not
      // file boundaries. Never touch them here (the chapter editor is the
      // right tool for a replaced single file).
      if (trackCount == 1) return;
      if (_chapters.length == trackCount) return; // already aligned
      // A count mismatch alone is NOT proof of staleness: embedded chapters
      // legitimately sit on the current timeline, and their last end can sit
      // BEFORE it (trailing silence trimmed, credits gap). The DIRECTIONS
      // differ, though:
      //  - a span poking PAST the audio's end is almost certainly a stale
      //    leftover — chapters pointing into files that no longer exist.
      //    Chapter markers are frame-accurate, so a few seconds of overshoot
      //    already means staleness (a deleted 10s intro file is caught);
      //  - a span ending early is ambiguous with hand-tuned chapters, so that
      //    direction keeps a wide tolerance (only a missing episode file —
      //    minutes of uncovered audio — counts as stale).
      final timelineEnd =
          _trackStartOffsets.isNotEmpty ? _trackStartOffsets.last : 0.0;
      final existingLastEnd =
          (_chapters.last['end'] as num?)?.toDouble() ?? timelineEnd;
      final stale = existingLastEnd - timelineEnd > 5.0 ||
          timelineEnd - existingLastEnd > 30.0;
      if (!stale) {
        return; // chapters live on the current timeline — leave them alone
      }
      final itemId = _currentItemId!;
      final now = DateTime.now();
      final last = _alignAttemptAt[itemId];
      if (last != null && now.difference(last) < const Duration(minutes: 30)) {
        return;
      }
      if (_alignAttemptAt.length > 64) _alignAttemptAt.clear();
      _alignAttemptAt[itemId] = now;

      // Build from the session tracks the timeline was built from. Durations
      // come from [_trackDurations] (the SAME values that define the current
      // timeline, so the written chapters can never disagree with playback).
      final sourceTracks = _lastSourceTracks;
      final titles = <String>[];
      var titlesUsable = sourceTracks != null &&
          sourceTracks.length == trackCount;
      if (titlesUsable) {
        for (final t in sourceTracks) {
          final title =
              ((t as Map<String, dynamic>)['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) {
            titlesUsable = false;
            break;
          }
          titles.add(title);
        }
      }
      var built = <Map<String, dynamic>>[];
      if (titlesUsable) {
        double cursor = 0;
        for (var i = 0; i < trackCount; i++) {
          final dur = _trackDurations[i];
          built.add({
            'title': titles[i],
            'start': double.parse(cursor.toStringAsFixed(3)),
            'end': double.parse((cursor + dur).toStringAsFixed(3)),
          });
          cursor += dur;
        }
      } else {
        // Track titles missing (some sessions omit them): fall back to ONE
        // light GET for the disk filenames. The file count must still match
        // the session tracks — a scan mid-flight would produce a chapter list
        // for a file set the player is not even playing.
        final item = await api.getLibraryItemLite(itemId);
        final media = item?['media'];
        if (media is! Map<String, dynamic>) return;
        final files = media['audioFiles'];
        if (files is! List || files.isEmpty) return;
        double cursor = 0;
        var order = 0;
        for (final f in files) {
          if (f is! Map<String, dynamic>) continue;
          order++;
          final meta = (f['metadata'] as Map<String, dynamic>? ?? {});
          final name = ((meta['filename'] ?? meta['path'] ?? '') as String);
          final stem = name.contains('.')
              ? name.substring(0, name.lastIndexOf('.'))
              : name;
          final dur = (f['duration'] as num?)?.toDouble() ?? 0;
          built.add({
            'title': stem.trim().isEmpty ? 'Chapter $order' : stem.trim(),
            'start': double.parse(cursor.toStringAsFixed(3)),
            'end': double.parse((cursor + dur).toStringAsFixed(3)),
          });
          cursor += dur;
        }
        if (built.length != trackCount) {
          debugPrint(
            '[AlignChapters] $itemId: audioFiles ${built.length} != session '
            'tracks $trackCount - server scan still settling, skipping',
          );
          return;
        }
      }
      final ok = await api.updateItemChapters(itemId, built);
      if (!ok) return;
      debugPrint(
        '[AlignChapters] $itemId: rebuilt ${built.length} chapters (had '
        '${_chapters.length}) - POSTed to the server and adopted live',
      );
      adoptServerChapters(built);
    } catch (e) {
      debugPrint('[AlignChapters] failed: $e');
    }
  }

  /// Remap a saved absolute position from the STALE chapter/track timeline
  /// onto the current session's track timeline.
  ///
  /// When the server's tracks were updated without rebuilding the chapters (a
  /// deleted episode file is the classic case), every saved position is an
  /// absolute value on the OLD track timeline and lands shifted on the new
  /// one — resuming after a deleted front file skips ahead by that file's
  /// duration. The position's stale chapter is matched to a current track by
  /// TITLE (the same titles the alignment writes) and the intra-chapter
  /// offset is re-anchored onto that track's start on the new timeline.
  /// Guards mirror the alignment (advanced toggle, books, multi-track, count
  /// mismatch); an unmatched title returns the position untouched — never
  /// guess.
  Future<double> _remapStartAcrossTrackChange(
    double startSec,
    List<dynamic> tracks,
  ) async {
    try {
      if (tracks.length <= 1) return startSec;
      if (!(await PlayerSettings.getAlignChaptersTracks())) return startSec;
      if (_currentEpisodeId != null) return startSec;
      final chapters = _chapters;
      if (chapters.isEmpty || chapters.length == tracks.length) {
        return startSec;
      }
      // Which stale chapter holds the position?
      int? k;
      for (var i = 0; i < chapters.length; i++) {
        final c = chapters[i] as Map<String, dynamic>;
        final s = (c['start'] as num?)?.toDouble() ?? 0;
        final e = (c['end'] as num?)?.toDouble() ?? double.infinity;
        if (startSec >= s && startSec < e) {
          k = i;
          break;
        }
      }
      if (k == null) return startSec;
      final ch = chapters[k] as Map<String, dynamic>;
      final chStart = (ch['start'] as num?)?.toDouble() ?? 0;
      final title = (ch['title'] as String? ?? '').trim();
      if (title.isEmpty) return startSec;
      // The same titles the alignment writes: match the stale chapter to the
      // current track and re-anchor the intra-chapter offset onto that
      // track's start on the NEW timeline.
      int? j;
      double cursor = 0;
      final starts = List<double>.filled(tracks.length, 0);
      for (var i = 0; i < tracks.length; i++) {
        starts[i] = cursor;
        final t = tracks[i] as Map<String, dynamic>;
        cursor += (t['duration'] as num?)?.toDouble() ?? 0;
        if (j == null && (t['title'] as String? ?? '').trim() == title) {
          j = i;
        }
      }
      if (j == null) return startSec;
      final trackDur =
          ((tracks[j] as Map<String, dynamic>)['duration'] as num?)
              ?.toDouble() ??
          0;
      final intra = (startSec - chStart).clamp(0.0, trackDur);
      final remapped = (starts[j] + intra).clamp(0.0, cursor);
      debugPrint(
        '[AlignChapters] resume remap: ${startSec.toStringAsFixed(1)}s -> '
        '${remapped.toStringAsFixed(1)}s (stale chapter "$title" -> track $j)',
      );
      return remapped;
    } catch (e) {
      debugPrint('[AlignChapters] resume remap failed: $e');
      return startSec;
    }
  }

  /// A stall, a stream rebuild or a transient position reset can make the
  /// engine look finished while the current book is still playing. Only a
  /// settled engine may complete a book or advance the queue: a random buffer
  /// hiccup must never jump to the next episode from the beginning.
  bool get _endSignalIsTrustworthy {
    final p = _player;
    if (p == null) return false;
    if (_retryInProgress || _isLoadingNewItem || _autoQueueAdvancing) return false;
    final state = p.processingState;
    return state != ProcessingState.loading &&
        state != ProcessingState.buffering &&
        state != ProcessingState.idle;
  }

  /// Whether the player itself is at the end of the last file, rather than
  /// only past the length the server indexed. An unknown duration is NOT an
  /// end: during buffering the engine cannot tell us where the last frame is,
  /// so keep playing until it reports a real end (GH: random auto-advance).
  bool _engineAtEnd() {
    final p = _player;
    if (p == null) return false;
    if (_trackStartOffsets.length > 1 &&
        _currentTrackIndex < _trackStartOffsets.length - 2)
      return false;
    final d = p.duration;
    if (d == null || d <= Duration.zero) return false;
    return p.position >= d - const Duration(seconds: 2);
  }

  Future<void> _onPlaybackComplete({bool userRequested = false}) async {
    // Last line of defence: a buffering/rebuilding engine is not at the end of
    // the book, whatever the position or the processing-state event said.
    if (!userRequested && !_endSignalIsTrustworthy) {
      debugPrint('[Complete] ignored - engine is buffering or rebuilding');
      return;
    }
    // Alpha: captures completion path choice for GH #186 (book restart bug).
    // Re-entry attempts are logged too so we can see if completion fires
    // multiple times from different signals (processingState, position-jump,
    // fallback) and races with auto-advance.
    debugPrint(
      '[Complete] entry: pos=${_lastKnownPositionSec.toStringAsFixed(1)}s totalDur=${_totalDuration.toStringAsFixed(1)}s item=$_currentItemId ep=$_currentEpisodeId reentry=$_isCompletingBook',
    );
    // A paused book must never finish or advance on its own. ExoPlayer can
    // still report the buffered track as completed after the user paused near
    // a chapter's end, and auto-advancing there looks like playback starting
    // by itself on the next chapter. A real end-of-book completion arrives
    // while still playing, so this only drops the spurious paused ones.
    if (!userRequested && !(_player?.playing ?? false)) {
      debugPrint('[Complete] ignored - not playing (paused or stopped)');
      return;
    }
    // A chapter list can be newer on the server than the queue this book was
    // started from (chapters added after it was queued or downloaded). Rather
    // than claim the book is finished at the old end, rebuild the queue from
    // the fresh chapters and carry on from here.
    if (!userRequested && _currentItemId != null && _api != null) {
      final freshId = _currentItemId!;
      try {
        final cachedChapters = await ChapterCache.read(freshId);
        if (cachedChapters != null &&
            cachedChapters.length > _chapters.length) {
          final item = await _api!.getLibraryItem(freshId);
          final media = item?['media'];
          final freshChapters = media is Map ? media['chapters'] : null;
          if (freshChapters is List && freshChapters.length > _chapters.length) {
            final metadata = (media as Map)['metadata'];
            final resumeAt = _lastKnownPositionSec;
            debugPrint(
              '[Complete] server has ${freshChapters.length} chapters, '
              'queue has ${_chapters.length} - re-queuing at '
              '${resumeAt.toStringAsFixed(1)}s',
            );
            await playItem(
              api: _api!,
              itemId: freshId,
              title: metadata is Map ? (metadata['title'] as String? ?? '') : '',
              author:
                  metadata is Map ? (metadata['authorName'] as String? ?? '') : '',
              coverUrl: _currentCoverUrl,
              totalDuration: (media['duration'] as num?)?.toDouble() ??
                  _totalDuration,
              chapters: freshChapters,
              startTime: resumeAt,
              forceStartTime: true,
              libraryId: _currentLibraryId,
              fromUi: true,
            );
            return;
          }
        }
      } catch (e) {
        debugPrint('[Complete] chapter refresh failed: $e');
      }
    }
    if (_isCompletingBook) return; // prevent re-entry
    _isCompletingBook = true;

    // ── iOS premature last-track completion guard (GH #219) ──
    // iOS ConcatenatingAudioSource sometimes fires ProcessingState.completed
    // when advancing to the final item without actually rendering its audio.
    // Symptoms: _currentTrackIndex just flipped to the last track, completion
    // fires within seconds (impossible to have played through a multi-minute
    // last track that fast). Spurious-completion check below can't catch this
    // because the position-getter math (trackRel + offset[last]) lands at
    // total duration. Recovery: seek a hair into the last track and resume,
    // which forces AVPlayer to reload that single item correctly.
    if (!userRequested && Platform.isIOS && _trackStartOffsets.length > 2) {
      final lastIdx = _trackStartOffsets.length - 2;
      final lastTrackStart = _trackStartOffsets[lastIdx];
      final lastTrackDur = _trackDurationAt(lastIdx);
      final advanceTime = _lastIndexAdvanceTime;
      final msSinceAdvance = advanceTime == null
          ? -1
          : DateTime.now().difference(advanceTime).inMilliseconds;
      if (_currentTrackIndex == lastIdx &&
          lastTrackDur > 5.0 &&
          msSinceAdvance >= 0 &&
          msSinceAdvance < 3000 &&
          _iosLastTrackRecoveryAttempts < _maxIosLastTrackRecoveries) {
        _iosLastTrackRecoveryAttempts++;
        final recoveryTarget = lastTrackStart + 0.5;
        debugPrint(
          '[Player] iOS premature last-track completion detected '
          '(idx=$_currentTrackIndex/$lastIdx, lastTrackDur=${lastTrackDur.toStringAsFixed(1)}s, '
          'advance=${msSinceAdvance}ms ago) — recovery attempt $_iosLastTrackRecoveryAttempts: '
          'seeking to ${recoveryTarget.toStringAsFixed(1)}s',
        );
        _logEvent(
          PlaybackEventType.pause,
          detail: 'iOS premature completion blocked',
        );
        _isCompletingBook = false;
        try {
          await _seekAbsolute(recoveryTarget);
          await _player?.play();
        } catch (e) {
          debugPrint('[Player] iOS last-track recovery failed: $e');
        }
        return;
      }
    }

    // Sanity check: if we're not near the end of the book, this is a spurious
    // completion signal (iOS AVPlayer can fire completed on audio interruptions,
    // buffer errors, etc.). Save current position and stop - don't mark finished
    // or advance the queue.
    //
    // Partial downloads get their own case: playback ended AT the download
    // boundary (the last downloaded file ran out, or the next/prev button sat
    // on the boundary). The bytes are done but the BOOK isn't, so this must
    // never reach the "finished" branch below — no isFinished, no
    // ReviewService, no auto-advance. Online, the completion hands straight
    // over to a streaming session (the boundary is the next chapter's start);
    // offline it parks on the boundary and the next-button continues by
    // streaming once the connection is back.
    final coverageEnd = _localCoverageEndSec;
    // Decide on whichever position is AHEAD: the live getter (fresh at the
    // engine's ENDED state — it composes the last file's end for a boundary
    // completion) or _lastKnownPositionSec. The cached value lags by a whole
    // position tick after a seek into the file end and is reset to 0 by every
    // source (re)load, so trusting it alone misreads the download boundary as
    // a mid-book completion — which parks nothing, leaves the position
    // resolving to the next (undownloaded) chapter, and on a fully stale/zero
    // value falls through to the book-finished branch that clears all state
    // (position drops to 0).
    final liveSec = position.inMilliseconds / 1000.0;
    final posAtEnd = _lastKnownPositionSec > liveSec
        ? _lastKnownPositionSec
        : liveSec;
    final atLocalBoundary =
        _isPartialLocalPlay &&
        coverageEnd != null &&
        posAtEnd >= coverageEnd - 2.0 &&
        posAtEnd <= coverageEnd + 60.0;
    if (!userRequested &&
        (atLocalBoundary ||
            (_totalDuration > 0 &&
                posAtEnd > 0 &&
                posAtEnd < _totalDuration * 0.9 &&
                posAtEnd < _totalDuration - 30))) {
      debugPrint(
        '[Player] ${atLocalBoundary ? 'Download boundary reached' : 'Spurious completion'} at ${posAtEnd.toStringAsFixed(1)}s / ${_totalDuration.toStringAsFixed(1)}s — saving position instead of marking finished',
      );
      _logEvent(
        PlaybackEventType.pause,
        detail: atLocalBoundary
            ? 'Download boundary reached'
            : 'Spurious completion blocked',
      );
      _syncSub?.cancel();
      _syncSub = null;
      _completionSub?.cancel();
      _completionSub = null;
      _bgSaveTimer?.cancel();
      _bgSaveTimer = null;
      // A download-queue play hit the end of its last downloaded file. stop()
      // resets the position so the next Play would replay from the start;
      // pause() parks the queue at its endpoint so a later Play continues
      // where the downloaded content stopped instead of jumping elsewhere.
      if (_localSessionMode) {
        await _player?.pause();
      } else {
        await _player?.stop();
      }
      if (atLocalBoundary) {
        // Persist the boundary itself (clamped to it), not a stale cached
        // position — a backward save here would throw away real progress.
        final boundarySave = posAtEnd > coverageEnd ? coverageEnd : posAtEnd;
        await _saveProgressLocal(
          Duration(milliseconds: (boundarySave * 1000).round()),
        );
        _lastKnownPositionSec = boundarySave;
      } else {
        await _saveProgressLocal(
          Duration(milliseconds: (_lastKnownPositionSec * 1000).round()),
        );
      }
      _isCompletingBook = false;
      // Parked at the end of the download: the boundary position is ALSO the
      // start of the next (non-downloaded) chapter, so keep reporting the last
      // downloaded chapter until the user seeks / plays / jumps on.
      if (atLocalBoundary) {
        // Online the download ended but the book continues: hand straight over
        // to a streaming session at the boundary instead of parking — reach
        // the boundary while online and the next chapter simply starts, no
        // dead pause. Start a hair past the boundary so the reopened stream
        // never lands exactly on a track-end seam (an end-for-end start could
        // instantly re-fire completion); offline (or a failed hand-off) falls
        // back to parking.
        if (await _streamContinueIfUncovered(coverageEnd + 0.3)) {
          return;
        }
        _setParkedAtBoundary(coverageEnd);
      }
      notifyListeners();
      return;
    }

    debugPrint('[Player] Book complete: $_currentTitle');
    _logEvent(PlaybackEventType.bookFinished);
    // Optional finish cue (chime / voice / vibration); off by default.
    // Queue modes continue to the next item through the provider rather than
    // pre-buffering, so ask whether an eligible next entry exists; treat that
    // as an auto-advance so the "remind during auto-advance" gate applies
    // instead of cueing every queued book.
    var cueAutoAdvance = false;
    if (_currentItemId != null) {
      final cueCurrentId = _currentEpisodeId != null
          ? '$_currentItemId-$_currentEpisodeId'
          : _currentItemId!;
      final willCb = _onWillAutoAdvanceCallback;
      if (willCb != null) {
        cueAutoAdvance = await willCb(cueCurrentId);
      } else {
        // Fallback: the pre-buffer peek only sees a directly playable next item.
        final peekCb = _onPeekNextItemCallback;
        if (peekCb != null) {
          cueAutoAdvance = await peekCb(cueCurrentId) != null;
        }
      }
    }
    unawaited(BookFinishReminder.instance.fire(onAutoAdvance: cueAutoAdvance));
    if (_currentEpisodeId == null) {
      unawaited(ReviewService.onBookFinished(isForeground: !_isBackgrounded));
    }

    // Cancel subscriptions first so we don't process stale events.
    _syncSub?.cancel();
    _syncSub = null;
    _completionSub?.cancel();
    _completionSub = null;
    _nativeAutoAdvanceSub?.cancel();
    _nativeAutoAdvanceSub = null;
    _bgSaveTimer?.cancel();
    _bgSaveTimer = null;
    // Android: stop() prevents ExoPlayer's phantom seek-to-0 on completion,
    // which would fire position-stream events that look like a restart.
    // iOS: stop() calls _setPlatformActive(false) which tears down the
    // AVPlayer entirely. The rebuilt AVPlayer for the next item is not
    // granted audio session privileges in background, so audio plays
    // silently and lock screen controls vanish. pause() preserves the
    // platform player + session — paired with darwinLoadControl's
    // automaticallyWaitsToMinimizeStalling=false this gives gapless
    // background auto-advance. GH #244.
    if (Platform.isAndroid) {
      await _player?.stop().timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('[Complete] player stop took over 5s - carrying on');
        },
      );
    } else {
      await _player?.pause();
    }

    // Mark as finished on the server (fire-and-forget to avoid blocking
    // auto-advance — the local save below is the source of truth).
    final itemId = _currentItemId;
    final episodeId = _currentEpisodeId;
    if (itemId != null && _api != null) {
      final api = _api!;
      final dur = _totalDuration;
      unawaited(() async {
        try {
          if (episodeId != null) {
            await api.updateEpisodeProgress(
              itemId,
              episodeId,
              currentTime: dur,
              duration: dur,
              isFinished: true,
            );
          } else {
            await api.markFinished(itemId, dur);
          }
          debugPrint('[Player] Marked as finished on server');
        } catch (e) {
          debugPrint('[Player] Failed to mark finished: $e');
        }
      }());
    }

    // Save locally as finished (fast, ensures offline correctness)
    if (itemId != null) {
      final progressKey = episodeId != null ? '$itemId-$episodeId' : itemId;
      await _progressSync.saveLocal(
        itemId: progressKey,
        currentTime: _totalDuration,
        duration: _totalDuration,
        speed: speed,
        isFinished: true,
      );
    }

    // Close the playback session (fire-and-forget)
    if (_playbackSessionId != null && _api != null) {
      final api = _api!;
      final sessionId = _playbackSessionId!;
      _logEvent(PlaybackEventType.sessionEnd, detail: 'book finished');
      unawaited(() async {
        try {
          debugPrint('[Player] Closing session (book finished)');
          await api.closePlaybackSession(sessionId);
        } catch (_) {}
      }());
    }

    // Local-session play: push the final accrued listening and finalize before
    // any auto-advance begins a new session (awaited to avoid racing it).
    if (_localSessionMode || _localSessionAccounting) {
      _logEvent(PlaybackEventType.sessionEnd, detail: 'local book finished');
      // Capped: a dozing phone on a slow tunnel left the book half finished
      // with the controls gone (GH #428).
      bool pushed = false;
      if (_api != null) {
        pushed = await LocalSessionService()
            .pushActive(api: _api!)
            .timeout(const Duration(seconds: 8), onTimeout: () => false);
      }
      await LocalSessionService()
          .finalizeActive(pushed: pushed)
          .timeout(const Duration(seconds: 8), onTimeout: () {});
    }

    // Notify LibraryProvider before clearing state so it can update isFinished locally.
    if (itemId != null) {
      final key = episodeId != null ? '$itemId-$episodeId' : itemId;
      if (_onBookFinishedCallback != null) {
        _onBookFinishedCallback!(key);
      } else {
        _pendingBookFinishedKey = key;
        debugPrint(
          '[Player] Book-finished callback not registered, buffering key=$key',
        );
      }
    }

    // Finish action: 'clear' dismisses the card (default); 'hold' parks on
    // the book with the card kept and play ignored; 'replay' keeps the card
    // and restarts from the beginning when play is pressed.
    final finishAction = await PlayerSettings.getBookFinishAction();
    if (finishAction == 'clear') {
      _clearState();
      _chapters = [];
      _handler?.updateChaptersQueue(const []);
    } else {
      _snapshotHeldFinish(finishAction);
      _clearState();
      _restoreHeldSnapshot();
      // _clearState reset the parked flag; re-arm it for hold / replay.
      _finishedHeld = true;
      _heldFinishAction = finishAction;
      _handler?.updateChaptersQueue(_chapters);
    }
    _isCompletingBook = false;
    notifyListeners();
  }

  /// Persist whether the user was actively playing when the app last left the
  /// foreground. Read back on cold-start / post-kill restore so a paused user
  /// isn't auto-resumed just because the OS rebuilt the process and MediaSession
  /// happened to still carry "playing".
  Future<void> _persistLastUserPlaying(bool playing) async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs ??= prefs;
      await prefs.setBool('last_user_was_playing', playing);
    } catch (_) {}
  }

  /// Position to persist for progress. A source swap or an in-flight seek can
  /// report 0 (or the pre-seek spot) for a moment; saving that overwrote the
  /// real position and the next play started from chapter 1. Prefer the seek
  /// target until the engine catches up, and never let a paused engine's
  /// backward glitch replace the last known position unless the user sought.
  Duration get _positionForProgressSave {
    final live = position;
    final liveSec = live.inMilliseconds / 1000.0;
    final target = activeSeekTarget;
    if (target != null && (liveSec - target).abs() > 5.0) {
      return Duration(milliseconds: (target * 1000).round());
    }
    if ((_player?.playing ?? false) == false &&
        !_seekedWhilePaused &&
        _lastKnownPositionSec > 0 &&
        liveSec < _lastKnownPositionSec - 2.0) {
      return Duration(milliseconds: (_lastKnownPositionSec * 1000).round());
    }
    return live;
  }

  Future<void> _saveProgressLocal(Duration pos) async {
    if (_currentItemId == null) return;
    if (_isCachedStartReconcilePending) return;
    final ct = pos.inMilliseconds / 1000.0;
    // Use compound key for podcast episodes
    final progressKey = _currentEpisodeId != null
        ? '$_currentItemId-$_currentEpisodeId'
        : _currentItemId!;
    // Incomplete download: the player pins beyond-file positions to the file's
    // end. Don't let that clamped value clobber a further-along saved position
    // (the user's real progress, recoverable once the full file streams or
    // re-downloads). GH #278. Only refuses a backward jump at the clamp point.
    if (_shortLocalDurationSec != null && ct >= _shortLocalDurationSec! - 2.0) {
      final saved = await _progressSync.getSavedPosition(progressKey);
      if (saved > ct + 1.0) {
        debugPrint(
          '[Player] Skipping save ${ct.toStringAsFixed(1)}s — would '
          'clobber further saved ${saved.toStringAsFixed(1)}s from incomplete '
          'download (GH #278)',
        );
        return;
      }
    }
    await _progressSync.saveLocal(
      itemId: progressKey,
      currentTime: ct,
      duration: _totalDuration,
      speed: speed,
    );
    // _logEvent(PlaybackEventType.syncLocal); // too noisy for history
  }

  DateTime _lastServerSync = DateTime.now();
  // Separate from the server-sync clock: drives the every-5s durable accrual so
  // a kill loses at most one tick of listening, independent of how often we POST.
  DateTime _lastAccrual = DateTime.now();
  double? _lastAccrualPos;
  bool _syncRecoveryInProgress = false;
  bool _positionSyncInProgress = false;
  int _positionSyncFailures = 0;
  DateTime? _noSessionSyncRetryAt;
  bool _recreatingSession = false;

  void _noteNoSessionSyncFailure(String what) {
    _positionSyncFailures++;
    if (_positionSyncFailures >= 3) {
      final waitSec = (60 << (_positionSyncFailures - 3)).clamp(60, 300);
      _noSessionSyncRetryAt = DateTime.now().add(Duration(seconds: waitSec));
      debugPrint(
        '[Player] No-session sync $what (failures=$_positionSyncFailures), '
        'backing off ${waitSec}s',
      );
    } else {
      debugPrint(
        '[Player] No-session sync $what (failures=$_positionSyncFailures)',
      );
    }
  }

  /// The active server address changed under a loaded book (local to remote
  /// or back). Sync, session pushes and the offline flush all go through
  /// [_api], which until now stayed on the address play started with - so
  /// after leaving WiFi every push went to a LAN address for as long as the
  /// book kept playing.
  void useApi(ApiService api) {
    final current = _api;
    if (current == null || identical(current, api)) return;
    if (current.cleanBaseUrl == api.cleanBaseUrl) return;
    debugPrint('[Player] Sync now goes to ${api.cleanBaseUrl}');
    _api = api;
  }

  /// Forget any sync backoff so the next tick pushes progress right away.
  /// Called when the network comes back or the active server changes.
  void resetServerSyncBackoff() {
    if (_positionSyncFailures == 0 && _noSessionSyncRetryAt == null) return;
    debugPrint(
      '[Player] Sync backoff cleared (failures=$_positionSyncFailures)',
    );
    _positionSyncFailures = 0;
    _noSessionSyncRetryAt = null;
  }

  int _playbackGeneration = 0;
  int? _cachedStartReconcileGeneration;

  /// True once a newer start has taken over from the one that was handed
  /// [generation]. Every start shares the current item, session and track
  /// state, so a start that lost has to back out without touching any of it:
  /// clearing it left the winner playing with no item (GH #391).
  bool _startSuperseded(int generation) => generation != _playbackGeneration;

  /// Backs a superseded start out: closes the server session it opened so
  /// the server is not left with a stray one, and reports nothing - the user
  /// is already listening to what they picked instead.
  String? _abandonStart(ApiService? api, String? ownSessionId, String where) {
    debugPrint('[Player] Start superseded ($where) - backing out');
    if (api != null && ownSessionId != null) {
      if (_playbackSessionId == ownSessionId) _playbackSessionId = null;
      unawaited(api.closePlaybackSession(ownSessionId));
    }
    return null;
  }

  bool get _isCachedStartReconcilePending =>
      _cachedStartReconcileGeneration == _playbackGeneration;

  /// Bank listening time to the durable store for the active play mode. Called
  /// every ~5s while playing (decoupled from the server POST) so the recorded
  /// total survives a kill. Uses wall-clock elapsed since the last accrual, so
  /// it stays correct at any speed and excludes paused spans (no ticks fire
  /// while paused; [play] restarts the clock).
  Future<void> _accrueListening(Duration absolutePos) async {
    if (_currentItemId == null) return;
    final now = DateTime.now();
    final delta = now.difference(_lastAccrual).inSeconds;
    if (delta <= 0) return;
    final ct = absolutePos.inMilliseconds / 1000.0;
    // A player can report playing while its position sits still - a stalled
    // stream, a dead web audio element. Wall clock alone would bank that span
    // as listening, and the 300s backstop timer keeps doing it for as long as
    // the app is open, so hours of standing still later ship as one phantom
    // session. Only credit a span the position actually moved through, and
    // drop the frozen span rather than carrying it into the next tick.
    final prevPos = _lastAccrualPos;
    _lastAccrualPos = ct;
    if (prevPos != null && (ct - prevPos).abs() < 0.5) {
      _lastAccrual = now;
      debugPrint(
        '[Player] Position frozen at ${ct.toStringAsFixed(1)}s - '
        'not banking ${delta}s as listening',
      );
      return;
    }
    final secs = delta > 300 ? 300 : delta;
    _lastAccrual = now;
    final key = _currentEpisodeId != null
        ? '$_currentItemId-$_currentEpisodeId'
        : _currentItemId!;
    final manualOffline = (_prefs?.getBool('manual_offline_mode')) ?? false;
    if (!_localSessionMode &&
        !_localSessionAccounting &&
        _playbackSessionId == null &&
        _sourceSessionless) {
      await _ensureStatsSessionForSessionlessSource();
    }
    if (_localSessionMode || _localSessionAccounting) {
      await LocalSessionService().accrue(
        progressKey: key,
        seconds: secs,
        currentTime: ct,
        api: null,
      );
    } else if (manualOffline || _isOfflineMode || _playbackSessionId == null) {
      await _progressSync.addOfflineListeningTime(key, secs);
    } else {
      await _progressSync.addStreamingPendingTime(key, secs);
    }
  }

  Future<void> _syncToServer(Duration pos, {int? timeListenedOverride}) async {
    final api = _api;
    final sessionId = _playbackSessionId;
    if (api == null || sessionId == null) return;
    final itemId = _currentItemId;
    final episodeId = _currentEpisodeId;
    final totalDuration = _totalDuration;
    if (_isCachedStartReconcilePending) return;
    final ct = pos.inMilliseconds / 1000.0;
    // Incomplete download: stuck at the truncated file's end. Don't push that
    // clamped position to the server (it would move real progress backward) or
    // report the stuck time as listened. GH #278.
    if (_shortLocalDurationSec != null && ct >= _shortLocalDurationSec! - 2.0) {
      return;
    }
    final now = DateTime.now();
    final elapsed =
        timeListenedOverride ??
        now.difference(_lastServerSync).inSeconds.clamp(0, 300);
    _lastServerSync = now;
    // The streaming safety buffer mirrors this same span; read it before the
    // POST so we only clear what the server is about to confirm. A real
    // timeListened (not an override) is what the buffer is shadowing.
    final streamKey = (timeListenedOverride == null && itemId != null)
        ? (episodeId != null ? '$itemId-$episodeId' : itemId)
        : null;
    final pendingBefore = streamKey != null
        ? await _progressSync.getStreamingPendingTime(streamKey)
        : 0;
    if (elapsed > 0) {
      unawaited(
        _progressSync.addTimeSaved(elapsed.toInt(), _player?.speed ?? 1.0),
      );
    }
    // Alpha: volume/sessionId piggybacked for GH #179 (volume falls off).
    // We sample these on each sync tick so drift over time is visible.
    final vol = _player?.volume;
    final eqSid = _player?.androidAudioSessionId;
    debugPrint(
      '[Player] Sync session ${sessionId.substring(0, 8)}... | currentTime=${ct.toStringAsFixed(1)}s, timeListened=${elapsed}s, volume=$vol, eqSession=$eqSid',
    );
    final status = await api.syncPlaybackSessionStatus(
      sessionId,
      currentTime: ct,
      duration: totalDuration,
      timeListened: elapsed,
    );
    // A new start may have replaced the session while the POST was in flight;
    // its result belongs to the old session and must not trigger recovery on
    // the new one.
    if (_playbackSessionId != sessionId) {
      debugPrint('[Player] Ignoring session sync result for a replaced session');
      return;
    }
    final ok = status == 200;
    if (ok && elapsed > 0) {
      // Tick the StatsWidget forward locally so "today" stays fresh between
      // 15-min authoritative refreshes (which Android Doze throttles).
      unawaited(HomeWidgetService().addLocalListeningSeconds(elapsed));
    }
    if (ok && streamKey != null && pendingBefore > 0) {
      unawaited(
        _progressSync.reduceStreamingPendingTime(streamKey, pendingBefore),
      );
    }
    if (ok) {
      _logEvent(PlaybackEventType.syncServer, detail: '+${elapsed}s');
    }
    if (!ok && !_syncRecoveryInProgress) {
      // Starting a new session makes the server close this one, and the
      // live source may stream through it. A failure that isn't "session
      // gone" is network trouble: keep the session, push progress through
      // the progress endpoint, and try the session again next tick.
      final sessionGone = status == 404;
      if (!sessionGone && _sourceSessionId == _playbackSessionId) {
        debugPrint(
          '[Player] Session sync failed (status=$status) - keeping the session the stream runs on, syncing progress directly',
        );
        await _syncProgressWithoutSession(pos);
        return;
      }
      debugPrint('[Player] Session sync failed - attempting recovery');
      _syncRecoveryInProgress = true;
      try {
        await _recoverSession(ct, elapsed);
        // A gone session was the one the stream ran on: the source is dead
        // already, and moving it now costs a short gap instead of the five
        // seconds of silence when the cache runs out and the retry kicks in.
        if (_sourceSessionDead) {
          final playing = _player?.playing ?? false;
          if (!await _applyPendingLocalSwap(resumeAfter: playing)) {
            await _applyPendingSessionUpgrade(resumeAfter: playing);
          }
        }
      } finally {
        _syncRecoveryInProgress = false;
      }
    }
  }

  /// Try to start a new server session when the current one becomes invalid.
  Future<void> _recoverSession(double currentTime, int lostTimeListened) async {
    if (_api == null || _currentItemId == null || _isLoadingNewItem) return;
    final api = _api!;
    final sessionItemId = _currentItemId!;
    final sessionEpisodeId = _currentEpisodeId;
    // A session-less stream gets its replacement from the presence-only /play
    // head; never pay for the full track list here.
    if (_sourceSessionless) {
      await _ensureStatsSessionForSessionlessSource();
      if (_currentItemId == sessionItemId &&
          _currentEpisodeId == sessionEpisodeId &&
          _playbackSessionId != null) {
        debugPrint('[Player] Recovered session: $_playbackSessionId');
        _logEvent(PlaybackEventType.sessionStart, detail: 'recovery');
        if (lostTimeListened > 0) {
          await api.syncPlaybackSession(
            _playbackSessionId!,
            currentTime: currentTime,
            duration: _totalDuration,
            timeListened: lostTimeListened,
          );
        }
      }
      return;
    }
    try {
      final sessionData = await _sharedSessionStart(
        api,
        sessionItemId,
        sessionEpisodeId,
      );
      if (_currentItemId != sessionItemId ||
          _currentEpisodeId != sessionEpisodeId) {
        final staleId = sessionData?['id'] as String?;
        if (staleId != null) {
          unawaited(api.closePlaybackSession(staleId));
        }
        return;
      }
      if (sessionData != null) {
        _playbackSessionId = sessionData['id'] as String?;
        debugPrint('[Player] Recovered session: $_playbackSessionId');
        _logEvent(PlaybackEventType.sessionStart, detail: 'recovery');
        _stashSessionUpgrade(sessionData);
        // Re-sync the lost time to the new session
        if (_playbackSessionId != null && lostTimeListened > 0) {
          await api.syncPlaybackSession(
            _playbackSessionId!,
            currentTime: currentTime,
            duration: _totalDuration,
            timeListened: lostTimeListened,
          );
        }
      } else {
        debugPrint('[Player] Session recovery failed - no session returned');
        _playbackSessionId = null;
      }
    } catch (e) {
      debugPrint('[Player] Session recovery error: $e');
    }
  }

  DateTime? _lastPauseTime;
  bool _seekedWhilePaused = false;
  // Origin of the playItem in flight, read by the play paths to decide
  // whether to wait on the server's saved position. See playItem().
  bool _playFromUi = false;
  bool _wasPlayingBeforeInterrupt = false;
  bool _pauseRequested = false;
  bool get isPauseRequested => _pauseRequested;

  void _markPauseRequested() {
    _pauseRequested = true;
  }

  // Storm guard for the idle-on-resume re-init path. A book the player can't
  // start (e.g. a thousands-of-files book the engine never leaves `idle` on)
  // would otherwise re-init in a tight loop, opening a new server play session
  // each pass. Cap re-inits within a short window.
  int _idleReinitCount = 0;
  DateTime? _lastIdleReinit;
  static const _idleReinitWindow = Duration(seconds: 10);
  static const _idleReinitMaxAttempts = 3;

  /// Auto-rewind calculation using linear scaling.
  /// Scales linearly from minRewind at activationDelay to maxRewind at 1 hour.
  /// activationDelay = minimum pause before rewind kicks in (0 = always).
  static double calculateAutoRewind(
    Duration pauseDuration,
    double minRewind,
    double maxRewind, {
    double activationDelay = 0,
  }) {
    final pauseSeconds = pauseDuration.inSeconds.toDouble();

    // Don't rewind if pause is shorter than activation delay
    if (pauseSeconds < activationDelay) return 0;

    // Linear from min to max over 1 hour of pause time
    const maxPause = 3600.0; // 1 hour = full rewind
    final effectivePause = (pauseSeconds - activationDelay).clamp(
      0.0,
      maxPause,
    );
    final t = effectivePause / maxPause;
    final rewind = minRewind + (maxRewind - minRewind) * t;
    return rewind.clamp(minRewind, maxRewind);
  }

  /// [fromUi] marks a play started from the app's own screen. App-screen
  /// resumes wait up to [_serverPositionCheckCap] for a server position
  /// another device may have advanced; headphone, notification, widget, lock
  /// screen and Android Auto resumes only do so after a pause long enough
  /// for that to be likely ([_localPositionStaleAfter]), so a quick re-press
  /// starts right away and a stale one no longer clobbers newer server
  /// progress (GH #430).
  Future<void> play({String? logDetail, bool fromUi = false}) async {
    _api?.cancelBackgroundItemTransfers();
    _pauseRequested = false;
    // The notification/headset is showing the first remaining book after a
    // removal. A play press is an explicit request to start that book, even
    // though the old player has no current item.
    if (!_isLoadingNewItem &&
        _currentItemId == null &&
        _idleNotificationTarget != null) {
      await _playIdleNotificationTarget();
      return;
    }
    // Parked on a finished book: both hold and replay reload on play — hold
    // restarts the last chapter/episode, replay restarts from the beginning.
    // Never fall through to resuming a stopped, completed source.
    if (_finishedHeld) {
      await _restartHeldParked();
      notifyListeners();
      return;
    }
    // A start is already loading (including a long-pause rebuild or a
    // load-only preload). Starting another one would race the source swap and
    // could restart from the saved position/0; let the in-flight start decide
    // and replay at its end when it lands paused.
    if (_isLoadingNewItem) {
      debugPrint(
        '[Service] play() — a start is still loading; will play when it lands',
      );
      _playRequestedDuringLoad = true;
      return;
    }
    // A second Play while the first is still moving the source onto a live
    // session raced it: it pressed play on a half-loaded player and ExoPlayer
    // failed with "Unexpected runtime error" (GH #344). The first one plays
    // when it's ready, so let it.
    final since = _playInFlightSince;
    if (since != null && DateTime.now().difference(since) < _playInFlightCap) {
      debugPrint(
        '[Service] play() ignored - the play from '
        '${DateTime.now().difference(since).inMilliseconds}ms ago is still getting ready',
      );
      return;
    }
    _playInFlightSince = DateTime.now();
    _playStartAt = DateTime.now();
    // Publish the in-flight start: [isStartInFlight] feeds the UI's loading
    // state, so the tap shows a spinner from this instant instead of waiting
    // for the first engine event (which a session rebuild delays by seconds).
    PlaybackQuietGate.beginStart();
    // Same as playItem: an offline-listening flush already on the wire has to
    // drop off (ledger kept) so its large `/play` body can't starve the resume.
    _progressSync.abortInFlightFlushForPlaybackStart();
    notifyListeners();
    try {
      await _playNow(logDetail: logDetail, fromUi: fromUi);
    } finally {
      PlaybackQuietGate.endStart();
      _playInFlightSince = null;
      notifyListeners();
    }
  }

  DateTime? _playInFlightSince;
  static const _playInFlightCap = Duration(seconds: 30);

  Future<void> _playNow({String? logDetail, bool fromUi = false}) async {
    // Offline + a source that isn't downloaded: resuming would re-engage the
    // stream (fresh session, fresh buffers) that offline mode exists to stop.
    // Stay paused until the connection is back, which resumes via
    // _onOfflineStateChanged.
    if (_offlineRemoteStream) {
      final posSec = _sourceSwapTarget(
        null,
        resumeAfter: _player?.playing ?? false,
      );
      // The current position may sit inside a DOWNLOADED chapter of the book
      // (user paused a stream, went offline, pressed play): re-enter LOCAL
      // playback there - real audio, no network - and resume it directly. The
      // full play tail's server-adopt seek and resume auto-rewind don't belong
      // to an offline re-root.
      if (await _reenterLocalPlayIfCovered(posSec)) {
        _pausedForOffline = false;
        _lastPauseTime = null;
        _lastServerSync = DateTime.now();
        _lastAccrual = DateTime.now();
        _lastAccrualPos = null;
        _seekedWhilePaused = false;
        if (_player != null && !_player!.playing) {
          await _player!.play();
        }
        notifyListeners();
        return;
      }
      debugPrint(
        '[Service] play() blocked — offline, current item is a stream and '
        '${posSec.toStringAsFixed(1)}s has no downloaded audio; staying '
        'paused until reconnect',
      );
      // Silence here reads as a dead button: say why, and point at the one
      // action that fixes it (the cloud turns orange while offline and its tap
      // reconnects). Only from the app's own screens - a headset/car press
      // must not throw UI up during background playback.
      if (fromUi) {
        final l = _l10n();
        showNavigatorOverlayToast(
          rootNavigatorKey.currentState,
          l?.playerErrorNotDownloadedOffline ??
              'This item isn\'t downloaded and offline mode is on',
          icon: Icons.cloud_off_outlined,
        );
      }
      return;
    }
    // The boundary completion path cancels the position/completion listeners;
    // if no listener was alive when the engine hit the end of the download,
    // that completion went unhandled: the engine sits ENDED at the boundary
    // with no parked state, so the title resolves to the next (undownloaded)
    // chapter and a bare play() would resume a dead end position. Adopt the
    // same parked bookkeeping first so the restart below picks the last
    // downloaded chapter and this play gets real audio.
    if (!_parkedAtBoundary &&
        _isPartialLocalPlay &&
        _currentItemId != null &&
        _player?.processingState == ProcessingState.completed) {
      debugPrint(
        '[Service] play() — engine ended at the download boundary unhandled; parking first',
      );
      await _onPlaybackComplete();
    }
    // Parked at the end of a partial download (natural completion or a forward
    // skip that hit the boundary): restart from the last downloaded chapter's
    // START rather than resuming the parked boundary position, which sits on
    // the next chapter's start spot with no audio behind it.
    if (_parkedAtBoundary) {
      final resumeIdx = _parkedBoundaryChapterIdx;
      _parkedAtBoundary = false;
      _parkedBoundaryChapterIdx = null;
      if (resumeIdx != null &&
          resumeIdx >= 0 &&
          resumeIdx < _chapters.length &&
          _player != null) {
        var restartStart = ChapterLookup.metaStart(_chapters, resumeIdx);
        // Belt and braces: a restart target with no audio behind it (drift put
        // the parked chapter's start ON the boundary) would seek to the file's
        // end, instantly complete and park the very state we just cleared.
        // Start at the last downloaded file's own beginning instead.
        final cEnd = _localCoverageEndSec;
        if (cEnd != null &&
            restartStart >= cEnd - 0.5 &&
            _trackStartOffsets.length > 1) {
          restartStart = _trackStartOffsets[_trackStartOffsets.length - 2];
        }
        debugPrint(
          '[Service] play() at download boundary — restarting from chapter '
          '$resumeIdx (${restartStart.toStringAsFixed(1)}s)',
        );
        _logEvent(
          PlaybackEventType.seek,
          detail: 'restart at download boundary from chapter ${resumeIdx + 1}',
        );
        // Resetting pause bookkeeping here keeps the play tail's resume
        // auto-rewind from pulling the fresh restart back into a gap.
        _lastPauseTime = null;
        _seekedWhilePaused = false;
        await _seekAbsolute(
          restartStart,
          chapterJump: true,
          pinChapterIndex: resumeIdx,
        );
        _seekedWhilePaused = false;
      }
    }
    debugPrint(
      '[Service] play() called — lastPause=${_lastPauseTime != null} fromUi=$fromUi',
    );

    // Cold-start play guard. If the OS killed absorb during a long pause
    // and the user tapped play via headphones / lock screen / Android Auto,
    // the handler routes play() into this service before any UI code has
    // had a chance to restore the last-played item. _currentItemId is null
    // here, so falling through to _player.play() fires on an empty player
    // and nothing happens. Route through the cold-start callback instead.
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs ??= prefs;
    final decision = ColdStartPlayPolicy.decide(
      currentItemId: _currentItemId,
      lastPlayedItemId: prefs.getString('widget_item_id'),
    );
    if (decision == ColdStartPlayDecision.restoreLastPlayed) {
      // Phantom-resume guard: if the user was paused when the app was last
      // alive, don't auto-restore just because the OS sent a stale play
      // command after rebuilding the process (MediaSession still carried
      // "playing" when they actually paused).
      final userWasPlaying = prefs.getBool('last_user_was_playing') ?? true;
      if (!userWasPlaying) {
        debugPrint(
          '[Service] play() cold-start but last_user_was_playing=false - ignoring phantom resume',
        );
        return;
      }
      debugPrint(
        '[Service] play() on cold-started service - routing to cold-start restore',
      );
      // Android can start the process from the media resume card and send
      // play while the app is still starting up, before main() has wired the
      // restore handler. Wait for it rather than dropping the press.
      var restore = AudioPlayerService.onColdStartPlayRequested;
      for (var i = 0; restore == null && i < 50; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        restore = AudioPlayerService.onColdStartPlayRequested;
      }
      if (restore != null) {
        unawaited(restore());
      } else {
        debugPrint(
          '[Service] No cold-start restore handler registered after 10s - ignoring play',
        );
      }
      return;
    }
    if (decision == ColdStartPlayDecision.nothing) {
      debugPrint(
        '[Service] play() called with no current item and no history - ignoring',
      );
      return;
    }

    _pauseStopTimer?.cancel();
    _pauseStopTimer = null;
    // Playing again settles any interruption still waiting to resume; a stale
    // flag would bring the book back after some later, unrelated focus gain.
    _wasPlayingBeforeInterrupt = false;
    _noisyPause =
        false; // User explicitly resumed — allow interrupt-resume again
    _handler?._noisyPauseAt = null; // Clear noisy suppression window
    // A loadOnly playItem left the item paused with no session; this first
    // real play is where listening actually starts, so the session does too.
    final pendingSession = _pendingLoadOnlySession;
    if (pendingSession != null) {
      _pendingLoadOnlySession = null;
      if (_currentItemId == pendingSession.itemId) {
        await LocalSessionService().beginSession(
          progressKey: pendingSession.progressKey,
          libraryItemId: pendingSession.itemId,
          episodeId: pendingSession.episodeId,
          mediaType: pendingSession.episodeId != null ? 'podcast' : 'book',
          duration: pendingSession.duration,
          startTime: position.inMilliseconds / 1000.0,
          displayTitle: pendingSession.title,
          displayAuthor: pendingSession.author,
          streamed: pendingSession.streamed,
        );
        // The loadOnly playItem returned before _setupSync, so this session
        // has no completion listener, no position sync, no EQ attach and no
        // stats accrual yet. Without it a hot-loaded book that plays to the
        // end just sits there: completed arrives, nobody reacts, the card
        // stays until a manual stop and the book is never marked finished.
        _setupSync();
      }
    }
    // BookOrbit audio streams through the in-app proxy, which a long
    // suspension can take down; a lock screen play doesn't foreground the app.
    if (_api?.isBookOrbit == true) await _api!.ensureMediaReady();

    // Play paths that don't go through playItem (plain resume, restart from
    // the download boundary) must still have the position/completion
    // listeners alive: the boundary completion cancels them while parked, and
    // without re-attaching here the NEXT boundary end is never handled — the
    // engine stays ENDED with playWhenReady=true and the card keeps reading
    // "playing" forever, with nothing saving or parking anything.
    if (_currentItemId != null &&
        (_syncSub == null || _completionSub == null)) {
      debugPrint('[Service] play() — re-attaching sync/completion listeners');
      _setupSync();
    }
    // A source streaming through a session the server no longer has (closed
    // by the pause timeout, or replaced since) would play from the cache
    // until that runs out, then die with a 404 and a five-second retry.
    // Nothing is audible yet, so this is the moment to move it.
    //
    // That move is a /play round trip, and its own budget is 20s per attempt
    // with a 40s total deadline. On a link that never answers (the usual case
    // after a long background: the radio is just back up, the server is still
    // unreachable, the cloud is orange) this used to hold play() - and every
    // tap behind it - for the whole 40s with only network traffic to show for
    // it. That is the "pressed play, nothing happened, data is running" report.
    // Cap the wait: the handful of seconds a healthy server needs. Past that
    // the start fails out loud (toast + the cloud the user can tap) and the
    // still-running rebuild is left as a warm-up, so the next press starts
    // straight from the source it lands.
    if (_sourceSessionDead) {
      // Cheapest fix first: a book with a start manifest can rebuild its
      // source from file ids alone, so the resume never waits on /play at all.
      // Only taken when no session is already stashed for this source - an
      // upgrade stashed by the foreground prewarm is a local swap and keeps
      // the listening-session accounting intact.
      final stashed = _pendingSessionUpgrade?['id'];
      if ((stashed == null || stashed != _playbackSessionId) &&
          await _restartFromManifestIfPossible(fromUi: fromUi)) {
        return;
      }
      final rebuildSw = Stopwatch()..start();
      var rebuildTimedOut = false;
      try {
        await _rebuildSourceOnDeadSession(
          resumeAfter: false,
        ).timeout(_deadSessionRebuildCap);
      } on TimeoutException {
        rebuildTimedOut = true;
        debugPrint(
          '[Service] play() — session rebuild still running after '
          '${_deadSessionRebuildCap.inSeconds}s; not holding the start on it. '
          'The rebuild continues in the background as a warm-up.',
        );
      } catch (e) {
        debugPrint('[Service] play() — session rebuild failed: $e');
      }
      debugPrint(
        '[Service] play() — session rebuild '
        '${rebuildTimedOut ? 'deferred' : 'finished'} in '
        '${rebuildSw.elapsedMilliseconds}ms',
      );
      if (_pauseRequested) {
        debugPrint(
          '[Service] Paused while the source was being rebuilt - not starting',
        );
        return;
      }
      if (rebuildTimedOut) {
        // Say why nothing started instead of leaving the button looking dead.
        // The item stays loaded and the background rebuild keeps going, so a
        // later press (or the reconnect the cloud offers) resumes instantly.
        // App screens only: a headset/car press must not raise UI over
        // whatever the user is looking at.
        if (fromUi) {
          final l = _l10n();
          showNavigatorOverlayToast(
            rootNavigatorKey.currentState,
            l?.playerErrorConnect ??
                'Couldn\'t reach the server. Check your connection and try again.',
            icon: Icons.cloud_off_outlined,
          );
        }
        notifyListeners();
        return;
      }
      // A rebuild that finished (fast, no timeout) yet left the source on the
      // dead session would start playback on URLs the server already closed:
      // the buffer plays out, then 404s - the silent dead button again, one
      // step later. Fail the start out loud instead. Skipped while another
      // rebuild is still in flight (the foreground prewarm, or the attempt
      // this press timed out on): that one owns the fix, and its swap
      // resumes a playing engine on its own - toasting "no server" over a
      // healthy warm-up would be wrong twice.
      if (_sourceSessionDead &&
          !_recreatingSession &&
          !ChromecastService().isCasting &&
          !_offline) {
        debugPrint(
          '[Service] play() — rebuild left the source on a closed session; '
          'not starting into it',
        );
        if (fromUi) {
          final l = _l10n();
          showNavigatorOverlayToast(
            rootNavigatorKey.currentState,
            l?.playerErrorConnect ??
                'Couldn\'t reach the server. Check your connection and try again.',
            icon: Icons.cloud_off_outlined,
          );
        }
        notifyListeners();
        return;
      }
    }
    // Android: a player left paused past the pause timeout comes back with
    // the position moving and nothing audible, and only a rebuilt player
    // sounds again. One whose decoder failed while paused is rebuilt too.
    // Decided before any seek: seeking a player that is about to be replaced
    // is wasted, and on a failed decoder the seek can wait forever.
    final pausedFor = _lastPauseTime == null
        ? null
        : DateTime.now().difference(_lastPauseTime!);
    final longPause = pausedFor != null && pausedFor >= _pauseStopTimeout;
    // A failed decoder can leave the player idle; it is rebuilt all the same.
    bool canRebuild() =>
        (_playerBroken || _player?.processingState != ProcessingState.idle) &&
        _currentItemId != null &&
        _api != null;
    String? rebuildWhy = _playerBroken
        ? 'Player failed while paused'
        : Platform.isAndroid && longPause
        ? 'Long pause (${pausedFor.inSeconds}s)'
        : null;
    var rebuild = rebuildWhy != null && canRebuild();
    // Where the resume lands: the live player follows it when it is kept,
    // the rebuild starts there otherwise.
    final enginePosSec =
        (_player?.position.inMilliseconds ?? 0) / 1000.0;
    var resumeAt = position.inMilliseconds / 1000.0;
    debugPrint(
      '[PlayTrace] resume base=${resumeAt.toStringAsFixed(1)}s '
      'engineLocal=${enginePosSec.toStringAsFixed(1)}s '
      'track=$_currentTrackIndex/${_trackStartOffsets.length - 1} '
      'pausedAt=${_pausedAtS?.toStringAsFixed(1) ?? '-'} '
      'anchor=${_resumeAnchorS?.toStringAsFixed(1) ?? '-'} '
      'pending=${_pendingStartSec.toStringAsFixed(1)} '
      'loading=$_isLoadingNewItem seekedWhilePaused=$_seekedWhilePaused',
    );
    // A source/session swap while paused can leave the engine reporting the
    // new file's start instead of the spot the listener paused on. Nothing
    // moves the position while paused except an explicit seek, so a large
    // backward step here is a broken reading, not a resume point.
    final pauseAnchor = _resumeAnchorS;
    var resumeCorrected = false;
    if (!_seekedWhilePaused &&
        pauseAnchor != null &&
        resumeAt < pauseAnchor - 2.0) {
      debugPrint(
        '[Player] Resume position ${resumeAt.toStringAsFixed(1)}s is behind '
        'the pause spot ${pauseAnchor.toStringAsFixed(1)}s - using the pause '
        'spot',
      );
      resumeAt = pauseAnchor;
      resumeCorrected = true;
    }
    var resumeMoved = false;
    Future<void> moveTo(double s, [Future<void> Function()? seek]) async {
      resumeAt = s;
      resumeMoved = true;
      if (rebuild) return;
      if (!await _resumeSeekFinished(seek ?? () => _seekAbsolute(s), s)) {
        rebuildWhy = 'Seek on resume never finished';
        rebuild = canRebuild();
      }
    }

    // A seek while paused (user, or the socket adopting another device's
    // position) is the position the user expects to hear next - don't let
    // the server check below override it.
    final seekedWhilePaused = _seekedWhilePaused;
    _seekedWhilePaused = false;
    // A tap on Play must never wait for a network round trip. After a long
    // background pause the server progress check (and the library catch-up
    // running alongside it) used to hold play() until the fetch returned, so
    // the button looked dead. Pressing Play means "resume here, now" - keep
    // the phone's own position. Headphone / car / widget / lock-screen starts
    // still reconcile with the server as before.
    final serverPos = !seekedWhilePaused && !fromUi
        ? await _serverPositionBeforeResume(fromUi: fromUi)
        : null;
    final adoptedServerPos = serverPos != null;
    if (serverPos != null) {
      await moveTo(serverPos);
      _logEvent(
        PlaybackEventType.seek,
        detail:
            'adopted server position ${serverPos.toStringAsFixed(1)}s before resume',
      );
    }
    // Coming back within a few minutes of the sleep timer firing means you were
    // awake for it, so put back what its rewind took. Done before the ordinary
    // auto-rewind below so that still applies from the restored position.
    // Moot when we just jumped to another device's position; consume the undo
    // anyway so it can't fire on a later resume.
    if (_player != null) {
      final undoTo = SleepTimerService().takeSleepRewindUndo(
        _currentItemId,
        position,
      );
      if (undoTo != null && !adoptedServerPos) {
        await moveTo(
          undoTo.inMilliseconds / 1000.0,
          () => seekTo(undoTo, logDetail: 'sleep rewind undone'),
        );
        // seekTo flags a paused seek; this one is ours, not the user's, and
        // the server check has already run, so don't carry it to next resume.
        _seekedWhilePaused = false;
      }
    }
    // Auto-rewind on resume if enabled. Skip it after a seek made while paused
    // (chapter jump, bookmark, device adoption): the user has just explicitly
    // placed the position, so pulling it back re-presents the tail of the
    // PREVIOUS chapter (a jump to chapter N's start rewinds into N-1) and
    // contradicts the position they expect to hear next. Check the live flag
    // too: a seek issued during the awaits above is just as deliberate.
    if (!seekedWhilePaused &&
        !_seekedWhilePaused &&
        _lastPauseTime != null &&
        _player != null) {
      final settings = await AutoRewindSettings.load();
      if (settings.enabled) {
        final pauseDuration = DateTime.now().difference(_lastPauseTime!);
        final rewindSeconds = calculateAutoRewind(
          pauseDuration,
          settings.minRewind,
          settings.maxRewind,
          activationDelay: settings.activationDelay,
        );
        // A player sitting at zero has lost its place (an error reset it);
        // rewinding from there would only seek to the start on top of
        // whatever the server check just restored.
        if (rewindSeconds > 0.5 && resumeAt > 0) {
          final currentAbsolutePos = resumeAt;
          final currentSpeed = _player!.speed;
          var newPosSeconds =
              currentAbsolutePos - (rewindSeconds * currentSpeed);
          if (newPosSeconds < 0) newPosSeconds = 0;
          // Chapter barrier: don't rewind past the current chapter start.
          // A rewind must also not drop an already-skipped intro back into
          // earshot: the seek's own target briefly suppresses the live skip
          // watcher, so the opening words would play before it caught up.
          if (_chapters.isNotEmpty) {
            var introSkip = 0.0;
            try {
              final skip =
                  await ChapterSkipSettings.loadForItem(_mediaItemKey);
              if (skip.enabled && skip.introSkipSeconds > 0) {
                introSkip = skip.introSkipSeconds.toDouble();
              }
            } catch (_) {}
            for (final ch in _chapters) {
              final start = (ch['start'] as num?)?.toDouble() ?? 0;
              final end = (ch['end'] as num?)?.toDouble() ?? 0;
              if (currentAbsolutePos >= start && currentAbsolutePos < end) {
                if (settings.chapterBarrier && newPosSeconds < start) {
                  newPosSeconds = start;
                }
                final introTarget = start + introSkip;
                if (introSkip > 0 &&
                    currentAbsolutePos >= introTarget &&
                    newPosSeconds >= start &&
                    newPosSeconds < introTarget &&
                    end - introTarget >= 1.0) {
                  newPosSeconds = introTarget;
                }
                break;
              }
            }
          }
          // A rewind is a nicety, a stall is not. A seek the engine can only
          // serve from the network waits for bytes, and a resume seek that
          // misses its cap marks the player broken and rebuilds the whole
          // source - seconds of silence for one second of audio. Only rewind
          // when the engine is ready and already holds audio ahead of the
          // playhead, so the move is served from the buffer.
          final engine = _player!;
          final hasRunway = engine.processingState == ProcessingState.ready &&
              engine.bufferedPosition > engine.position;
          if (!hasRunway) {
            debugPrint(
              '[Player] Auto-rewind skipped '
              '(${rewindSeconds.toStringAsFixed(1)}s) - '
              '${engine.processingState} with no audio buffered ahead',
            );
          } else {
            await moveTo(newPosSeconds);
            // Log the actual book-time delta: at speed>1.0 it's larger than
            // rewindSeconds, and the chapter barrier may cap it smaller.
            final actualDelta = currentAbsolutePos - newPosSeconds;
            final rewindDetail = currentSpeed == 1.0
                ? '${rewindSeconds.toStringAsFixed(1)}s'
                : '${rewindSeconds.toStringAsFixed(1)}s (${actualDelta.toStringAsFixed(1)}s at ${currentSpeed.toStringAsFixed(2)}x)';
            _logEvent(PlaybackEventType.autoRewind, detail: rewindDetail);
            debugPrint(
              '[Player] Auto-rewind ${rewindSeconds.toStringAsFixed(1)}s '
              '(paused ${pauseDuration.inSeconds}s)',
            );
          }
        }
      }
    }
    // The guard above corrected a broken reading but nothing has moved the
    // engine to it yet (auto-rewind disabled or skipped for lack of runway).
    // Seek now; otherwise playback would start from the wrong file position.
    if (resumeCorrected && !resumeMoved && !rebuild && _player != null) {
      debugPrint(
        '[Player] Applying the corrected resume position '
        '${resumeAt.toStringAsFixed(1)}s',
      );
      await moveTo(resumeAt);
    }
    // Pause pressed while the resume was checking/adopting must not be
    // overridden by the start below (the pause handler already positioned the
    // player there).
    if (_pauseRequested) {
      debugPrint('[Service] Pause requested while resuming — staying paused');
      return;
    }
    _lastPauseTime = null;
    // Reset server sync clock so the first sync after resume doesn't
    // include pause duration as timeListened
    _lastServerSync = DateTime.now();
    _lastAccrual = DateTime.now();
    _lastAccrualPos = null;
    // Re-activate audio session in case a prior stop released it. The answer
    // is the audio focus request: a refusal here on a resume from the
    // background is a lead when the book then plays without sound.
    try {
      final activated = await (await AudioSession.instance).setActive(true);
      debugPrint(
        '[Player] Resume setActive(true)=$activated '
        '(paused ${pausedFor?.inSeconds ?? '?'}s)',
      );
    } catch (e) {
      debugPrint('[Player] Resume setActive(true) failed: $e');
    }
    // Rebuild at the position the resume settled on, which already includes
    // the auto rewind, so nothing seeks once audio starts.
    if ((rebuild || _playerBroken) && canRebuild()) {
      final why = rebuildWhy ?? 'Player failed while paused';
      _playerBroken = false;
      // A position of zero means the player lost its place; the start then
      // comes from the saved progress instead of being forced to the top.
      // A seek made while paused after resumeAt was captured (scrub, chapter
      // jump) is newer than that snapshot: rebuild at the live position so
      // the rebuild doesn't undo it.
      final pausedSeekAfterCapture = _seekedWhilePaused;
      final startS = pausedSeekAfterCapture
          ? position.inMilliseconds / 1000.0
          : resumeAt;
      debugPrint(
        '[Player] $why - rebuilding the player '
        '${startS > 0 ? "at ${startS.toStringAsFixed(1)}s" : "from the saved position"} '
        'instead of resuming it',
      );
      _logEvent(PlaybackEventType.play, detail: '$logDetail (rebuilt: $why)');
      unawaited(
        playItem(
          api: _api!,
          itemId: _currentItemId!,
          title: _currentTitle ?? '',
          author: _currentAuthor ?? '',
          coverUrl: _currentCoverUrl,
          totalDuration: _totalDuration,
          chapters: _chapters,
          startTime: startS,
          forceStartTime: pausedSeekAfterCapture || startS > 0,
          episodeId: _currentEpisodeId,
          episodeTitle: _currentEpisodeTitle,
          libraryId: _currentLibraryId,
          fromUi: fromUi,
        ),
      );
      return;
    }
    // If the player is idle (source was disposed), we need to fully re-initialize
    // playback instead of just calling play() on an empty player.
    if (_player?.processingState == ProcessingState.idle &&
        _currentItemId != null &&
        _api != null) {
      // Cap re-inits within a window so a book the engine can't start doesn't
      // spin here forever, hammering the server with fresh play sessions.
      final now = DateTime.now();
      if (_lastIdleReinit != null &&
          now.difference(_lastIdleReinit!) < _idleReinitWindow) {
        _idleReinitCount++;
      } else {
        _idleReinitCount = 1;
      }
      _lastIdleReinit = now;
      if (_idleReinitCount > _idleReinitMaxAttempts) {
        debugPrint(
          '[Player] Idle-on-resume re-init capped after $_idleReinitCount attempts — giving up to avoid a retry storm',
        );
        // The cap is a storm guard, not something the user asked for: say the
        // start failed instead of letting the press do nothing at all.
        if (fromUi) {
          final l = _l10n();
          showNavigatorOverlayToast(
            rootNavigatorKey.currentState,
            l?.playerErrorInit ?? 'Player failed to initialize',
            icon: Icons.error_outline_rounded,
          );
        }
        return;
      }
      debugPrint(
        '[Player] Player is idle on resume - re-initializing playback for $_currentItemId (attempt $_idleReinitCount)',
      );
      playItem(
        api: _api!,
        itemId: _currentItemId!,
        title: _currentTitle ?? '',
        author: _currentAuthor ?? '',
        coverUrl: _currentCoverUrl,
        totalDuration: _totalDuration,
        chapters: _chapters,
        episodeId: _currentEpisodeId,
        episodeTitle: _currentEpisodeTitle,
        libraryId: _currentLibraryId,
        seriesId: _currentSeriesId,
        fromUi: fromUi,
      );
      return;
    }
    // Restart the listening-time clock so the paused span isn't counted as
    // listening on the first sync tick after resume (a long/overnight pause
    // would otherwise be credited as up to 300s of phantom listening).
    _lastServerSync = DateTime.now();
    _lastAccrual = DateTime.now();
    _lastAccrualPos = null;
    // Start playback immediately — don't wait for server calls
    _pausedAtS = null;
    _resumeAnchorS = null;
    _player?.play();
    // Long background / overnight pauses can leave the just_audio event stream
    // throttled in Doze, so the playing=true state may not reach the MediaSession
    // on its own and the system notification isn't rebuilt after resume. Force a
    // fresh PlaybackState push (which flips the session from paused to playing and
    // re-enters the foreground) and re-push the media item metadata.
    _handler?.refreshPlaybackState();
    Future.delayed(const Duration(milliseconds: 500), () {
      _handler?.refreshPlaybackState();
    });
    if (_currentItemId != null && _currentTitle != null) {
      _repushNotifiedMediaItem();
    }
    // Any paused seek up to this instant belonged to this resume (a socket
    // adoption can land between the check above and here); the flag is for
    // seeks during the NEXT pause.
    _seekedWhilePaused = false;
    _scheduleAudioDiagnostics('resume');
    _logEvent(PlaybackEventType.play, detail: logDetail);
    _onPlaybackStateChangedCallback?.call(true);
    unawaited(_persistLastUserPlaying(true));
    final resumed = _currentItemId;
    if (fromUi && resumed != null && _currentEpisodeId == null)
      onAppPlay?.call(resumed);
    // Re-create server session and check progress in the background
    // so resume is instant instead of waiting for network round-trips
    unawaited(_resumeServerSync());

    // Restart safety-net save timer (stopped on pause to avoid background wakes)
    if (_bgSaveTimer == null || !_bgSaveTimer!.isActive) {
      _bgSaveTimer?.cancel();
      _bgSaveTimer = Timer.periodic(const Duration(seconds: 300), (_) async {
        if (_currentItemId == null || _player == null || !_player!.playing)
          return;
        final pos = _positionForProgressSave;
        final posSec = pos.inMilliseconds / 1000.0;
        if (posSec <= 0) return;
        await _saveProgressLocal(pos);
        // Backstop accrual for a frozen position stream (Doze); shares
        // _lastAccrual so it never double-counts live ticks.
        await _accrueListening(pos);
      });
    }
    // Restart stuck detection (stopped on pause to avoid background wakes)
    if (_stuckCheckTimer == null || !_stuckCheckTimer!.isActive) {
      _startStuckDetection();
    }
    // Verify playback actually started — iOS USAC decoder can silently fail
    // after a seek, leaving the player in a non-playing state with no errors.
    _schedulePlayVerify();
    // Check auto sleep on every resume — catches window entry between pauses
    SleepTimerService().checkAutoSleep();
    notifyListeners();
  }

  /// Pause long enough that another device could plausibly have listened
  /// meanwhile. Shorter pauses resume instantly with no server round trip.
  static const _serverPositionCheckMinPause = Duration(minutes: 2);

  /// How old this phone's own save of a position gets before a headphone,
  /// widget or car start asks the server whether another device moved on.
  static const _localPositionStaleAfter = Duration(minutes: 5);

  /// Whether this phone saved the item's position within
  /// [_localPositionStaleAfter].
  Future<bool> _localPositionIsFresh(String progressKey) async {
    final ts = await _progressSync.getSavedTimestamp(progressKey);
    if (ts <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch - ts <
        _localPositionStaleAfter.inMilliseconds;
  }

  /// Longest an app-screen resume waits on the server before starting where
  /// the phone left off. A late answer is dropped, never seeked to.
  static const _serverPositionCheckCap = Duration(seconds: 2);

  /// Head start given to a known-expired token before a cached/direct start
  /// rebuilds its track URLs. A refresh that outlives this falls through to
  /// the source's 401 retry instead of holding the start.
  static const _tokenPreflightCap = Duration(seconds: 3);

  /// Resume seeks on a player whose decoder died while paused can wait
  /// forever, which held play() - and every tap after it - for the whole
  /// in-flight cap. On Android, a plain seek that hasn't finished within
  /// [_resumeSeekCap] marks the player broken and the resume rebuilds it.
  /// A pending source swap is left to finish, however long it takes.
  static const _resumeSeekCap = Duration(seconds: 3);

  /// How long play() waits for the /play rebuild of a source whose session the
  /// server already closed. A healthy server answers in well under a second;
  /// the cap only exists so an unreachable one fails the start loudly in
  /// seconds instead of holding the button (and every later tap, which the
  /// in-flight guard swallows) for the request's own 40s budget.
  static const _deadSessionRebuildCap = Duration(seconds: 5);

  Future<bool> _resumeSeekFinished(
    Future<void> Function() seek,
    double target,
  ) async {
    if (!Platform.isAndroid ||
        _pendingLocalSwapKey != null ||
        _pendingSessionUpgrade != null) {
      await seek();
      return true;
    }
    try {
      await seek().timeout(_resumeSeekCap);
      return true;
    } on TimeoutException {
      debugPrint(
        '[Player] Seek to ${target.toStringAsFixed(1)}s on resume did not finish '
        'within ${_resumeSeekCap.inSeconds}s - treating the player as broken',
      );
      _playerBroken = true;
      return false;
    }
  }

  /// Before a resume after a long pause, look at the server's saved progress
  /// and, if another device genuinely moved it ahead, return that position for
  /// the resume to start at; null keeps the phone's. Runs only before audio,
  /// capped, and only after a pause long enough to matter (a few minutes from
  /// the app screen, [_localPositionStaleAfter] from headphones, car or
  /// widget); anything slower starts local.
  Future<double?> _serverPositionBeforeResume({bool fromUi = true}) async {
    if (_api == null || _currentItemId == null || _player == null) return null;
    // An idle player is about to be re-initialised through playItem, which
    // reconciles the start position itself.
    if (_player!.processingState == ProcessingState.idle) return null;
    if (_knownOffline || _isOfflineMode) return null;
    // Other-account downloads must never adopt a server position under the
    // same id (it may be a different book). Same-account downloads are safe to
    // check: the timestamp gate below only takes a genuinely newer server
    // position, which is what recovers a local record that got clobbered.
    if (_localSessionMode &&
        _downloadService.isFromOtherAccount(_currentItemId!)) {
      return null;
    }
    if (ChromecastService().isCasting) return null;
    final lastPause = _lastPauseTime;
    // BookOrbit has no live progress push to cover a short pause, so check
    // after any pause long enough for someone to have listened elsewhere.
    final minPause = !fromUi
        ? _localPositionStaleAfter
        : _api!.isBookOrbit
            ? const Duration(seconds: 10)
            : _serverPositionCheckMinPause;
    if (lastPause == null || DateTime.now().difference(lastPause) < minPause) {
      return null;
    }
    final manualOffline =
        (_prefs ?? await SharedPreferences.getInstance()).getBool(
          'manual_offline_mode',
        ) ??
        false;
    if (manualOffline) return null;
    final pKey = _currentEpisodeId != null
        ? '$_currentItemId-$_currentEpisodeId'
        : _currentItemId!;
    try {
      final localTs = await _progressSync.getSavedTimestamp(pKey);
      const checkCap = _serverPositionCheckCap;
      final serverProgress = await _api!
          .getItemProgress(pKey)
          .timeout(checkCap, onTimeout: () => null);
      if (serverProgress == null) {
        debugPrint(
          '[Player] Resume server-check (pre-start): no answer within ${checkCap.inMilliseconds}ms - starting local',
        );
        return null;
      }
      final serverPos =
          (serverProgress['currentTime'] as num?)?.toDouble() ?? 0;
      final serverTs = (serverProgress['lastUpdate'] as num?)?.toInt() ?? 0;
      final localPos = position.inMilliseconds / 1000.0;
      // Timestamp gate, like the sync path: our own pre-rewind position still
      // sits on the server after a resume, so position alone would call every
      // auto-rewind "server ahead".
      final ahead = serverTs > localTs && serverPos > localPos + 5.0;
      debugPrint(
        '[Player] Resume server-check (pre-start): server=${serverPos}s(ts=$serverTs) vs local=${localPos}s(ts=$localTs) -> ${ahead ? "SEEKING" : "keep local"}',
      );
      if (!ahead) return null;
      await _seekAbsolute(serverPos);
      _logEvent(
        PlaybackEventType.seek,
        detail:
            'adopted server position ${serverPos.toStringAsFixed(1)}s before resume',
      );
      return serverPos;
    } catch (e) {
      debugPrint('[Player] Resume server-check (pre-start) failed: $e');
      return null;
    }
  }

  /// The server session the playing source streams through, read off its
  /// URLs. Null for tokened item URLs and local files.
  String? get _sourceSessionId {
    if (_activeStreamUrls.isEmpty) return null;
    final m = RegExp(
      r'/public/session/([^/]+)/',
    ).firstMatch(_activeStreamUrls.first);
    return m?.group(1);
  }

  /// The source is loaded and streams without a server session (manifest /
  /// cache / direct-file URLs), and the backend isn't BookOrbit.
  bool get _sourceSessionless =>
      !_localSessionMode &&
      _activeStreamUrls.isNotEmpty &&
      _sourceSessionId == null &&
      _api?.isBookOrbit != true;

  /// A client-owned local session may credit the listening time for such a
  /// source (used as the fallback when the presence `/play` can't be read).
  bool get _sourceNeedsLocalAccounting =>
      _sourceSessionless && !LocalSessionService().localUnsupported;

  /// Begin a client-owned local session for the current (session-less stream)
  /// play. Stamped `streamed: true` -> Direct Play, so the server label is the
  /// same one `/play` produced. Idempotent; on an old server the eventual push
  /// falls back to the `/play` route inside [LocalSessionService].
  Future<void> _beginLocalSessionAccounting() async {
    if (_localSessionMode ||
        _localSessionAccounting ||
        !_sourceNeedsLocalAccounting) {
      return;
    }
    final api = _api;
    final itemId = _currentItemId;
    if (api == null || itemId == null) return;
    _localSessionAccounting = true;
    final key = _currentEpisodeId != null
        ? '$itemId-$_currentEpisodeId'
        : itemId;
    try {
      await LocalSessionService().beginSession(
        progressKey: key,
        libraryItemId: itemId,
        episodeId: _currentEpisodeId,
        mediaType: _currentEpisodeId != null ? 'podcast' : 'book',
        duration: _totalDuration,
        startTime: position.inMilliseconds / 1000.0,
        displayTitle: _currentTitle,
        displayAuthor: _currentAuthor,
        streamed: true,
      );
      // Probe the route with this zero-time upsert. An old server answers
      // 404/501; the legacy fallback would otherwise fire a /play on every
      // tick, so hand the listening time back to the ledger (which flushes a
      // /play only when it holds enough).
      await LocalSessionService().pushActive(api: api);
      if (LocalSessionService().localUnsupported) {
        _localSessionAccounting = false;
        await LocalSessionService().finalizeActive(pushed: true);
        debugPrint(
          '[Player] Server lacks /api/session/local - keeping the offline '
          'ledger for listening time',
        );
        return;
      }
      debugPrint(
        '[Player] Listening credited via local session (source has no '
        'playback session)',
      );
    } catch (e) {
      _localSessionAccounting = false;
      debugPrint('[Player] Local session begin failed: $e');
    }
  }

  bool _presenceSessionInFlight = false;
  DateTime? _presenceSessionRetryAfter;

  /// Statistics session for a session-less stream. Prefers a presence-only
  /// `/play` (the server registers an active session; only its id is read and
  /// the multi-MB track list is dropped) so the server's active sessions and
  /// per-session sync work as before. Falls back to the client-owned local
  /// session when the head can't be read.
  Future<void> _ensureStatsSessionForSessionlessSource() async {
    if (_playbackSessionId != null || _localSessionAccounting) return;
    final api = _api;
    final itemId = _currentItemId;
    if (api == null || itemId == null || !_sourceSessionless) return;
    // Offline listening belongs in the ledger, not in a stream of failed
    // presence requests; a failed online attempt is retried after a pause
    // instead of once per sync tick.
    final manualOffline = (_prefs?.getBool('manual_offline_mode')) ?? false;
    if (manualOffline || _isOfflineMode) return;
    final retryAfter = _presenceSessionRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    if (_presenceSessionInFlight) return;
    _presenceSessionInFlight = true;
    final episodeId = _currentEpisodeId;
    final generation = _playbackGeneration;
    final client = http.Client();
    String? id;
    try {
      id = await api.startPlaybackSessionPresence(
        itemId,
        client,
        episodeId: episodeId,
      );
    } catch (e) {
      debugPrint('[Player] Presence session failed: $e');
    } finally {
      _presenceSessionInFlight = false;
      client.close();
    }
    if (id == null) {
      _presenceSessionRetryAfter =
          DateTime.now().add(const Duration(minutes: 2));
      await _beginLocalSessionAccounting();
      return;
    }
    if (_currentItemId != itemId ||
        _currentEpisodeId != episodeId ||
        _playbackGeneration != generation) {
      // The book changed while the head was in flight - close the stray.
      unawaited(api.closePlaybackSession(id).catchError((Object _) {}));
      return;
    }
    if (_playbackSessionId != null) {
      unawaited(api.closePlaybackSession(id).catchError((Object _) {}));
      return;
    }
    _playbackSessionId = id;
    _presenceSessionRetryAfter = null;
    _lastServerSync = DateTime.now();
    debugPrint('[Player] Presence session $id (stats-only, no track list)');
  }

  /// Re-create the server playback session from the sync tick: the guarded
  /// branch needs one (a session-backed source whose id was lost, or a
  /// BookOrbit stream), and reuses the same stashing/adoption path a start
  /// uses.
  Future<void> _recreateSessionInSyncTick() async {
    _recreatingSession = true;
    try {
      final sessionApi = _api!;
      final sessionItemId = _currentItemId!;
      final sessionEpisodeId = _currentEpisodeId;
      final sessionData = sessionEpisodeId != null
          ? await sessionApi.startEpisodePlaybackSession(
              sessionItemId,
              sessionEpisodeId,
            )
          : await sessionApi.startPlaybackSession(sessionItemId);
      if (_currentItemId != sessionItemId ||
          _currentEpisodeId != sessionEpisodeId) {
        final staleId = sessionData?['id'] as String?;
        if (staleId != null) {
          unawaited(sessionApi.closePlaybackSession(staleId));
        }
      } else if (sessionData != null) {
        _playbackSessionId = sessionData['id'] as String?;
        if (_playbackSessionId != null) {
          debugPrint(
            '[Player] Recreated session in sync tick: $_playbackSessionId',
          );
          // The playing source still points at the OLD session's URLs. Adopt
          // this one at the next pause/seek, unless that old session is
          // already gone: then the stream dies with the cache, so move it now.
          _stashSessionUpgrade(sessionData);
          if (_sourceSessionDead) {
            final playing = _player?.playing ?? false;
            if (!await _applyPendingLocalSwap(resumeAfter: playing)) {
              await _applyPendingSessionUpgrade(resumeAfter: playing);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[Player] Session recreate in sync tick failed: $e');
    } finally {
      _recreatingSession = false;
    }
  }

  /// A session URL stops working the moment the server closes the session:
  /// its public track route serves open sessions only, and Audiobookshelf
  /// closes any other open session from the same device when a new one
  /// starts. So a source is dead once its session is no longer the one we
  /// hold - closed by the pause timeout, or replaced. Playback carries on
  /// from the cache until that runs out, then a 404 and a five-second retry.
  bool get _sourceSessionDead {
    if (_localSessionMode) return false;
    final sid = _sourceSessionId;
    return sid != null && sid != _playbackSessionId;
  }

  /// Restart the current book from its start manifest rather than paying a
  /// /play round trip. The manifest carries the file ids, so the source can be
  /// built locally and playback resumes at the live position without waiting
  /// on the server.
  ///
  /// This is the answer to "back after a long background, the ticket is gone":
  /// the reload goes through [playItem], whose manifest path opens the tracks
  /// from disk; the session it may open in the background only feeds progress.
  /// Books only (a show's files hang off its episodes).
  Future<bool> _restartFromManifestIfPossible({bool fromUi = false}) async {
    final api = _api;
    final itemId = _currentItemId;
    if (api == null || itemId == null || _currentEpisodeId != null) {
      return false;
    }
    if (_localSessionMode ||
        _isOfflineMode ||
        _knownOffline ||
        _manualOffline ||
        ChromecastService().isCasting) {
      return false;
    }
    final manifest = await PlaybackManifest.load(itemId);
    if (manifest == null) return false;
    final posSec = _sourceSwapTarget(
      null,
      resumeAfter: _player?.playing ?? false,
    );
    debugPrint(
      '[Manifest] Dead-session resume — rebuilding the source from the '
      'manifest at ${posSec.toStringAsFixed(1)}s (no /play wait)',
    );
    unawaited(
      playItem(
        api: api,
        itemId: itemId,
        title: _currentTitle ?? '',
        author: _currentAuthor ?? '',
        coverUrl: _currentCoverUrl,
        totalDuration: _totalDuration,
        chapters: _chapters,
        // The pause spot (or live position while playing) is authoritative
        // here: local progress may lag by a few seconds, and a rewind would
        // be audible.
        startTime: posSec > 0 ? posSec : 0,
        forceStartTime: posSec > 0,
        libraryId: _currentLibraryId,
        seriesId: _currentSeriesId,
        fromUi: fromUi,
      ),
    );
    return true;
  }

  /// Add the stable streaming-cache key for a direct-file URL.
  ///
  /// media3 keys its disk cache by the full URL, and our URLs carry a token
  /// (`?token=…`) that is re-signed on every start - so the same file became a
  /// different cache entry each session, and a seek back inside a chapter that
  /// had already been played still went to the network. `itemId|ino` is stable
  /// across sessions and unique per file; the player plugin reads it and never
  /// sends it upstream. Session track URLs have no ino and keep the default key.
  Map<String, String> _withCacheKey(
    Map<String, String> headers,
    String? itemId,
    String url,
  ) {
    if (itemId == null || itemId.isEmpty) return headers;
    final ino = RegExp(r'/file/([^/?#]+)').firstMatch(url)?.group(1);
    if (ino == null || ino.isEmpty) return headers;
    final key = '$itemId|$ino';
    // Log the book once, not once per file: every track has its own ino, so
    // the old per-key check printed one line per track (1122 lines per start
    // on a thousand-file book) and dominated the exported log.
    if (_lastLoggedCacheKey != itemId) {
      _lastLoggedCacheKey = itemId;
      debugPrint('[Player] Streaming cache key book=$itemId (itemId|ino per file)');
    }
    return {...headers, 'X-Absorb-Cache-Key': key};
  }

  // Last book whose cache key was reported, so the line prints once per book
  // rather than once per track.
  String? _lastLoggedCacheKey;

  /// Move a source that streams through a dead session onto a live one.
  /// Starts a session when we hold none; a held one is adopted through the
  /// pending upgrade. Returns whether the source was rebuilt.
  Future<bool> _rebuildSourceOnDeadSession({required bool resumeAfter}) async {
    if (_api == null || _currentItemId == null || _localSessionMode) {
      return false;
    }
    // A finished download takes the rebuild: no new session, no network.
    if (await _applyPendingLocalSwap(resumeAfter: resumeAfter)) return true;
    if (_isOfflineMode || _knownOffline || ChromecastService().isCasting) {
      return false;
    }
    final manualOffline =
        (_prefs ?? await SharedPreferences.getInstance()).getBool(
          'manual_offline_mode',
        ) ??
        false;
    if (manualOffline) return false;
    final pending = _pendingSessionUpgrade;
    if (pending == null || pending['id'] != _playbackSessionId) {
      if (_recreatingSession || _isLoadingNewItem) return false;
      _recreatingSession = true;
      final api = _api;
      final sessionItemId = _currentItemId;
      final sessionEpisodeId = _currentEpisodeId;
      if (api == null || sessionItemId == null) {
        _recreatingSession = false;
        return false;
      }
      try {
        final sessionData = await _sharedSessionStart(
          api,
          sessionItemId,
          sessionEpisodeId,
        );
        if (_currentItemId != sessionItemId ||
            _currentEpisodeId != sessionEpisodeId) {
          final staleId = sessionData?['id'] as String?;
          if (staleId != null) unawaited(api.closePlaybackSession(staleId));
          return false;
        }
        if (sessionData == null) return false;
        _playbackSessionId = sessionData['id'] as String?;
        _logEvent(PlaybackEventType.sessionStart, detail: 'dead source');
        _stashSessionUpgrade(sessionData);
      } catch (e) {
        debugPrint('[Player] Session start for a dead source failed: $e');
        return false;
      } finally {
        _recreatingSession = false;
      }
    }
    // A rebuild can outlive its caller's patience (play() caps the wait and
    // lets the start go ahead on the source it has). By the time the session
    // lands the listener may already be hearing audio, so resume after the
    // swap - replacing the source under a playing engine without that would
    // hand back silence for no visible reason.
    final swapped = await _applyPendingSessionUpgrade(
      resumeAfter: resumeAfter || (_player?.playing ?? false),
    );
    debugPrint(
      '[Player] Source was on a closed session - '
      '${swapped ? 'rebuilt on ${_playbackSessionId?.substring(0, 8)}' : 'rebuild failed, keeping it'}',
    );
    return swapped;
  }

  /// Progress-endpoint sync for a tick whose session sync could not be used.
  Future<void> _syncProgressWithoutSession(Duration pos) async {
    if (_api == null || _currentItemId == null) return;
    final key = _currentEpisodeId != null
        ? '$_currentItemId-$_currentEpisodeId'
        : _currentItemId!;
    try {
      await _saveProgressLocal(pos);
      final ok = await _progressSync.syncToServer(api: _api!, itemId: key);
      debugPrint(
        '[Player] Direct progress sync ${ok ? 'succeeded' : 'returned false'}',
      );
    } catch (e) {
      debugPrint('[Player] Direct progress sync error: $e');
    }
  }

  /// Foreground prewarm for the next play tap: re-create the playback session
  /// in the background, so the tap starts from a live source instead of paying
  /// the rebuild that play() would otherwise wait on (capped at
  /// [_deadSessionRebuildCap]). The early checks only keep this quiet; the
  /// session start re-validates everything, and its own [_recreatingSession]
  /// guard makes a flapping foreground harmless.
  ///
  /// Session only - deliberately no source swap here. Swapping would make the
  /// engine prepare the new stream and prefetch its opening audio while the
  /// user may only be looking at the app, which is traffic nobody asked for.
  /// The tap-time rebuild finds this session stashed ([_pendingSessionUpgrade])
  /// and only has to move the source, so the slow part - the /play round trip -
  /// is already paid for.
  ///
  /// Gated to a recent pause (within [_prewarmResumeWindow]) that this pause
  /// hasn't already prewarmed, and throttled to [_sessionPrewarmCooldown]: a
  /// failed attempt (server down, link still coming up) would otherwise repeat
  /// on every app switch, each one burning a /play request's 20s x 2 budget. A
  /// session it does open is armed for closing ([_armPrewarmSessionClose]) so
  /// it cannot linger unused.
  Future<void> _prewarmSessionForPlay() async {
    if (_api == null || _currentItemId == null || _isLoadingNewItem) return;
    if (_localSessionMode ||
        _isOfflineMode ||
        _knownOffline ||
        _manualOffline) {
      return;
    }
    if (ChromecastService().isCasting) return;
    // A held session whose URLs the source hasn't adopted yet already came with
    // a stashed upgrade (resume/sync-tick recreations stash before they swap),
    // so there is nothing to open here: the tap applies it.
    if (_playbackSessionId != null) return;
    // A prewarm only pays off when the SOURCE streams through a playback
    // session: a dead session is what makes the next play wait for a rebuild.
    // Manifest / cached sources use tokened file URLs (there is no session to
    // die) and play() opens its stats session in the background anyway, so
    // warming one here is a multi-MB `/play` download for nothing.
    if (_sourceSessionId == null) return;
    // Prewarm only covers a pause the listener is likely to resume. A book
    // left paused for a long time is far more often opened to browse than to
    // play, and each prewarm downloads the whole `/play` session body (multi-MB
    // on a server that doesn't compress its API JSON).
    final lastPause = _lastPauseTime;
    if (lastPause == null ||
        DateTime.now().difference(lastPause) > _prewarmResumeWindow) {
      debugPrint(
        '[Service] Foreground prewarm skipped - no recent pause to resume',
      );
      return;
    }
    // One prewarm per pause: a prewarm the listener never used (they only
    // switched apps) must not be repeated for the SAME pause after the
    // cooldown - the unused session was already closed by its own timer.
    final lastPrewarm = _lastSessionPrewarmAt;
    if (lastPrewarm != null && !lastPrewarm.isBefore(lastPause)) {
      debugPrint(
        '[Service] Foreground prewarm skipped - this pause was already '
        'prewarmed',
      );
      return;
    }
    final last = _lastSessionPrewarmAt;
    if (last != null) {
      final since = DateTime.now().difference(last);
      if (since < _sessionPrewarmCooldown) {
        debugPrint(
          '[Service] Foreground prewarm skipped - last attempt '
          '${since.inSeconds}s ago',
        );
        return;
      }
    }
    _lastSessionPrewarmAt = DateTime.now();
    await _resumeServerSync();
    final opened = _playbackSessionId;
    if (opened != null) _armPrewarmSessionClose(opened);
  }

  DateTime? _lastSessionPrewarmAt;

  /// Aligned with [_pauseStopTimeout]: a session that died of the pause timeout
  /// cannot be needed again before that same window has passed, so there is no
  /// point asking a second time sooner.
  static const _sessionPrewarmCooldown = Duration(minutes: 10);

  /// How recently the listener must have paused for a foreground prewarm to be
  /// worth its multi-MB `/play` body. Past this, opening the app reads as
  /// browsing rather than returning to the book.
  static const _prewarmResumeWindow = Duration(minutes: 30);

  Timer? _prewarmSessionCloseTimer;

  /// Close a prewarmed session the user never used.
  ///
  /// Prewarm opens it while the book is paused, but the pause timeout that
  /// normally closes sessions already fired for this pause - so without this
  /// the server keeps an idle session (and its "now playing" view) until the
  /// app is killed. Deliberately not reusing [_pauseStopTimer]: its body also
  /// cancels an active sleep timer, which is not this timer's business.
  void _armPrewarmSessionClose(String sessionId) {
    _prewarmSessionCloseTimer?.cancel();
    _prewarmSessionCloseTimer = Timer(_pauseStopTimeout, () {
      _prewarmSessionCloseTimer = null;
      // Closed or replaced elsewhere: whoever did that owns the cleanup.
      if (_playbackSessionId != sessionId) return;
      // In use now - pause()/stop() will close it on their own schedule.
      if (_player?.playing ?? false) return;
      // A start is still working with this very session (the tap landed just
      // before the timer): closing it now would pull the session out from
      // under the load. Look again later.
      if (_isLoadingNewItem || _recreatingSession) {
        debugPrint(
          '[Service] Prewarmed session close deferred - a start is in flight',
        );
        _armPrewarmSessionClose(sessionId);
        return;
      }
      debugPrint(
        '[Service] Prewarmed session unused for '
        '${_pauseStopTimeout.inMinutes}min - closing it',
      );
      _playbackSessionId = null;
      if (_pendingSessionUpgrade?['id'] == sessionId) {
        _pendingSessionUpgrade = null;
      }
      _logEvent(PlaybackEventType.sessionEnd, detail: 'prewarm unused');
      final api = _api;
      if (api != null) unawaited(api.closePlaybackSession(sessionId));
    });
  }

  /// One `/play` in flight per item, shared by every caller.
  ///
  /// Two starts used to open their own session - a launch restore's background
  /// resume and the user's tap, or a rebuild and a resume refresh. On a slow
  /// link both multi-MB response bodies competed with the first audio bytes;
  /// one measured start lost 16s to exactly that. Reusing the in-flight request
  /// removes the duplicate traffic without changing who owns the result (each
  /// caller still validates the session against its own item/episode).
  final Map<String, Future<Map<String, dynamic>?>> _sharedSessionStarts = {};

  String _sessionStartKey(String itemId, String? episodeId) =>
      episodeId == null ? itemId : '$itemId-$episodeId';

  Future<Map<String, dynamic>?> _sharedSessionStart(
    ApiService api,
    String itemId,
    String? episodeId,
  ) {
    final key = _sessionStartKey(itemId, episodeId);
    final inFlight = _sharedSessionStarts[key];
    if (inFlight != null) {
      debugPrint('[Player] Reusing the in-flight /play for $key');
      return inFlight;
    }
    // Opened through the cancellable request so a start that needs the pipe can
    // abort this body. On a server that doesn't compress its API JSON the body
    // is several MB - one capture: 3.48 MB / 13.1s at 270 KB/s - and a start
    // that landed during it waited 9.9s for the same bytes. playItem cancels
    // every pending session client at its top, so the body stops the moment a
    // start begins; the session is then opened again by the sync tick.
    final future = _startSessionRequest(
      api: api,
      itemId: itemId,
      episodeId: episodeId,
      timeout: const Duration(seconds: 40),
    ).whenComplete(() => _sharedSessionStarts.remove(key));
    _sharedSessionStarts[key] = future;
    return future;
  }

  /// Re-create the server session after a pause long enough to have closed
  /// it. Runs in the background so play() returns instantly. Position is not
  /// touched here: once audio is running we never seek it out from under the
  /// listener (see play()).
  Future<void> _resumeServerSync() async {
    if (_api == null || _currentItemId == null) return;
    if (_recreatingSession || _isLoadingNewItem) return;
    if (_playbackSessionId != null) return;
    // A source that doesn't stream through a server session needs no full
    // /play: a presence-only session keeps the server's active view and the
    // per-session sync, and only its id is read from the response.
    if (_sourceSessionless) {
      await _ensureStatsSessionForSessionlessSource();
      return;
    }
    final manualOffline =
        (_prefs ?? await SharedPreferences.getInstance()).getBool(
          'manual_offline_mode',
        ) ??
        false;
    if (manualOffline || _isOfflineMode || _localSessionMode) {
      debugPrint(
        '[Player] Skipping session re-create on resume (manualOffline=$manualOffline, isOffline=$_isOfflineMode, localSession=$_localSessionMode)',
      );
      return;
    }
    final api = _api!;
    final sessionItemId = _currentItemId!;
    final sessionEpisodeId = _currentEpisodeId;
    _recreatingSession = true;
    try {
      final sessionData = await _sharedSessionStart(
        api,
        sessionItemId,
        sessionEpisodeId,
      );
      if (_currentItemId != sessionItemId ||
          _currentEpisodeId != sessionEpisodeId) {
        final staleId = sessionData?['id'] as String?;
        if (staleId != null) unawaited(api.closePlaybackSession(staleId));
        return;
      }
      if (sessionData != null) {
        _playbackSessionId = sessionData['id'] as String?;
        debugPrint(
          '[Player] Re-created session on resume: $_playbackSessionId',
        );
        _stashSessionUpgrade(sessionData);
      }
    } catch (e) {
      debugPrint('[Player] Failed to re-create session on resume: $e');
    } finally {
      _recreatingSession = false;
    }
  }

  Future<void> pause() async {
    final sw = Stopwatch()..start();
    debugPrint('[RemoveTrace] pause entry');
    _markPauseRequested();
    // Any pause other than our own offline auto-pause is the user taking over,
    // so a reconnect must not resume for them.
    _pausedForOffline = false;
    debugPrint('[Service] pause() called');
    _playVerifyTimer?.cancel();
    _wasPlayingBeforeInterrupt = false;
    _lastPauseTime = DateTime.now();
    // Stamp BT-route observation for AA-disconnect phantom-click detection.
    // Fire-and-forget: pause shouldn't block on a native call.
    unawaited(
      _isBluetoothAudioConnected().then((bt) {
        if (bt) _lastPlayedOnBtAt = DateTime.now();
      }),
    );
    // Stop timers to avoid background wakes while paused
    if (_bgSaveTimer != null) {
      _bgSaveTimer!.cancel();
      _bgSaveTimer = null;
    }
    if (_stuckCheckTimer != null) {
      _stuckCheckTimer!.cancel();
      _stuckCheckTimer = null;
    }
    await _player?.pause();
    debugPrint('[RemoveTrace] pause engine ${sw.elapsedMilliseconds}ms');
    _logEvent(PlaybackEventType.pause);
    _onPlaybackStateChangedCallback?.call(false);
    unawaited(_persistLastUserPlaying(false));

    notifyListeners();
    // A pause while the item is still loading has nothing to save: the
    // player sits at zero until its start seek lands, and saving that sent
    // 0:00 to the server (GH #479). The start keeps the saved position.
    final state = _player?.processingState;
    if (_isLoadingNewItem &&
        (state == null ||
            state == ProcessingState.idle ||
            state == ProcessingState.loading)) {
      _resumeAnchorS = null;
      debugPrint('[Player] Paused while the item is still loading - keeping the saved position');
      return;
    }
    final pos = _positionForProgressSave;
    _pausedAtS = pos.inMilliseconds / 1000.0;
    _resumeAnchorS = _pausedAtS;
    debugPrint(
      '[Player] Saving on pause: ${(pos.inMilliseconds / 1000.0).toStringAsFixed(1)}s',
    );
    await _saveProgressLocal(pos);

    // Check manual offline before syncing
    final manualOffline =
        (_prefs ?? await SharedPreferences.getInstance()).getBool(
          'manual_offline_mode',
        ) ??
        false;

    // Credit listening right up to the pause for whatever mode is active — we
    // were playing until now — then let the push below ship it. resume (play())
    // restarts both clocks so the paused span is never counted. Runs even under
    // manual offline since accrual works offline.
    await _accrueListening(pos);
    if (_localSessionMode || _localSessionAccounting) {
      final online = !manualOffline && !_isOfflineMode && _api != null;
      if (online) unawaited(LocalSessionService().pushActive(api: _api!));
      _lastServerSync = DateTime.now();
      _lastAccrual = DateTime.now();
    }

    if (manualOffline || _knownOffline) return;

    if (!_isOfflineMode && _playbackSessionId != null) {
      debugPrint('[RemoveTrace] pause sync start ${sw.elapsedMilliseconds}ms');
      await _syncToServer(pos);
      debugPrint('[RemoveTrace] pause sync done ${sw.elapsedMilliseconds}ms');
    } else if (!_isOfflineMode && _currentItemId != null && _api != null) {
      final syncKey = _currentEpisodeId != null
          ? '$_currentItemId-$_currentEpisodeId'
          : _currentItemId!;
      _progressSync.syncToServer(api: _api!, itemId: syncKey);
    }

    // Paused audio is the other free moment to adopt a waiting session's
    // tokenless URLs - the rebuild is inaudible and playback resumes on a
    // source that can't hit token expiry.
    // A finished download goes first - once on the files the session's URLs
    // no longer matter.
    if (_pendingLocalSwapKey != null) {
      final swap = _pauseSwap = _applyPendingLocalSwap(resumeAfter: false);
      unawaited(swap);
    } else if (_pendingSessionUpgrade != null) {
      final swap = _pauseSwap = _applyPendingSessionUpgrade(resumeAfter: false);
      unawaited(swap);
    }

    // After 10 min paused, close the server session so we don't inflate
    // listening stats with paused time. We deliberately keep the AudioSession
    // active and the player paused (not stopped) so the foreground service
    // stays in foreground state and the MediaSession stays alive - this is
    // what keeps notification / lock screen / Bluetooth / WearOS controls
    // responsive after a long pause. Same pattern as Spotify and Pocket Casts.
    _pauseStopTimer?.cancel();
    _pauseStopTimer = Timer(_pauseStopTimeout, () async {
      debugPrint('[Player] Pause timeout - releasing server session');
      // Close server playback session. timeListened=0 because the user has
      // been paused for the whole pause-timeout window - the wall-clock diff
      // would otherwise inflate server listening stats by up to 300s.
      if (_playbackSessionId != null && _api != null) {
        _logEvent(PlaybackEventType.sessionEnd, detail: 'pause timeout');
        try {
          await _syncToServer(position, timeListenedOverride: 0);
          debugPrint('[Player] Closing session (pause timeout)');
          await _api!.closePlaybackSession(_playbackSessionId!);
        } catch (_) {}
        _playbackSessionId = null;
      }
      // Cancel sleep timer
      if (SleepTimerService().isActive) {
        SleepTimerService().cancel();
      }
    });
  }

  Future<void> togglePlayPause({bool fromUi = false}) async {
    debugPrint('[Service] togglePlayPause() — isPlaying=$isPlaying');
    if (isPlaying) {
      await pause();
    } else {
      await play(fromUi: fromUi);
    }
  }

  /// Forward an ABSOLUTE book position to the receiver when the item being
  /// seeked is the one on screen: the cast IS the player then, and a local-only
  /// seek just moves a stopped local player (GH #273).
  Future<void> _forwardSeekToCast(Duration pos) async {
    final cast = ChromecastService();
    if (!cast.isCasting ||
        _currentItemId == null ||
        cast.castingItemId != _currentItemId ||
        cast.castingEpisodeId != _currentEpisodeId) {
      return;
    }
    await cast.seekTo(pos);
  }

  Future<void> seekTo(
    Duration pos, {
    PlaybackEventType logAs = PlaybackEventType.seek,
    String? logDetail,
    // True when the caller is jumping to a specific chapter (chapter sheet,
    // next/prev chapter): the seek may then snap to the nearest file boundary
    // to compensate for metadata-vs-file timeline drift. All other seeks keep
    // the exact position.
    bool chapterJump = false,
  }) async {
    // Offline + non-downloaded source: a scrub seeks the stream, fetching the
    // network bytes offline mode must not request — unless the seek target sits
    // inside a DOWNLOADED chapter, in which case re-enter local playback there.
    if (_offlineRemoteStream) {
      final targetSec = pos.inMilliseconds / 1000.0;
      if (await _reenterLocalPlayIfCovered(targetSec)) return;
      debugPrint(
        '[Service] seekTo blocked — offline, current item is a stream and '
        '${targetSec.toStringAsFixed(1)}s has no downloaded audio',
      );
      return;
    }
    await _forwardSeekToCast(pos);
    _resetStuckDetection();
    if (_player != null && !_player!.playing) _seekedWhilePaused = true;
    _lastUserSeekTime = DateTime.now();
    final from = position;
    final targetSec = pos.inMilliseconds / 1000.0;
    // While a start is still loading, its source swap/initial position is
    // about to overwrite any seek issued now. Record the request and let the
    // start apply it once the engine is ready. Pinning it here too keeps the
    // title/bar on the dragged chapter immediately instead of snapping back
    // to where the load was heading.
    if (_isLoadingNewItem) {
      _queueLoadSeek(
        targetSec,
        apply: () => seekTo(
          Duration(milliseconds: (targetSec * 1000).round()),
          logAs: logAs,
          logDetail: logDetail,
          chapterJump: chapterJump,
        ),
      );
      return;
    }
    // A precise seek (scrubber drag, bookmark/history restore) whose target
    // lands within 1s of a chapter's metadata start is treated as a chapter
    // jump: metadata-vs-file drift can put the target a hair BEFORE the
    // chapter's own file, so an exact seek would land on the PREVIOUS file's
    // tail — playing it and showing the previous chapter's title (the same
    // mislabel as the rewind case). The boundary snap + nearest-start latch
    // then land on the intended file and pin its title. The 1s tolerance is
    // the same band [_latchChapterJumpTarget] accepts, so only targets that
    // clearly mean "the start of that chapter" are promoted; mid-chapter
    // scrubs keep their exact position.
    final boundaryJump = !chapterJump && _isChapterStartWithin(targetSec);
    await _seekAbsolute(targetSec, chapterJump: chapterJump || boundaryJump);
    // A scrub that reached the download boundary parks there (pause + last
    // downloaded chapter) instead of leaving the engine completed at the file
    // end with the next chapter's title — and unlike waiting for the
    // completion signal, this parks even when no completion listener is alive
    // to see the boundary.
    final coverageEnd = _localCoverageEndSec;
    if (_isPartialLocalPlay &&
        coverageEnd != null &&
        (pos.inMilliseconds / 1000.0) > coverageEnd - 0.5) {
      await _parkAtPartialBoundary();
    }
    _logEvent(
      logAs,
      detail: logDetail ?? '${_formatPos(from)} → ${_formatPos(pos)}',
      overridePosition: from.inMilliseconds / 1000.0,
    );
    notifyListeners();
  }

  /// Jump straight to a specific chapter (chapter sheet). Unlike [seekTo] with
  /// [chapterJump], which hands the engine a whole-second-rounded target and
  /// lets the nearest-start heuristic re-infer the intended chapter, the
  /// caller already KNOWS the chapter — so the index is pinned up front and
  /// the target is the chapter's exact metadata start (no `.round()`). A
  /// rounded-down target (e.g. 6517.2 — 6517.0) can otherwise land a hair
  /// BEFORE the chapter's own metadata start; the boundary snap + nearest
  /// -start latch then both promote to the NEXT chapter and the jump lands a
  /// chapter off ("012" is played, "013" is reported).
  Future<void> seekToChapterIndex(int chapterIndex) =>
      _chapterJumpThenAutoPlay(() => _seekToChapterIndexImpl(chapterIndex));

  Future<bool> _seekToChapterIndexImpl(int chapterIndex) async {
    if (_player == null || _chapters.isEmpty) return false;
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return false;
    final ch = _chapters[chapterIndex] as Map<String, dynamic>;
    final start = (ch['start'] as num?)?.toDouble() ?? 0;
    // The engine cannot seek while its source is loading — record the chapter
    // jump and run it (with intro-skip / boundary snap / pin) once the start
    // has landed. Without this the start landed on its own position (often
    // chapter 1) and the tap looked like "jump to the first episode".
    if (_isLoadingNewItem) {
      _queueLoadSeek(
        start,
        apply: () => _seekToChapterIndexImpl(chapterIndex),
      );
      return true;
    }
    // Offline + network source: only the DOWNLOADED chapters are reachable.
    // Tap one to re-enter local playback; anything else is a no-op (its audio
    // isn't on disk).
    if (_offlineRemoteStream) {
      final subset = _downloadedChapterSubset();
      if (subset == null || !subset.contains(chapterIndex)) {
        debugPrint(
          '[Service] Chapter jump blocked — offline and chapter '
          '${chapterIndex + 1} is not downloaded',
        );
        return false;
      }
      return _reenterLocalPlayIfCovered(start);
    }
    // Partial download: a chapter with no local audio continues the book via
    // streaming when online; offline the tap is a clean no-op instead of a
    // dead seek into the gap (or a clamp into a neighbouring file that
    // phantom-completes with the wrong chapter's title).
    final gate = await _partialJumpGate(start);
    if (gate != null) return gate;
    // Land DIRECTLY at the intro-skip point when enabled, instead of seeking
    // to the chapter start and letting the post-landing position tick catch up.
    // A raw chapter-start jump sets _lastUserSeekTime, which suppresses the
    // auto-skip for 3s - so the listener heard the opening ~3s of every chapter
    // before the skip yanked forward. Mirrors the prev/next pre-jump exactly.
    final introTarget = await _crossChapterIntroSkipTarget(chapterIndex);
    var target = introTarget ?? start;
    // Chapter end for the repair clamp: explicit end, else next chapter start.
    double chapterEnd = _totalDuration;
    final endFromData = (ch['end'] as num?)?.toDouble();
    final nextStart = chapterIndex + 1 < _chapters.length
        ? ((_chapters[chapterIndex + 1] as Map)['start'] as num?)?.toDouble()
        : null;
    if (endFromData != null) {
      chapterEnd = endFromData;
    } else if (nextStart != null) {
      chapterEnd = nextStart;
    }
    await _forwardSeekToCast(Duration(milliseconds: (target * 1000).round()));
    _resetStuckDetection();
    // Re-check after the cast await: the item can be swapped out while the
    // receiver round-trips. Same reason [seekTo] does.
    if (_player != null && !_player!.playing) _seekedWhilePaused = true;
    _lastUserSeekTime = DateTime.now();
    final from = position;
    if (introTarget != null) {
      // Intro-skip landing is offset INTO the chapter - stay precise, no file-
      // boundary snap (matches the prev/next pre-jump).
      await _seekAbsoluteAlignedRepair(
        target,
        clampMaxSec: chapterEnd - 1.0,
        chapterJump: false,
        pinChapterIndex: chapterIndex,
      );
    } else {
      await _seekAbsolute(
        target,
        chapterJump: true,
        pinChapterIndex: chapterIndex,
      );
    }
    _logEvent(
      PlaybackEventType.seek,
      detail: introTarget != null && introTarget - start >= 0.5
          ? 'chapter ${chapterIndex + 1} to ${introTarget.toStringAsFixed(1)}s (intro skip)'
          : 'chapter ${chapterIndex + 1}',
      overridePosition: from.inMilliseconds / 1000.0,
    );
    notifyListeners();
    return true;
  }

  /// Rewind triggered by the sleep timer firing. Same mechanics as a manual
  /// seek-back, but logged as an auto-rewind so the playback history reads
  /// "Auto-rewound 15m (sleep timer)" instead of a raw seek (GH #232).
  Future<void> sleepTimerRewind(int seconds) async {
    if (seconds <= 0) return;
    var target = position - Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final amount = seconds % 60 == 0 ? '${seconds ~/ 60}m' : '${seconds}s';
    await seekTo(
      target,
      logAs: PlaybackEventType.autoRewind,
      logDetail: '$amount (sleep timer)',
    );
    // Pausing for sleep already saved and sent the spot from before the
    // rewind, so a restart or another device went back there (GH #433).
    debugPrint(
      '[SleepTimer] Saving the rewound spot: ${(target.inMilliseconds / 1000.0).toStringAsFixed(1)}s',
    );
    await _saveProgressLocal(target);
    final manualOffline =
        (_prefs ?? await SharedPreferences.getInstance()).getBool(
          'manual_offline_mode',
        ) ??
        false;
    if (manualOffline || _isOfflineMode) return;
    if (_playbackSessionId != null) {
      await _syncToServer(target, timeListenedOverride: 0);
    } else if (_currentItemId != null && _api != null) {
      final syncKey = _currentEpisodeId != null
          ? '$_currentItemId-$_currentEpisodeId'
          : _currentItemId!;
      _progressSync.syncToServer(api: _api!, itemId: syncKey);
    }
  }

  /// Offline on a network source: the current item isn't downloaded and there
  /// is no stream to jump through, so [action] (a skip that would seek the
  /// streaming engine) must not run. Logs the block under that name.
  bool _offlineRemoteTransportBlocked(String action) {
    if (!_offlineRemoteStream) return false;
    debugPrint(
      '[Service] $action blocked — offline and the current item is not downloaded',
    );
    return true;
  }

  Future<void> skipForward([int seconds = 30]) async {
    if (_player == null) return;
    if (_offlineRemoteTransportBlocked('skipForward')) return;
    _resetStuckDetection();
    if (!_player!.playing) _seekedWhilePaused = true;
    // Skip amounts are CONTENT seconds: the position moves exactly the
    // configured amount of audio, regardless of playback speed.
    final adjusted = seconds;
    _lastUserSeekTime = DateTime.now();
    debugPrint(
      '[Service] skipForward(${adjusted}s) — playing=${_player!.playing}',
    );
    final newPos = position + Duration(seconds: adjusted);
    final posS = position.inMilliseconds / 1000.0;
    var newPosS = newPos.inMilliseconds / 1000.0;
    // Mirror of skipBackward's chapter barrier: a forward skip that would
    // cross into the next chapter stops at this chapter's end (the boundary
    // itself) instead of skipping over it. The next boundary is looked up
    // regardless of the setting: with the barrier ON it also bounds the
    // landing-repair below, so a within-chapter skip can't spill past it.
    final forwardBarrier = await PlayerSettings.getSkipChapterBarrier();
    double? nextChapterStart;
    if (_chapters.isNotEmpty) {
      for (var i = 0; i < _chapters.length; i++) {
        final s = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
        if (s > posS + 0.5) {
          nextChapterStart = s;
          break;
        }
      }
    }
    if (forwardBarrier && _chapters.isNotEmpty) {
      if (nextChapterStart != null && newPosS > nextChapterStart) {
        // Crossing the boundary lands where a chapter jump would: the next
        // chapter's start, with its intro skip applied by the normal
        // chapter-entry logic. Snapping to the last frame instead left the
        // player sitting on a completed chapter. PAUSED, the jump must
        // reposition only — the auto-play wrapper here is what made a
        // paused forward skip with less remaining than the skip amount
        // start playing by itself ("剩余时间小于快进时间就自动播放"). The
        // chapter BUTTONS keep the auto-resume; a skip press does not.
        _logEvent(
          PlaybackEventType.skipForward,
          detail: 'cross to next chapter (intro skip applies)',
        );
        if (_player!.playing) {
          await skipToNextChapter();
        } else {
          await _skipToNextChapterImpl();
        }
        return;
      }
    }
    // While the source is loading, the engine would drop the seek. Queue the
    // absolute target (the barrier above may already have queued a chapter
    // jump); the load's own position is used as the reference.
    if (_isLoadingNewItem) {
      _queueLoadSeek(
        newPosS,
        apply: () => seekTo(
          Duration(milliseconds: (newPosS * 1000).round()),
          logAs: PlaybackEventType.skipForward,
          logDetail: '+${adjusted}s',
        ),
      );
      return;
    }
    // A partial download's local audio ends at the download boundary. A forward
    // skip that would cross it has no audio to land on (the engine's seek past
    // the concatenation clamps to the end and "jumps" into the next chapter's
    // title). Online the book continues as a stream at the target; offline,
    // park at the boundary instead.
    final coverageEnd = _localCoverageEndSec;
    if (_isPartialLocalPlay &&
        coverageEnd != null &&
        newPosS > coverageEnd - 0.5) {
      if (await _streamContinueIfUncovered(newPosS)) return;
      await _parkAtPartialBoundary();
      return;
    }
    // VBR sources without a seek index coarse-seek SHORT of the target (a
    // 10s skip landing 4s in). Measure the landing and re-request the
    // shortfall, bounded so a repair can never run far past the target. At
    // the book's tail the clamp makes every request land short — repairing
    // there would just re-seek the clamped end twice, so skip the loop.
    // With the barrier ON the bound also stops just short of the next
    // chapter, so an undershoot-repair can't spill a within-chapter skip
    // past the boundary.
    var repairClamp = newPosS + 30.0;
    if (forwardBarrier &&
        nextChapterStart != null &&
        nextChapterStart - 1.0 < repairClamp) {
      repairClamp = nextChapterStart - 1.0;
    }
    if (_totalDuration <= 0 || newPosS < _totalDuration - 1.0) {
      await _seekAbsoluteAlignedRepair(newPosS, clampMaxSec: repairClamp);
    } else {
      await _seekAbsolute(newPosS);
    }
    _logEvent(PlaybackEventType.skipForward, detail: '+${adjusted}s');
    debugPrint('[Service] skipForward done — playing=${_player!.playing}');
  }

  Future<void> skipBackward([int seconds = 10]) async {
    if (_player == null) return;
    if (_offlineRemoteTransportBlocked('skipBackward')) return;
    _resetStuckDetection();
    if (!_player!.playing) _seekedWhilePaused = true;
    // Skip amounts are CONTENT seconds: the position moves exactly the
    // configured amount of audio, regardless of playback speed.
    final adjusted = seconds;
    _lastUserSeekTime = DateTime.now();
    final posS = position.inMilliseconds / 1000.0;
    final targetS = posS - adjusted;

    // Find current chapter start (used by the barrier below AND as the floor
    // the plain-path seek may never retreat past).
    double chapterStart = 0;
    int? chapterIdx;
    if (_chapters.isNotEmpty) {
      for (int i = _chapters.length - 1; i >= 0; i--) {
        final s = (_chapters[i]['start'] as num?)?.toDouble() ?? 0;
        if (s <= posS + 0.5) {
          chapterStart = s;
          chapterIdx = i;
          break;
        }
      }
    }
    final chapterBarrier = await PlayerSettings.getSkipChapterBarrier();
    // ENGINE-ANCHORED barrier rewind (multi-file books).
    //
    // Resolving the chapter's METADATA start through the absolute timeline
    // re-derives it from the per-file duration estimates, whose error
    // compounds across files: a heavily drifted book resolves "the current
    // chapter's start" into an EARLIER file entirely, and even the barrier
    // snap then lands in the previous chapter's tail. Anchor to the ENGINE's
    // current file instead: the chapter being rewound inside is playing there
    // NOW, so the rewind must simply never retreat past that file's start.
    // Where the chapter begins inside the file:
    //  - chapter index == file index (chapter-per-file structure): the file
    //    start IS the chapter start — floor 0, drift-immune;
    //  - otherwise (chapters inside files): best-effort from the metadata
    //    delta (posS - chapterStart), clamped at the file start.
    // The anchor index is the ENGINE's LIVE value: a stale [_currentTrackIndex]
    // (a seek whose answer never came back) would anchor the rewind one file
    // early — the "rewind jumps to the previous chapter, stalls loading it,
    // then sits at its 0s" report.
    var anchorIdx = _currentTrackIndex;
    final liveIdx = _player?.currentIndex;
    if (liveIdx != null && liveIdx != anchorIdx) {
      debugPrint(
        '[Service] Rewind anchor: stale track index $anchorIdx -> '
        'engine live $liveIdx',
      );
      anchorIdx = liveIdx;
      _currentTrackIndex = liveIdx;
    }
    if (chapterBarrier &&
        !_isLoadingNewItem &&
        chapterIdx != null &&
        anchorIdx >= 0 &&
        anchorIdx < _trackStartOffsets.length - 1) {
      final trackStartOff = _trackStartOffsets[anchorIdx];
      final engineLocal = _player!.position.inMilliseconds / 1000.0;
      final double floorLocal;
      if (chapterIdx == anchorIdx) {
        floorLocal = 0; // chapter-per-file: file start == chapter start
      } else {
        floorLocal = (engineLocal - (posS - chapterStart))
            .clamp(0.0, double.infinity);
      }
      var localTarget = engineLocal - adjusted;
      var snapped = localTarget < floorLocal;
      if (snapped) localTarget = floorLocal;
      final absTarget = trackStartOff + localTarget;
      final floorAbs = trackStartOff + floorLocal;
      if (snapped) _disarmIntroForSameChapterRewind(posS, chapterStart);
      debugPrint(
        '[Service] Rewind anchored: engineLocal=${engineLocal.toStringAsFixed(1)}s '
        'adjusted=${adjusted}s target=${absTarget.toStringAsFixed(1)}s '
        '(track $anchorIdx, floor ${floorAbs.toStringAsFixed(1)}s, '
        'snap=$snapped)',
      );
      // Same barrier rules for the landing repair: the floor is the
      // chapter's file-local start, so a large coarse-seek error can't dig
      // the re-request into the previous chapter. The snapped chapter rides
      // the seek's own pin: a position tick during the engine switch would
      // otherwise resolve the landing (a hair before the metadata chapter
      // start) to the PREVIOUS chapter - that pushed its near-end progress to
      // the notification and left the bar stuck at full until the next state
      // push.
      await _seekAbsoluteAlignedRepair(
        absTarget,
        clampMaxSec: (absTarget - 30.0).clamp(floorAbs, double.infinity),
        backward: true,
        pinChapterIndex: snapped ? chapterIdx : null,
      );
      final landedIdx = _player?.currentIndex;
      final crossedToEarlierFile =
          landedIdx != null && landedIdx < anchorIdx;
      if (_player?.processingState == ProcessingState.ready) {
        final landed = position.inMilliseconds / 1000.0;
        if (landed < floorAbs - 0.5 || crossedToEarlierFile) {
          debugPrint(
            '[Service] Rewind landing ${landed.toStringAsFixed(1)}s '
            '(track $landedIdx) crossed the chapter barrier at '
            '${floorAbs.toStringAsFixed(1)}s - re-snapping',
          );
          await _seekAbsolute(
            floorAbs,
            chapterJump: snapped || floorLocal <= 0,
            pinChapterIndex: chapterIdx,
          );
        }
      }
      _logEvent(
        PlaybackEventType.skipBackward,
        detail: snapped
            ? 'snap to chapter start (engine-anchored)'
            : '-${adjusted}s (engine-anchored)',
      );
      return;
    }
    if (chapterBarrier && _chapters.isNotEmpty) {
      // Rewind would cross the chapter boundary - always snap to the current
      // chapter's start. The old "double-tap within 2s breaks through" escape
      // was removed: rapid rewind presses (tap-tap-tap to go back 20-30s)
      // routinely land within 2s, so the barrier was being crossed by accident
      // and the toggle could not be relied on. Crossing into the previous
      // chapter remains available via the dedicated previous-chapter button.
      if (targetS < chapterStart) {
        _disarmIntroForSameChapterRewind(posS, chapterStart);
        if (_isLoadingNewItem) {
          final reference = posS;
          _queueLoadSeek(
            chapterStart,
            apply: () async {
              await seekTo(
                Duration(milliseconds: (chapterStart * 1000).round()),
                logAs: PlaybackEventType.skipBackward,
                logDetail: 'snap to chapter start',
              );
              // Re-assert the same-chapter rewind disarm on the loaded player:
              // the start load resets the per-item skip flags.
              _disarmIntroForSameChapterRewind(reference, chapterStart);
            },
          );
          return;
        }
        // Treat this as a chapter jump: snap to the file boundary (the metadata
        // start can drift a fraction of a second into the PREVIOUS file, which
        // would otherwise land on the previous chapter's tail and show its
        // title with the bar near full) and pin the reported chapter to the
        // current one for the whole engine switch.
        await _seekAbsolute(
          chapterStart,
          chapterJump: true,
          pinChapterIndex: chapterIdx,
        );
        _logEvent(
          PlaybackEventType.skipBackward,
          detail: 'snap to chapter start',
        );
        return;
      }
    }

    var n = targetS < 0 ? 0.0 : targetS;
    if (_isLoadingNewItem) {
      _queueLoadSeek(
        n,
        apply: () => seekTo(
          Duration(milliseconds: (n * 1000).round()),
          logAs: PlaybackEventType.skipBackward,
          logDetail: '-${adjusted}s',
        ),
      );
      return;
    }
    if (n > 0.5) {
      // VBR coarse seeks can stop short of the target (closer to where the
      // rewind started than asked). Measure the landing and re-request the
      // shortfall. Two barrier rules apply even though the target itself
      // stays inside the chapter:
      //  - the repair's floor is the current chapter's start, so a large
      //    first-seek error can't dig the re-request ACROSS the boundary
      //    (this was the "rewind no longer respects the chapter barrier"
      //    regression);
      //  - the FIRST landing can overshoot across it too — re-snap with the
      //    barrier semantics when it does.
      final floorSec =
          chapterBarrier && _chapters.isNotEmpty ? chapterStart : 0.0;
      await _seekAbsoluteAlignedRepair(
        n,
        clampMaxSec: (n - 30.0).clamp(floorSec, double.infinity),
        backward: true,
      );
      if (floorSec > 0 && _player?.processingState == ProcessingState.ready) {
        final landed = position.inMilliseconds / 1000.0;
        if (landed < floorSec - 0.5) {
          debugPrint(
            '[Service] Rewind landing ${landed.toStringAsFixed(1)}s crossed '
            'the chapter barrier at ${floorSec.toStringAsFixed(1)}s - '
            're-snapping to the chapter start',
          );
          _disarmIntroForSameChapterRewind(posS, floorSec);
          await _seekAbsolute(
            floorSec,
            chapterJump: true,
            pinChapterIndex: chapterIdx,
          );
        }
      }
    } else {
      await _seekAbsolute(n);
    }
    _logEvent(PlaybackEventType.skipBackward, detail: '-${adjusted}s');
  }

  Future<void> skipToNextChapter() =>
      _chapterJumpThenAutoPlay(_skipToNextChapterImpl);

  /// Continue a PARTIAL-download play past its last local audio by switching
  /// to a streaming session at [targetSec] — the standard playItem entry, so
  /// progress reporting, session ids and the media widget all follow the
  /// regular stream model. Only when the target has NO local audio (a gap or
  /// past coverage) AND the server is reachable; otherwise the caller keeps its
  /// local-session fallback (offline park) untouched. Returns true when the
  /// switch actually happened.
  Future<bool> _streamContinueIfUncovered(double targetSec) async {
    // Only meaningful while a PARTIAL download confines the audio: a full
    // stream already covers every position, so a seek must stay in-session —
    // a "continue" here would tear the running session down and start a fresh
    // one (loading gap + re-fetched track URLs), and the stale pre-teardown
    // position (often the book's tail) would flash the LAST chapter's title
    // while the new session buffers.
    if (!_isPartialLocalPlay) return false;
    if (targetSec < 0 || _positionCoveredLocally(targetSec)) return false;
    final api = _api;
    if (api == null || _offline) return false;
    final itemId = _currentItemId;
    if (itemId == null || _player == null) return false;
    // After the hand-off the session is a full-book STREAM: navigation must
    // stop being confined to the downloaded subset.
    _localPlayableChapterIndices = const [];
    // The hand-off is a session restart: pin the seek target (like a real
    // seek does) so the loading gap resolves the chapter from the intended
    // target instead of the stale pre-teardown position.
    _lastSeekTargetSeconds = targetSec;
    _lastSeekTime = DateTime.now();
    debugPrint(
      '[Service] Jump target ${targetSec.toStringAsFixed(1)}s has no local '
      'audio — continuing this book via streaming',
    );
    final err = await _playFromServer(
      api,
      itemId,
      _currentTitle ?? '',
      _currentAuthor ?? '',
      _currentCoverUrl,
      _totalDuration,
      _chapters,
      targetSec,
      forceStartTime: true,
    );
    return err == null;
  }

  /// Partial-download guard for a chapter jump to [targetSec].
  ///
  /// Returns null when the caller may seek locally (target has local audio,
  /// or this isn't a partial play). Returns true when the jump was HANDLED
  /// here - the target sits outside the downloaded range and the book was
  /// continued via streaming. Returns false when the jump must be ABORTED
  /// (offline / no API): a raw seek into that gap would dead-seek or clamp
  /// into a neighbouring file and phantom-complete with the wrong chapter.
  Future<bool?> _partialJumpGate(double targetSec) async {
    if (!_isPartialLocalPlay) return null;
    if (await _streamContinueIfUncovered(targetSec)) return true;
    if (_positionCoveredLocally(targetSec)) return null;
    debugPrint(
      '[Service] Chapter jump to ${targetSec.toStringAsFixed(1)}s blocked - '
      'outside the downloaded range and no stream available',
    );
    return false;
  }

  /// Chapter to report while parked at [coverageEnd] (the end of the last
  /// downloaded file): the chapter the LAST DOWNLOADED FILE belongs to,
  /// anchored on that file's own start. Preferring the playable subset's last
  /// entry misfires when metadata-vs-file drift leaves the NEXT chapter's
  /// metadata start a few seconds inside the last file — that chapter is then
  /// "covered" by the subset even though its audio isn't on disk, so the
  /// boundary would report (and play() restart into) a chapter with no audio:
  /// title on the undownloaded episode, a silent seek that instantly completes
  /// again, position pinned on the next chapter's start.
  int? _boundaryParkedChapterIdx(double coverageEnd) {
    if (_chapters.isEmpty) return null;
    double startOf(int i) => ChapterLookup.metaStart(_chapters, i);
    // 0) The downloader's own 1:1 track→chapter map (when the session records
    //    one): the LAST entry IS the chapter the last downloaded file carries
    //    — recorded when the file was fetched, immune to any metadata-vs-file
    //    drift that makes the position math below ambiguous.
    final map = _localTrackChapterIdx;
    if (map.isNotEmpty) {
      final mapped = map[map.length - 1];
      if (mapped >= 0 && mapped < _chapters.length) {
        debugPrint(
          '[Player] Boundary chapter from track map: idx=$mapped '
          '"${_chapters[mapped]['title']}" '
          '(coverageEnd=${coverageEnd.toStringAsFixed(1)}s)',
        );
        return mapped;
      }
    }
    // 1) The chapter containing the last file's start IS the chapter that file
    //    carries, whatever the drift did to later chapter starts. Only require
    //    real audio behind the boundary here — NOT that the chapter's own
    //    metadata start be file-covered: a metadata start drifting before its
    //    file's start would reject the file's OWN chapter and fall through to
    //    the NEXT (undownloaded) one below.
    final nTracks = _trackStartOffsets.length - 1;
    if (nTracks >= 1) {
      final anchor = ChapterLookup.indexAtWithGrace(
        _chapters,
        _trackStartOffsets[nTracks - 1] + 0.5,
        _totalDuration,
      );
      if (anchor != null && anchor >= 0 && anchor < _chapters.length) {
        if (coverageEnd - startOf(anchor) >= 5.0) return anchor;
      }
    }
    // 2) Fallback: last playable chapter that still has real audio behind it.
    final playable = _localPlayableChapterIndices;
    for (var k = playable.length - 1; k >= 0; k--) {
      if (coverageEnd - startOf(playable[k]) >= 5.0) return playable[k];
    }
    if (playable.isNotEmpty) return playable.first;
    // 3) No subset (single downloaded track): plain lookup a hair before the
    //    boundary, so the boundary itself can't resolve to the next chapter.
    return _resolveChapterIndex(coverageEnd - 1.0);
  }

  /// Chapter override for any position-based chapter resolution while a
  /// partial download sits at its boundary. Non-null as soon as [posSec]
  /// reaches the download boundary — NOT only once the async park has
  /// completed: the engine lands on the boundary (and a scrub clears the
  /// parked flag while its own park is still in flight) several operations
  /// BEFORE [_parkedAtBoundary] flips, and during that window every raw
  /// containment resolves to the next (undownloaded) chapter — the visible
  /// title flash this exists to prevent.
  int? _boundaryChapterOverride(double posSec) {
    if (_chapters.isEmpty) return null;
    if (_parkedAtBoundary) {
      final i = _parkedBoundaryChapterIdx;
      if (i != null && i >= 0 && i < _chapters.length) return i;
    }
    final cEnd = _localCoverageEndSec;
    if (_isPartialLocalPlay &&
        cEnd != null &&
        posSec >= cEnd - 0.5 &&
        posSec <= cEnd + 60.0) {
      final i = _boundaryParkedChapterIdx(cEnd);
      if (i != null && i >= 0 && i < _chapters.length) return i;
    }
    return null;
  }

  /// Shared park bookkeeping at [coverageEnd]. Resolves the parked chapter
  /// BEFORE setting the flag — [_boundaryParkedChapterIdx]'s last-resort
  /// fallback reads the parked flag back through [_resolveChapterIndex], so
  /// resolving after would hand back a stale index on a re-park. Sets the
  /// flags, pushes the chapter to the lock screen right now (the position
  /// tick that would normally correct the title is about to be cancelled by
  /// the completion path) and logs the whole decision — the completion path
  /// is the one shot at that log, its subs are cancelled.
  int? _setParkedAtBoundary(double coverageEnd) {
    final parkedIdx = _boundaryParkedChapterIdx(coverageEnd);
    _parkedAtBoundary = true;
    _parkedBoundaryChapterIdx = parkedIdx;
    debugPrint(
      '[Player] Parked at download boundary: idx=$parkedIdx '
      '"${parkedIdx != null && parkedIdx < _chapters.length ? (_chapters[parkedIdx]['title'] ?? '') : ''}" '
      'coverageEnd=${coverageEnd.toStringAsFixed(1)}s '
      'offsets=$_trackStartOffsets '
      'playable=$_localPlayableChapterIndices '
      'trackMap=$_localTrackChapterIdx',
    );
    if (parkedIdx != null) _pinChapterLatch(parkedIdx);
    return parkedIdx;
  }

  /// Park at the end of a partial download's local range (used by forward
  /// skips that would cross it): pause and save the boundary position instead
  /// of seeking into chapters whose audio isn't on disk. Unlike the natural
  /// completion path this keeps the position/completion listeners alive - the
  /// session is still live and the user can seek back / play on.
  Future<void> _parkAtPartialBoundary() async {
    if (!_isPartialLocalPlay) return;
    final coverageEnd = _localCoverageEndSec;
    if (coverageEnd == null || _player == null) return;
    debugPrint(
      '[Player] Download boundary (${coverageEnd.toStringAsFixed(1)}s) '
      'reached by skip — parking instead of crossing into non-downloaded audio',
    );
    _logEvent(PlaybackEventType.pause, detail: 'Download boundary reached');
    _seekedWhilePaused = false;
    await _player!.pause();
    _setParkedAtBoundary(coverageEnd);
    _lastKnownPositionSec = coverageEnd;
    await _saveProgressLocal(
      Duration(milliseconds: (coverageEnd * 1000).round()),
    );
    notifyListeners();
  }

  /// Chapter indices of the CURRENT item whose audio is really on disk, read
  /// from the download service's cached session rather than the player's
  /// offsets — a streaming session paints its offsets across the whole book,
  /// so [_positionCoveredLocally] would call every chapter "covered". Returns
  /// null when the item has no usable local session.
  List<int>? _downloadedChapterSubset() {
    final itemId = _currentItemId;
    if (itemId == null || _chapters.isEmpty) return null;
    final cachedJson = _downloadService.getCachedSessionData(itemId);
    if (cachedJson == null) return null;
    if (identical(cachedJson, _subsetMemoJson) &&
        identical(_chapters, _subsetMemoChapters)) {
      return _subsetMemo;
    }
    try {
      final session = jsonDecode(cachedJson) as Map<String, dynamic>;
      final audioTracks = session['audioTracks'] as List<dynamic>?;
      if (audioTracks == null || audioTracks.isEmpty) return null;
      final absoluteStarts = (session['trackStartOffsets'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble())
          .toList();
      final starts = <double>[];
      if (absoluteStarts != null &&
          absoluteStarts.length == audioTracks.length) {
        starts.addAll(absoluteStarts);
      } else {
        var acc = 0.0;
        for (final t in audioTracks) {
          starts.add(acc);
          acc += (t['duration'] as num?)?.toDouble() ?? 0;
        }
      }
      final subset = <int>[];
      for (var i = 0; i < _chapters.length; i++) {
        final s = ChapterLookup.metaStart(_chapters, i);
        for (var t = 0; t < audioTracks.length; t++) {
          final d = (audioTracks[t]['duration'] as num?)?.toDouble() ?? 0;
          final end = starts[t] + d;
          if (s >= starts[t] - 0.5 && s < end - 0.5) {
            subset.add(i);
            break;
          }
        }
      }
      _subsetMemoJson = cachedJson;
      _subsetMemoChapters = _chapters;
      _subsetMemo = subset;
      return subset;
    } catch (_) {
      return null;
    }
  }

  /// Offline + network source + [targetSec] inside a downloaded chapter of the
  /// current item: re-enter LOCAL playback from there (the full
  /// [playItem]/[_playFromLocal] path), so offline navigation lands on real
  /// audio and [_sourceIsNetwork] flips back. Returns whether the switch
  /// happened.
  Future<bool> _reenterLocalPlayIfCovered(double targetSec) async {
    if (!_offlineRemoteStream || targetSec < 0) return false;
    final itemId = _currentItemId;
    final api = _api;
    if (itemId == null || api == null) return false;
    final subset = _downloadedChapterSubset();
    if (subset == null || subset.isEmpty) return false;
    var covered = false;
    for (final i in subset) {
      final start = ChapterLookup.metaStart(_chapters, i);
      final nextStart = i + 1 < _chapters.length
          ? ((_chapters[i + 1] as Map)['start'] as num?)?.toDouble() ??
                _totalDuration
          : _totalDuration;
      if (targetSec >= start - 0.5 && targetSec < nextStart - 0.5) {
        covered = true;
        break;
      }
    }
    if (!covered) return false;
    debugPrint(
      '[Service] Offline: ${targetSec.toStringAsFixed(1)}s is a downloaded '
      'chapter — re-entering local playback',
    );
    final err = await playItem(
      api: api,
      itemId: itemId,
      title: _currentTitle ?? '',
      author: _currentAuthor ?? '',
      coverUrl: _currentCoverUrl,
      totalDuration: _totalDuration,
      chapters: _chapters,
      episodeId: _currentEpisodeId,
      episodeTitle: _currentEpisodeTitle,
      libraryId: _currentLibraryId,
      seriesId: _currentSeriesId,
      startTime: targetSec,
      forceStartTime: true,
      fromUi: true,
    );
    if (err == null) {
      debugPrint('[Service] Offline re-root into local playback succeeded');
      return true;
    }
    debugPrint('[Service] Offline re-root failed: $err');
    return false;
  }

  /// Prev/next among the DOWNLOADED chapters of the current item while the
  /// player is an offline remote stream. Picks the neighbouring downloaded
  /// chapter and re-roots into local playback there; at the ends of the
  /// download the press is a no-op (nothing more is available offline).
  Future<bool> _offlineChapterNav(bool back) async {
    final subset = _downloadedChapterSubset();
    if (subset == null || subset.isEmpty) {
      debugPrint(
        '[Service] Offline chapter nav: no downloaded chapters — staying put',
      );
      return false;
    }
    final posS = chapterResolvePosSec;
    double? target;
    if (back) {
      for (var k = subset.length - 1; k >= 0; k--) {
        final i = subset[k];
        final start = ChapterLookup.metaStart(_chapters, i);
        if (start < posS - 3.0) {
          target = start;
          break;
        }
      }
      target ??= ChapterLookup.metaStart(_chapters, subset.first);
    } else {
      for (final i in subset) {
        final start = ChapterLookup.metaStart(_chapters, i);
        if (start > posS + 1.0) {
          target = start;
          break;
        }
      }
      if (target == null) {
        debugPrint(
          '[Service] Offline chapter nav: at the last downloaded chapter — '
          'staying put',
        );
        return false;
      }
    }
    return _reenterLocalPlayIfCovered(target);
  }

  Future<bool> _skipToNextChapterImpl({double? referencePosSec}) async {
    if (_player == null || _chapters.isEmpty) return false;
    _resetStuckDetection();
    if (!_player!.playing) _seekedWhilePaused = true;
    // Resolve against the pending-start / active-seek target, NOT the raw
    // stream position: every chapter class here is its own audio file, so a
    // jump is a session upgrade during which `position` collapses to the stale
    // local offset (~0s) and next-chapter resolution would scan from chapter 0.
    final posS = referencePosSec ?? chapterResolvePosSec;
    // The engine silently ignores seeks while its source is loading. Record
    // the jump; the load applies it with the frozen reference (recomputing
    // from the loaded position would skip a second chapter).
    if (_isLoadingNewItem) {
      final target = ChapterLookup.nextSkipTarget(
        _chapters,
        posS,
        _totalDuration,
      );
      if (target == null || target.finishesItem) return false;
      _queueLoadSeek(
        target.seconds,
        apply: () => _skipToNextChapterImpl(referencePosSec: posS),
      );
      return true;
    }
    // Offline + network source: only the DOWNLOADED chapters exist. Step to
    // the next downloaded chapter by re-entering local playback; past the last
    // download the press is a no-op (no more offline audio).
    if (_offlineRemoteStream) return _offlineChapterNav(false);
    final playable = _navPlayableChapters;
    Future<void> jumpTo(double start) async {
      // Crossing into a genuinely DIFFERENT chapter keeps the intro skip armed -
      // pre-jump straight to the intro-skip point so the chapter's opening words
      // aren't briefly played while the skip waits for the first post-landing
      // position tick. Mirrors the prev-chapter handler.
      double? preJumpTarget;
      final chapterIdx = ChapterLookup.indexAtWithGrace(
        _chapters,
        start,
        _totalDuration,
      );
      if (chapterIdx != null) {
        preJumpTarget = await _crossChapterIntroSkipTarget(chapterIdx);
      }
      if (preJumpTarget != null) {
        await _seekAbsoluteAlignedRepair(
          preJumpTarget,
          clampMaxSec: preJumpTarget + 8.0,
          chapterJump: false,
          pinChapterIndex: chapterIdx,
        );
      } else {
        await _seekAbsolute(
          start,
          // Snap to the file boundary when landing exactly on the chapter
          // start; an intro-skip pre-jump is offset into the chapter and stays
          // precise.
          chapterJump: true,
          pinChapterIndex: null,
        );
      }
      _logEvent(
        PlaybackEventType.seek,
        detail: preJumpTarget != null
            ? 'next chapter to ${preJumpTarget.toStringAsFixed(1)}s (intro skip)'
            : 'next chapter',
      );
      notifyListeners();
    }

    if (playable.isNotEmpty) {
      for (final i in playable) {
        final s = ChapterLookup.metaStart(_chapters, i);
        if (s > posS + 1.0) {
          debugPrint('[Service] skipToNextChapter → $s s');
          await jumpTo(s);
          return true;
        }
      }
      // End of the DOWNLOADED content (not the book). Online, continue the
      // book by streaming from the next chapter — a real continuation, not a
      // dead seek into audio that isn't local (phantom completion showing the
      // wrong chapter's title). Offline, the chapter boundary has no audio:
      // never cross it (no seek into the next chapter, no park at the file end
      // that re-labels the position as the next chapter) — the jump is simply a
      // no-op.
      final streamTarget = ChapterLookup.nextSkipTarget(
        _chapters,
        posS,
        _totalDuration,
      );
      if (streamTarget != null && streamTarget.finishesItem) {
        // Downloaded content reached the END OF THE BOOK itself — genuine
        // completion; the completion path owns the "finished" state.
        debugPrint(
          '[Service] skipToNextChapter → end of the whole book at '
          '${streamTarget.seconds.toStringAsFixed(1)}s',
        );
        _lastKnownPositionSec = streamTarget.seconds;
        _logEvent(PlaybackEventType.seek, detail: 'next chapter to end');
        await _onPlaybackComplete(userRequested: true);
        return false;
      }
      if (streamTarget != null &&
          await _streamContinueIfUncovered(streamTarget.seconds)) {
        return true;
      }
      debugPrint(
        '[Service] skipToNextChapter → offline (or no stream) past the local '
        'end — staying put (last playable chapter ${playable.last})',
      );
      return false;
    }
    final target = ChapterLookup.nextSkipTarget(
      _chapters,
      posS,
      _totalDuration,
    );
    if (target == null) return false;
    if (target.finishesItem) {
      debugPrint(
        '[Service] skipToNextChapter → end at ${target.seconds.toStringAsFixed(1)}s',
      );
      _lastKnownPositionSec = target.seconds;
      _logEvent(PlaybackEventType.seek, detail: 'next chapter to end');
      // NOT a chapter jump: this is the end of the BOOK. Whether playback
      // continues (autoplay-next-book) is the completion path's decision, so
      // report "didn't jump" and leave _onPlaybackComplete in charge.
      await _onPlaybackComplete(userRequested: true);
      return false;
    }
    debugPrint(
      '[Service] skipToNextChapter → ${target.seconds.toStringAsFixed(1)}s',
    );
    // A PARTIAL download has a boundary: a target past it continues via
    // streaming (online) or stays put (offline); a target within the local
    // range lands in-session below. A FULL stream covers every position, so
    // the plain in-session seek below is always right — it must never consult
    // the "no local audio" check (a stream whose track map doesn't span the
    // target would falsely re-start the whole session).
    if (_isPartialLocalPlay) {
      if (await _streamContinueIfUncovered(target.seconds)) return true;
      if (!_positionCoveredLocally(target.seconds)) {
        debugPrint(
          '[Service] skipToNextChapter → target has no local audio and no '
          'stream available — staying put',
        );
        return false;
      }
    }
    await jumpTo(target.seconds);
    return true;
  }

  Future<void> skipToPreviousChapter() =>
      _chapterJumpThenAutoPlay(_skipToPreviousChapterImpl);

  Future<bool> _skipToPreviousChapterImpl({double? referencePosSec}) async {
    if (_player == null || _chapters.isEmpty) return false;
    _resetStuckDetection();
    if (!_player!.playing) _seekedWhilePaused = true;
    // Same session-upgrade caveat as skipToNextChapter: every chapter is its
    // own audio file, so a rewind is a session upgrade during which `position`
    // collapses to the stale local offset (~0s). Reading it raw would resolve
    // to chapter 0 and fall through to a seek(0) — "jumps to chapter one".
    // Resolve against the pending-start / active-seek target instead.
    final posS = referencePosSec ?? chapterResolvePosSec;
    // A source that is still loading ignores seeks. Queue the jump against the
    // position the user was at; the deferred run recomputes the exact target
    // from that frozen reference instead of the loaded source's own position.
    if (_isLoadingNewItem) {
      // Hint only: the deferred run re-reads the direct/iterative setting and
      // computes the exact target from the frozen reference.
      double hint = 0.0;
      for (int i = _chapters.length - 1; i >= 0; i--) {
        final s = ChapterLookup.metaStart(_chapters, i);
        if (s < posS - 3.0) {
          hint = s;
          break;
        }
      }
      _queueLoadSeek(
        hint,
        apply: () => _skipToPreviousChapterImpl(referencePosSec: posS),
      );
      return true;
    }
    // Offline + network source: only the DOWNLOADED chapters exist. Step to
    // the previous downloaded chapter by re-entering local playback; before
    // the first download the press restarts it there.
    if (_offlineRemoteStream) return _offlineChapterNav(true);
    final playable = _navPlayableChapters;
    // Hoisted: both restart paths (direct-mode at the first chapter, iterative
    // mode at the very start) restart the same target.
    final restartStart = playable.isNotEmpty
        ? ChapterLookup.metaStart(_chapters, playable.first)
        : 0.0;
    final restartIdx = playable.isNotEmpty ? playable.first : null;
    final directJump = await PlayerSettings.getPrevChapterDirectJump();
    if (directJump) {
      // Direct mode: always jump straight to the previous PLAYABLE chapter
      // (for partial downloads) / previous chapter (full plays). At the first
      // chapter (or when the position isn't inside any chapter), restart.
      final currentIdx = ChapterLookup.indexAtWithGrace(
        _chapters,
        posS,
        _totalDuration,
      );
      int? prevIdx;
      if (playable.isNotEmpty) {
        for (final i in playable.reversed) {
          if (i < (currentIdx ?? -1)) {
            prevIdx = i;
            break;
          }
        }
      } else if (currentIdx != null && currentIdx > 0) {
        prevIdx = currentIdx - 1;
      }
      if (prevIdx != null) {
        final start = ChapterLookup.metaStart(_chapters, prevIdx);
        final gate = await _partialJumpGate(start);
        if (gate != null) return gate;
        debugPrint(
          '[Service] skipToPreviousChapter (direct) → chapter $prevIdx at ${start}s',
        );
        // Crossing into a genuinely DIFFERENT chapter keeps the intro skip
        // armed - pre-jump straight to the intro-skip point so the chapter's
        // opening words aren't briefly played while the skip waits for the
        // first post-landing position tick before jumping.
        final preJumpTarget = await _crossChapterIntroSkipTarget(prevIdx);
        if (preJumpTarget != null) {
          await _seekAbsoluteAlignedRepair(
            preJumpTarget,
            clampMaxSec: preJumpTarget + 8.0,
            chapterJump: false,
            pinChapterIndex: prevIdx,
          );
        } else {
          await _seekAbsolute(start, chapterJump: true, pinChapterIndex: null);
        }
        _logEvent(
          PlaybackEventType.seek,
          detail: preJumpTarget != null
              ? 'prev chapter (direct) to ${preJumpTarget.toStringAsFixed(1)}s (intro skip)'
              : 'prev chapter (direct)',
        );
        notifyListeners();
        return true;
      }
      // Restart: at the FIRST playable chapter (partial download) restart it,
      // not absolute 0 — chapter 0 may be an un-downloaded preview whose audio
      // isn't local. Full plays restart from their own chapter 0 as before.
      final gate = await _partialJumpGate(restartStart);
      if (gate != null) return gate;
      _disarmIntroForSameChapterRewind(posS, restartStart);
      await _seekAbsolute(
        restartStart,
        chapterJump: true,
        pinChapterIndex: restartIdx,
      );
      notifyListeners();
      return true;
    }
    // If more than 3s into current chapter, go to start of current chapter
    // Otherwise go to previous chapter. Full-book plays iterate the book's
    // chapters; partial-download plays iterate the playable subset only
    // (target indices are still full-book indices into `_chapters`).
    final ordered = playable.isNotEmpty ? playable : null;
    for (
      int k = ordered != null ? ordered.length - 1 : _chapters.length - 1;
      k >= 0;
      k--
    ) {
      final i = ordered != null ? ordered[k] : k;
      final start = ChapterLookup.metaStart(_chapters, i);
      if (start < posS - 3.0) {
        final gate = await _partialJumpGate(start);
        if (gate != null) return gate;
        debugPrint('[Service] skipToPreviousChapter → chapter $i at ${start}s');
        // Landing on our OWN chapter start is a deliberate rewind to re-hear
        // the opening - the intro skip must not fire there (it would drag the
        // position forward again and lock prev-navigation in a bounce loop).
        // Crossing into a genuinely DIFFERENT chapter keeps the skip armed so
        // it fires once, as requested.
        final disarmedSameChapter = _disarmIntroForSameChapterRewind(
          posS,
          start,
        );
        // Crossing into a genuinely DIFFERENT chapter the intro skip stays
        // armed - pre-jump straight to the intro-skip point so the chapter's
        // opening words aren't briefly played while the skip waits for the
        // first post-landing position tick before jumping.
        double? preJumpTarget;
        if (!disarmedSameChapter) {
          preJumpTarget = await _crossChapterIntroSkipTarget(i);
        }
        if (preJumpTarget != null) {
          await _seekAbsoluteAlignedRepair(
            preJumpTarget,
            clampMaxSec: preJumpTarget + 8.0,
            chapterJump: false,
            pinChapterIndex: i,
          );
        } else {
          await _seekAbsolute(start, chapterJump: true, pinChapterIndex: null);
        }
        _logEvent(
          PlaybackEventType.seek,
          detail: preJumpTarget != null
              ? 'prev chapter to ${preJumpTarget.toStringAsFixed(1)}s (intro skip)'
              : 'prev chapter',
        );
        notifyListeners();
        return true;
      }
    }
    // If at the very start, seek to the first playable chapter (partial
    // download) or 0 (full play). Chapter 0 may be an un-downloaded preview,
    // so a partial download restarts its own first chapter, not absolute 0.
    final gate = await _partialJumpGate(restartStart);
    if (gate != null) return gate;
    _disarmIntroForSameChapterRewind(posS, restartStart);
    await _seekAbsolute(
      restartStart,
      chapterJump: true,
      pinChapterIndex: restartIdx,
    );
    notifyListeners();
    return true;
  }

  /// Applies the paused-jump auto-play policy around a chapter jump.
  ///
  /// Tapping a chapter in the sheet, or a prev/next chapter button, while the
  /// player is paused almost always means "I want to hear this one" - but the
  /// jumps themselves only reposition, so the player used to sit there paused
  /// and the tap looked like it did nothing audible. [PlayerSettings
  /// .getChapterJumpAutoPlay] turns the resume on (default) or keeps the
  /// reposition-only behaviour for lining a chapter up before starting.
  ///
  /// The seek already recorded `_seekedWhilePaused`, so resuming through [play]
  /// takes the "the user placed this position" path: no auto-rewind into the
  /// previous chapter's tail, no server-position adoption overriding the jump.
  ///
  /// [jump] reports whether it actually seeked, so a no-op - no chapters, no
  /// next chapter, or next-past-the-end - can't be the thing that starts
  /// playback.
  Future<void> _chapterJumpThenAutoPlay(Future<bool> Function() jump) async {
    // Offline mode is handled INSIDE each jump (skipToNext/PreviousChapter and
    // seekToChapterIndex re-enter local playback for downloaded chapters and
    // no-op otherwise), so a blanket block here would also wall off the
    // downloaded chapters that are perfectly playable offline.
    final wasPaused = _player != null && !_player!.playing;
    final wasLoading = _isLoadingNewItem;
    if (!await jump()) return;
    if (wasLoading || _isLoadingNewItem) {
      // The in-flight start will play on its own; a load-only start ends
      // paused, so remember the pause-jump auto-play policy for load end.
      if (wasPaused && await PlayerSettings.getChapterJumpAutoPlay()) {
        if (_isLoadingNewItem) {
          _pendingLoadAutoPlay = true;
        } else if (_player != null && !_player!.playing) {
          await play(logDetail: 'chapter jump from paused', fromUi: true);
        }
      }
      return;
    }
    if (!wasPaused || _player == null || _player!.playing) return;
    if (!await PlayerSettings.getChapterJumpAutoPlay()) return;
    debugPrint(
      '[Service] Chapter jump made from a paused player → resuming playback',
    );
    await play(logDetail: 'chapter jump from paused', fromUi: true);
  }

  /// Returns true when the previous-chapter press (or chapter-start snap in
  /// skipBackward) lands back on the start of the SAME chapter the user is
  /// already in: the intro skip is disarmed and must not fire. Returns false
  /// when the landing is a genuinely DIFFERENT chapter - the skip re-arms via
  /// the normal entry-change in [_maybeSkipChapterIntroOutro].
  bool _disarmIntroForSameChapterRewind(double fromPosSec, double arrivalSec) {
    if (_chapters.isEmpty) return false;
    final fromIdx = ChapterLookup.indexAtWithGrace(
      _chapters,
      fromPosSec,
      _totalDuration,
    );
    final toIdx = ChapterLookup.indexAtWithGrace(
      _chapters,
      arrivalSec,
      _totalDuration,
    );
    if (fromIdx == null || fromIdx != toIdx) {
      _disarmRewindChapterIdx = null;
      _disarmRewindUntil = null;
      return false;
    }
    _skipEntryChapterIdx = toIdx;
    _introSkippedThisEntry = true;
    _outroSkippedThisEntry = false;
    // Keep the disarm intent for a short window even if the upcoming track
    // swap re-keys the item/episode and wipes the per-item flags above.
    _disarmRewindChapterIdx = toIdx;
    _disarmRewindUntil = DateTime.now().add(const Duration(seconds: 5));
    // Same suppression the manual scrub relies on (see _maybeSkipChapterIntroOutro):
    // no auto-skip may override a deliberate rewind to the chapter's own start.
    _lastUserSeekTime = DateTime.now();
    debugPrint(
      '[Service] ChapterSkip Same-chapter rewind to ${arrivalSec.toStringAsFixed(1)}s (idx $toIdx) — intro stays played, skip disarmed for this entry',
    );
    return true;
  }

  // ── Chapter skip: file-timeline chapter bounds ────────────────────────────
  //
  // The player reports and seeks in the FILE timeline: `position` is
  // track-relative plus _trackStartOffsets[currentTrack] (see [position]), and
  // _seekAbsolute converts an absolute target back into (track, offset). The
  // `start`/`end` fields in _chapters are a SEPARATE timeline that drifts away
  // from the file timeline by a few seconds once a book has been split and
  // re-encoded - the same drift already documented for chapter jumps at
  // [_resolveAbsolutePosition].
  //
  // The skip windows used to compare a FILE-timeline position against
  // METADATA-timeline boundaries, so the drift was paid twice: the trigger
  // fired at the wrong moment AND the resulting target was re-interpreted in
  // the other coordinate system. Measured on a 1:1 book whose metadata ran
  // behind the real audio, an "intro 20s" skip advanced only 16s and an
  // "outro 7s" skip fired with 5s still audible - exactly the reported numbers.
  //
  // Everything below therefore works in the file timeline, where chapter bounds
  // are exact by construction:
  //   chapter i starts at the start of the FILE holding its metadata start
  //   chapter i ends   at the start of the FILE holding chapter i+1's start
  // A single-file book has only one timeline, so its metadata is already exact
  // and is returned verbatim. The math itself lives in ChapterLookup so it can
  // be unit-tested without spinning up just_audio.

  /// Whether chapter bounds must be read from the file timeline. Multi-file
  /// books are the only ones where the two timelines can disagree.
  bool get _useFileTimelineBounds =>
      ChapterLookup.useFileTimeline(_trackStartOffsets, _trackDurations);

  double _chapterMetaStart(int i) => ChapterLookup.metaStart(_chapters, i);

  // File-timeline chapter bounds, rebuilt only when the inputs change. The skip
  // check runs on every position tick (and on a 120ms poll inside the outro
  // window), so recomputing the bounds there cost several full track scans per
  // tick; see [ChapterLookup.buildFileBounds].
  ({List<double> starts, List<double> ends})? _chapterBoundsCache;
  List<dynamic>? _chapterBoundsChapters;
  List<double>? _chapterBoundsOffsets;
  List<double>? _chapterBoundsDurations;
  double? _chapterBoundsTotalDuration;
  int? _chapterBoundsCount;

  ({List<double> starts, List<double> ends}) get _chapterBounds {
    final cached = _chapterBoundsCache;
    // _chapters is always replaced wholesale rather than mutated in place, so
    // reference identity plus length is a sufficient generation check.
    if (cached != null &&
        identical(_chapterBoundsChapters, _chapters) &&
        identical(_chapterBoundsOffsets, _trackStartOffsets) &&
        identical(_chapterBoundsDurations, _trackDurations) &&
        _chapterBoundsTotalDuration == _totalDuration &&
        _chapterBoundsCount == _chapters.length) {
      return cached;
    }
    final built = ChapterLookup.buildFileBounds(
      chapters: _chapters,
      trackStartOffsets: _trackStartOffsets,
      trackDurations: _trackDurations,
      totalDuration: _totalDuration,
    );
    _chapterBoundsCache = built;
    _chapterBoundsChapters = _chapters;
    _chapterBoundsOffsets = _trackStartOffsets;
    _chapterBoundsDurations = _trackDurations;
    _chapterBoundsTotalDuration = _totalDuration;
    _chapterBoundsCount = _chapters.length;
    return built;
  }

  /// Bounds of chapter [i] in the timeline the player reports and seeks in.
  ({double start, double end}) _chapterSkipBounds(int i) {
    final bounds = _chapterBounds;
    if (i < 0 || i >= bounds.starts.length) {
      return (start: 0, end: _totalDuration);
    }
    return (start: bounds.starts[i], end: bounds.ends[i]);
  }

  /// Chapter index for [posSec], refined from the metadata [hint] into the file
  /// timeline the position actually lives on. Near a boundary the two can
  /// disagree by one chapter, and the outro window is half-open, so a stale
  /// index would immediately satisfy `end - pos < outroSkip` at the very top of
  /// a chapter and jump the listener straight past it.
  int _chapterSkipIndexAt(double posSec, int hint) {
    if (!_useFileTimelineBounds) return hint;
    final bounds = _chapterBounds;
    return ChapterLookup.indexAtPrecomputed(
      starts: bounds.starts,
      ends: bounds.ends,
      hint: hint,
      posSec: posSec,
    );
  }

  /// For a genuinely different-chapter arrival, pre-computes the chapter's
  /// intro-skip target so the previous-chapter press lands directly at
  /// chapterStart + introSkip instead of playing the opening words and then
  /// jumping once the first post-landing position tick arrives. Mirrors the
  /// entry-change snapshot in [_maybeSkipChapterIntroOutro]: the same per-item
  /// settings are used and the same in-chapter clamp applies (at least 1s of
  /// content must remain after the target). Returns null when the normal skip
  /// wouldn't fire anyway (disabled, intro=0, or the chapter is too short).
  ///
  /// The bounds come from [_chapterSkipBounds] rather than from the caller's
  /// metadata start, so the target is expressed in the same timeline the seek
  /// will be issued in.
  Future<double?> _crossChapterIntroSkipTarget(int chapterIdx) async {
    if (chapterIdx < 0 || chapterIdx >= _chapters.length) return null;
    final settings = await ChapterSkipSettings.loadForItem(_mediaItemKey);
    if (!settings.enabled || settings.introSkipSeconds <= 0) return null;
    final bounds = _chapterSkipBounds(chapterIdx);
    final target = bounds.start + settings.introSkipSeconds.toDouble();
    if (bounds.end - target < 1.0) return null;
    debugPrint(
      '[Service] ChapterSkip Prev-chapter pre-jump → chapter $chapterIdx at ${bounds.start.toStringAsFixed(1)}s → ${target.toStringAsFixed(1)}s (intro ${settings.introSkipSeconds}s)',
    );
    return target;
  }

  /// Intro-skip pre-jump for the AUTOMATIC chapter transition.
  ///
  /// Every deliberate navigation already lands straight on the intro-skip point
  /// via [_crossChapterIntroSkipTarget]. An automatic advance on a 1:1 book was
  /// the one crossing with nothing armed: it is a bare track flip issued by
  /// AVQueuePlayer, so it never seeks and never reaches the pre-jump code. The
  /// new track reports position 0, `position` maps that to exactly
  /// `chapterStart`, and the `posSec > chapterStart` test in
  /// [_maybeSkipChapterIntroOutro] rejects an exact hit - so the chapter's
  /// opening words played until the next position-stream tick arrived. That
  /// tick window is what made it audible as a stray sound effect or a word or
  /// two before the skip yanked forward.
  ///
  /// Deliberately seeks and nothing else: no `_lastUserSeekTime` (this is not a
  /// user action, and faking one would suppress the skip for 3s) and no
  /// entry-flag bookkeeping. If this seek fails, the tick-driven skip still runs
  /// normally, whereas pre-marking the entry as handled would let the entire
  /// intro play out.
  Future<void> _autoAdvanceIntroSkip(int chapterIdx) async {
    final introTarget = await _crossChapterIntroSkipTarget(chapterIdx);
    // Re-check after the settings await: the item can be swapped out while
    // that round-trips, and a stale target would seek into the wrong book.
    if (introTarget == null || _player == null || _isLoadingNewItem) return;
    final bounds = _chapterSkipBounds(chapterIdx);
    debugPrint(
      '[ChapterSkip] Auto-advance pre-jump → chapter $chapterIdx at '
      '${bounds.start.toStringAsFixed(1)}s → ${introTarget.toStringAsFixed(1)}s',
    );
    _resetStuckDetection();
    await _seekAbsoluteAlignedRepair(
      introTarget,
      clampMaxSec: bounds.end - 1.0,
      pinChapterIndex: chapterIdx,
    );
  }

  /// Seek that verifies the actual landing and re-seeks forward when the
  /// engine snapped to an earlier sync frame. Progressive audio (MP3/VBR over
  /// HTTP, coarse Xing TOCs) aligns seeks to the sync frame at-or-before the
  /// target, so an intro-skip jump to "chapterStart + introSkip" can land a
  /// few seconds early and the user hears more of the intro than configured.
  /// Each repair moves the request past the missed frame by the measured
  /// shortfall plus a 1s margin, so the next landing is the earliest sync
  /// frame AT or AFTER the true target (an overshoot of less than a frame is
  /// the correct semantic for "skip all of the intro"). Forward-only - the
  /// observed failure is always under-shooting, never over. Files with exact
  /// seek maps (M4B/M4A) land on the first try: the shortfall is ~0 and no
  /// repair runs, so those books get a single seek exactly as before.
  ///
  /// Only used by the chapter intro/outro skip path. Manual drags and precise
  /// seeks keep calling [_seekAbsolute] with its exact-position semantics.
  Future<void> _seekAbsoluteAlignedRepair(
    double absoluteSeconds, {
    required double clampMaxSec,
    double tolerance = 0.6,
    int maxPasses = 2,
    bool chapterJump = false,
    int? pinChapterIndex,
    // Repair direction. Forward (default) chases a seek that landed SHORT of
    // the target (VBR coarse-TOC seeking undershoots); backward chases one
    // that stopped before retreating the full amount. [clampMaxSec] bounds the
    // corrected request: an upper bound forward, a lower bound backward.
    bool backward = false,
  }) async {
    var request = absoluteSeconds;
    for (var pass = 0; pass <= maxPasses; pass++) {
      await _seekAbsolute(
        request,
        chapterJump: chapterJump,
        pinChapterIndex: pinChapterIndex,
      );
      // A multi-file session shift is still settling (or JustAudio returned
      // early during loading): position isn't the landed sample yet, so never
      // measure or repair against a garbage reading.
      if (_player?.processingState != ProcessingState.ready) break;
      final landed = position.inMilliseconds / 1000.0;
      if ((landed - absoluteSeconds).abs() > 30.0) break;
      if (backward) {
        final deviation = landed - absoluteSeconds;
        // Landed at-or-before the target (or within tolerance): good.
        if (deviation <= tolerance) break;
        final next = absoluteSeconds - deviation - 1.0;
        if (next <= clampMaxSec) break;
        debugPrint(
          '[SkipDebug] Backward seek repair: intended '
          '${absoluteSeconds.toStringAsFixed(1)}s landed '
          '${landed.toStringAsFixed(1)}s (over by ${deviation.toStringAsFixed(1)}s) '
          '-> re-request ${next.toStringAsFixed(1)}s',
        );
        request = next;
        continue;
      }
      // A fresh source/session swap reports its new track's file start (in-file
      // 0) as the current position until the first seek is applied to a
      // buffered frame. Reading that as a landed sample turns every intro-skip
      // seek into a bogus "short = whole request", and the +shortfall+1
      // re-request would overshoot past the intro (chapterStart + 2*intro + 1).
      // A real sync-frame undershoot (the only failure repair exists for) has
      // already left the track's start - a VBR coarse TOC never snaps a 20s
      // target back to frame 0. So a requested in-file offset larger than
      // tolerance that lands back on (or before) the track start means the seek
      // never took effect: bail out and trust the source's own start position
      // instead of compounding the stale reading into an overshoot.
      final trackStart =
          (_trackStartOffsets.isNotEmpty &&
              _currentTrackIndex < _trackStartOffsets.length)
          ? _trackStartOffsets[_currentTrackIndex]
          : 0.0;
      final requestedInFile = request - trackStart;
      if (requestedInFile > tolerance && landed - trackStart <= 0.05) break;
      final shortfall = request - landed;
      // Good enough: landed within tolerance of THIS request, or already at-or-
      // past the true target (a later pass's request grows, so the request-
      // relative shortfall alone would keep repairing a correct landing).
      if (shortfall <= tolerance || landed >= absoluteSeconds - tolerance) {
        break;
      }
      final next = absoluteSeconds + shortfall + 1.0;
      if (next >= clampMaxSec || clampMaxSec <= request) break;
      request = next;
      debugPrint(
        '[ChapterSkip] Seek repair: intended ${absoluteSeconds.toStringAsFixed(1)}s '
        'landed ${landed.toStringAsFixed(1)}s (short ${shortfall.toStringAsFixed(1)}s) '
        '-> re-request ${request.toStringAsFixed(1)}s',
      );
    }
  }

  /// Check and perform chapter intro/outro skip based on settings.
  /// Called on each position update when playing and chapters exist.
  ///
  /// One-shot per chapter: the intro/outro skip takes effect at most once for
  /// a given chapter index per item session. After it has been handled, re-
  /// entering that window (e.g. when the user rewinds back into a chapter) does
  /// NOT re-fire the skip, so navigating to a chapter start isn't dragged
  /// forward again. A skip is only performed when the jump is meaningful
  /// (>= 1s), otherwise the window is just marked handled - never an empty seek.
  /// Fast-poll (120ms) the chapter skip windows. Re-runs
  /// [_maybeSkipChapterIntroOutro] at a fine grain so both an intro leak and a
  /// boundary crossing are caught within ~one poll instead of a full
  /// position-stream period. The conditions inside that function stop and
  /// cancel it once the skips fire or the watch leaves the windows.
  void _startChapterSkipWatch() {
    if (_chapterSkipWatchTimer != null) return;
    _chapterSkipWatchTimer = Timer.periodic(const Duration(milliseconds: 120), (
      _,
    ) async {
      if (_player?.playing != true) {
        _stopChapterSkipWatch();
        return;
      }
      // A seek (user action or an auto intro pre-jump) is still settling;
      // re-evaluating now would only issue a second seek to the same target.
      if (_lastSeekTargetSeconds != null) return;
      if (_chapterSkipWatchBusy) return;
      _chapterSkipWatchBusy = true;
      try {
        await _maybeSkipChapterIntroOutro(position.inMilliseconds / 1000.0);
      } catch (e) {
        // A failed evaluation must not kill the timer with an unhandled error.
        debugPrint('[ChapterSkip] Watch evaluation failed: $e');
      } finally {
        _chapterSkipWatchBusy = false;
      }
    });
  }

  void _stopChapterSkipWatch() {
    if (_chapterSkipWatchTimer == null) return;
    _chapterSkipWatchTimer!.cancel();
    _chapterSkipWatchTimer = null;
  }

  Future<void> _maybeSkipChapterIntroOutro(double posSec) async {
    _resetChapterSkipHandledIfNewItem();
    final now = DateTime.now();

    // After a manual seek (rewind/fast-forward/chapter jump) the player may
    // still be settling on the target position while stale position events
    // arrive - suppress auto-skip briefly so it doesn't immediately override
    // a deliberate user navigation (e.g. rewinding to a chapter start).
    if (now.difference(_lastUserSeekTime).inMilliseconds < 3000) return;
    // A play START hold applies to the OUTRO skip only (checked below):
    // holding the intro skip too would delay the deliberate "skip the intro
    // of the chapter I just started" feature by the same window.

    final metaIdx = ChapterLookup.indexAtWithGrace(
      _chapters,
      posSec,
      _totalDuration,
    );
    if (metaIdx == null) return;
    // ChapterLookup reads the metadata timeline; refine the hit into the file
    // timeline the position actually lives on before deriving any window.
    final chapterIdx = _chapterSkipIndexAt(posSec, metaIdx);
    // Bounds are file-timeline, i.e. the same clock as posSec, so "7s from the
    // end" really is 7s before the last audible sample no matter how far the
    // metadata has drifted. A single file keeps its metadata verbatim (one
    // timeline, already exact). The previous inline derivation fell back to
    // _totalDuration for chapters lacking an end field, which made the
    // "target must stay inside the chapter" guard useless for those books.
    final bounds = _chapterSkipBounds(chapterIdx);
    final chapterStart = bounds.start;
    final chapterEnd = bounds.end;

    // Partial download: the outro-skip must never act beyond the last
    // downloaded file's real audio. The file timeline produced by a truncated
    // concat collapses every chapter from the last file's start onward onto the
    // same degenerate (zero-width) file window, so a position near the concat
    // tail can resolve to the book's LAST chapter even though the audible file
    // is an early one - and the "skip to end" branch would then seek
    // _totalDuration, which the seek clamp snaps back to the concat end and
    // reports as a spurious completion mid-handoff. Leave the tail entirely to
    // the boundary logic (_partialJumpGate / _streamContinueIfUncovered).
    final coverageEnd = _localCoverageEndSec;
    if (_isPartialLocalPlay && coverageEnd != null) {
      final lastCovered = _boundaryParkedChapterIdx(coverageEnd);
      if (lastCovered == null ||
          lastCovered >= _chapters.length ||
          chapterIdx > lastCovered) {
        return;
      }
      if (posSec >= coverageEnd - 0.5) return;
    }

    // A new "entry" begins whenever playback crosses into a different chapter
    // (prev/next nav, or switching back to an already-played chapter). Reset
    // the per-entry flags so the intro/outro skip re-applies once, and snapshot
    // the per-book skip settings for THIS entry. A settings change made while
    // an entry is already playing must NOT retroactively re-evaluate it -
    // otherwise being 1:38 into a chapter and then setting intro/outro skip to
    // 10s would yank the progress straight back to the 10s mark. The new values
    // apply from the NEXT chapter entry on.
    if (_skipEntryChapterIdx != chapterIdx) {
      _skipEntryChapterIdx = chapterIdx;
      _introSkippedThisEntry = false;
      _outroSkippedThisEntry = false;
      final settings = await ChapterSkipSettings.loadForItem(_mediaItemKey);
      _entrySkipEnabled = settings.enabled;
      _entryIntroSkip = settings.introSkipSeconds.toDouble();
      _entryOutroSkip = settings.outroSkipSeconds.toDouble();
    }
    // A deliberate same-chapter rewind (prev button / snap) may have had its
    // per-item flags wiped above by the track-swap re-key; re-assert the disarm
    // for a short window so the landing isn't dragged forward by the intro skip.
    if (_disarmRewindChapterIdx == chapterIdx &&
        _disarmRewindUntil != null &&
        DateTime.now().isBefore(_disarmRewindUntil!)) {
      _introSkippedThisEntry = true;
      _outroSkippedThisEntry = false;
    }
    if (!_entrySkipEnabled) return;

    final introSkip = _entryIntroSkip;
    final outroSkip = _entryOutroSkip;

    // Skip intro (once per entry): within the intro window and not yet handled
    // for the current entry of this chapter. Fires once, then stays marked for
    // the whole entry so it doesn't drag the position on every tick.
    if (introSkip > 0 &&
        !_introSkippedThisEntry &&
        // An exact landing on the chapter start (a fresh start, or the first
        // tick after an automatic advance) must skip too: with a strict `>` the
        // opening words played until the next position tick arrived.
        posSec >= chapterStart &&
        posSec - chapterStart < introSkip) {
      final target = chapterStart + introSkip;
      // Mark handled regardless of whether we can jump, so the window is only
      // evaluated once per entry.
      _introSkippedThisEntry = true;
      // Only perform a real jump when the target is meaningfully INSIDE the
      // chapter (>= 1s of content must remain after it) and actually advances
      // the position. Without the in-chapter clamps, a book whose chapters are
      // shorter than introSkip would overshoot straight into the next chapter,
      // making "previous chapter" navigation appear to bounce right back.
      if (chapterEnd - target >= 1.0 && target - posSec >= 1.0) {
        debugPrint(
          '[ChapterSkip] Skipping intro: pos=${posSec.toStringAsFixed(1)}s chapterStart=${chapterStart.toStringAsFixed(1)}s target=${target.toStringAsFixed(1)}s',
        );
        await _seekAbsoluteAlignedRepair(target, clampMaxSec: chapterEnd - 1.0);
        _logEvent(PlaybackEventType.seek, detail: 'skip chapter intro');
        // Persist the jump now instead of waiting for the periodic save (which
        // only runs on a 5s mark). A process kill inside that window restored
        // the pre-skip position - inside the intro - and the next start played
        // the opening words again before skipping to the same mark.
        await _saveProgressLocal(
          Duration(milliseconds: (target * 1000).round()),
        );
        return;
      } else {
        debugPrint(
          '[ChapterSkip] Intro window too short to skip: chapter=${chapterStart.toStringAsFixed(1)}-${chapterEnd.toStringAsFixed(1)}s target=${target.toStringAsFixed(1)}s — suppressed for this entry',
        );
      }
    }

    // The shared position stream runs this whole function on a 500-1000ms
    // cadence, so a chapter boundary crossing could be recognized up to a full
    // period late - the chapter tail would play ~1s too long, and an automatic
    // advance into the next chapter would leak the opening words before the
    // intro skip fired. Spin a 120ms watch near the boundary and inside an
    // intro window; it re-runs this function until the skip fires or the
    // window is left, then it cancels itself.
    final inIntroWatch =
        introSkip > 0 &&
        !_introSkippedThisEntry &&
        posSec >= chapterStart &&
        posSec - chapterStart < introSkip;
    final nextChapterStart = chapterIdx + 1 < _chapters.length
        ? _chapterSkipBounds(chapterIdx + 1).start
        : null;
    final approachingChapter =
        introSkip > 0 &&
        nextChapterStart != null &&
        posSec < nextChapterStart &&
        nextChapterStart - posSec < 1.5;
    final inOutroWatch =
        outroSkip > 0 &&
        !_outroSkippedThisEntry &&
        posSec < chapterEnd &&
        chapterEnd - posSec < outroSkip + 1.5;
    if (inOutroWatch || inIntroWatch || approachingChapter) {
      _startChapterSkipWatch();
    } else {
      _stopChapterSkipWatch();
    }

    // Skip outro (once per entry): within the outro window and not yet handled
    // for the current entry of this chapter. Held off briefly after a play
    // START: the first seconds of audio belong to the user pressing play, not
    // to the skip logic deciding the chapter they just started is already
    // over — a super-short first chapter used to be jumped the instant audio
    // began, reading as "the app started episode 2 by itself".
    final startedAt = _playStartAt;
    final recentPlayStart = startedAt != null &&
        now.difference(startedAt).inMilliseconds < 3000;
    if (outroSkip > 0 &&
        !_outroSkippedThisEntry &&
        !recentPlayStart &&
        posSec < chapterEnd &&
        chapterEnd - posSec < outroSkip) {
      _outroSkippedThisEntry = true;
      // If there's a next chapter, skip to it when the jump is meaningful.
      if (chapterIdx + 1 < _chapters.length) {
        // On the file timeline this chapter's end IS the next chapter's first
        // frame (both resolve to the same file start), so the tail lands
        // exactly on the rollover. A single file keeps the next chapter's
        // metadata start instead: its `end` may sit inside a trailing gap, and
        // jumping into that gap would leave the position with no chapter.
        final nextStart = _useFileTimelineBounds
            ? chapterEnd
            : _chapterMetaStart(chapterIdx + 1);
        // Partial download: the "next chapter" begins at/past the last
        // downloaded file's end; jumping there inside an auto-skip would cross
        // the boundary. Leave the tail to the boundary/handoff logic.
        final coverageEnd = _localCoverageEndSec;
        if (_isPartialLocalPlay &&
            coverageEnd != null &&
            nextStart > coverageEnd - 0.5) {
          debugPrint(
            '[ChapterSkip] Outro next-start ${nextStart.toStringAsFixed(1)}s '
            'past coverage end ${coverageEnd.toStringAsFixed(1)}s - leaving '
            'to boundary logic',
          );
          return;
        }
        if (nextStart - posSec >= 1.0) {
          debugPrint(
            '[ChapterSkip] Skipping outro: pos=${posSec.toStringAsFixed(1)}s chapterEnd=${chapterEnd.toStringAsFixed(1)}s nextChapterStart=${nextStart.toStringAsFixed(1)}s',
          );
          await _seekAbsoluteAlignedRepair(
            nextStart,
            clampMaxSec: nextStart + 8.0,
          );
          _logEvent(PlaybackEventType.seek, detail: 'skip chapter outro');
          return;
        }
      } else {
        // Last chapter - skip to end of book when the jump is meaningful
        // (completion handler takes over from there).
        // Partial download: the whole-book tail is not on disk; seeking
        // _totalDuration would clamp to the concat end mid-handoff and report
        // a spurious completion. Leave the tail to the boundary logic.
        if (_isPartialLocalPlay && _localCoverageEndSec != null) {
          debugPrint(
            '[ChapterSkip] Skipping to end suppressed on partial download '
            '(pos=${posSec.toStringAsFixed(1)}s) - leaving to boundary logic',
          );
          return;
        }
        if (_totalDuration > 0 && _totalDuration - posSec >= 1.0) {
          debugPrint(
            '[ChapterSkip] Skipping to end: pos=${posSec.toStringAsFixed(1)}s totalDuration=${_totalDuration.toStringAsFixed(1)}s',
          );
          await _seekAbsolute(_totalDuration);
          _logEvent(PlaybackEventType.seek, detail: 'skip to end');
          return;
        }
      }
    }
  }

  /// Clears the per-entry chapter skip markers whenever a different item (or
  /// episode) starts playing, so each book gets fresh skip handling.
  void _resetChapterSkipHandledIfNewItem() {
    final key = _mediaItemKey;
    if (_chapterSkipTrackedItemKey != key) {
      _chapterSkipTrackedItemKey = key;
      _skipEntryChapterIdx = null;
      _introSkippedThisEntry = false;
      _outroSkippedThisEntry = false;
    }
  }

  Future<void> setSpeed(double s) async {
    if (_player == null) return;
    debugPrint('[Service] setSpeed(${s}x) — before: ${_player!.speed}x');
    await _player!.setSpeed(s);
    debugPrint('[Service] setSpeed done — after: ${_player!.speed}x');
    _logEvent(
      PlaybackEventType.speedChange,
      detail: '${s.toStringAsFixed(2)}x',
    );
    if (_currentItemId != null) {
      PlayerSettings.setBookSpeed(_currentItemId!, s);
      // Re-push MediaItem so the notification/AA duration updates for the
      // new speed (duration is divided by speed for speed-adjusted time).
      if (_handler != null) {
        final chTitle = currentChapter?['title'] as String?;
        _pushMediaItem(
          _mediaItemKey,
          _currentTitle ?? '',
          _currentAuthor ?? '',
          _currentCoverUrl,
          _totalDuration,
          chapter: chTitle,
        );
      }
    }
    // Refresh the PlaybackState so Android Auto's speed badge tracks the rate.
    _handler?.refreshPlaybackState();
    notifyListeners();
  }

  /// True when a finished book is kept parked on the card (the hold finish
  /// action): the engine is stopped, so its stale position must not drive the
  /// progress bar or chapter label. UI treats it as finished (full progress,
  /// last chapter) until the user replays or picks a different book.
  bool get isParkedFinished => _finishedHeld;

  Map<String, dynamic>? get currentChapter {
    // Parked on a finished book: the engine (_player) was torn down, so the
    // null guard below must not hide the frozen last chapter.
    if (_finishedHeld && _chapters.isNotEmpty) {
      return _chapters.last as Map<String, dynamic>;
    }
    if (_chapters.isEmpty || _player == null) return null;
    final pos = chapterResolvePosSec; // absolute book position
    final idx = _resolveChapterIndex(pos);
    if (idx == null || idx < 0 || idx >= _chapters.length) return null;
    return _chapters[idx] as Map<String, dynamic>;
  }

  /// Latch-aware chapter index of the current position — the SAME source the
  /// notification/lock screen uses. In-app chapter displays (card, expanded,
  /// per-chapter download state) must agree with it: a jump in progress lands
  /// ~0.2-0.4s before the target chapter's metadata start (metadata vs file
  /// boundary drift), so a raw position containment would report the tail of
  /// the PREVIOUS chapter at ~100% until the stream crosses the boundary.
  int? get currentChapterIndex {
    // Parked on a finished book: the engine (_player) was torn down; freeze on
    // the last chapter before the null guard can hide it.
    if (_finishedHeld && _chapters.isNotEmpty) {
      return _chapters.length - 1;
    }
    if (_chapters.isEmpty || _player == null) return null;
    final idx = _resolveChapterIndex(chapterResolvePosSec);
    if (idx == null || idx < 0 || idx >= _chapters.length) return null;
    return idx;
  }

  /// True while parked at the end of a partial download: the position sits
  /// EXACTLY on the next (undownloaded) chapter's start, so any display that
  /// resolves chapters by raw position containment reports that phantom
  /// chapter. Such displays (the progress pill resolves its own containment
  /// for fill/name consistency) must prefer [currentChapterIndex] while this
  /// is set.
  bool get parkedAtBoundary => _parkedAtBoundary;

  /// Public form of the boundary chapter override for displays that resolve
  /// chapters from their OWN position sample (the progress pill's smoothed
  /// position): returns the last downloaded chapter's index while parked OR
  /// as soon as [posSec] reaches the download boundary — covering the window
  /// where the position is already at the boundary but the async park has
  /// not landed yet (raw containment would flash the undownloaded chapter).
  int? boundaryChapterOverride(double posSec) =>
      _boundaryChapterOverride(posSec);

  /// Chapter index for [posSec], mirroring the notification tick's semantics
  /// so the card/expanded title agrees with the lock screen:
  /// 1. a held chapter-jump latch is authoritative until the position passes
  ///    the latched chapter's end (metadata-vs-track drift can otherwise
  ///    demote a landed jump to a boundary gap / the previous chapter);
  /// 2. otherwise strict containment;
  /// 3. otherwise the trailing grace window past the last chapter end.
  int? _resolveChapterIndex(double posSec) {
    if (_chapters.isEmpty) return null;
    // Parked at the end of a partial download — or the position has already
    // landed on the boundary while the async park is still in flight: the
    // boundary is the NEXT chapter's start, so plain lookup would report a
    // chapter with no audio (and flash it during the pre-park window).
    // Keep the last downloaded chapter until the user navigates / plays on.
    final boundaryIdx = _boundaryChapterOverride(posSec);
    if (boundaryIdx != null) return boundaryIdx;
    if (_chapterJumpLatchIndex >= 0 &&
        _chapterJumpLatchIndex < _chapters.length) {
      final lEnd =
          (_chapters[_chapterJumpLatchIndex]['end'] as num?)?.toDouble() ??
          _totalDuration;
      if (posSec < lEnd) return _chapterJumpLatchIndex;
      // A seek that is still settling composes its position from the OLD
      // track's tail plus the NEW track's offset — a value that can overshoot
      // the latched chapter's metadata end without the audio having moved.
      // Dropping the latch on that transient re-flashes the previous
      // chapter's title over the pinned jump target for the whole buffering
      // window. Hold the latch until the seek settles.
      if (_lastSeekTargetSeconds != null) return _chapterJumpLatchIndex;
      _chapterJumpLatchIndex = -1;
    }
    final plain = ChapterLookup.indexAt(_chapters, posSec, _totalDuration);
    if (plain != null) return plain;
    return ChapterLookup.indexAtWithGrace(_chapters, posSec, _totalDuration);
  }

  Future<void> stop({bool keepSleepTimer = false}) async {
    final sw = Stopwatch()..start();
    debugPrint('[RemoveTrace] stop entry');
    // A removal stops the old book in the background; the user can tap the
    // next card before that stop finishes. Capture the session we are stopping
    // so its later sync/close/engine-stop cannot tear down the new playback.
    final stopGeneration = _playbackGeneration;
    final stopItemId = _currentItemId;
    final stopEpisodeId = _currentEpisodeId;
    final stopSessionId = _playbackSessionId;
    final stopApi = _api;
    final stopPosition = _positionForProgressSave;
    bool newerStartOwnsPlayback() =>
        _playbackGeneration != stopGeneration ||
        _currentItemId != stopItemId ||
        _currentEpisodeId != stopEpisodeId;
    // Background item reads (prewarm/refetch/backfill) must not hold the pipe
    // while the session sync and close POSTs below run.
    _api?.cancelBackgroundItemTransfers();
    _cancelPendingSessionClients();
    debugPrint('[RemoveTrace] stop transfers canceled ${sw.elapsedMilliseconds}ms');
    _pausedForOffline = false;
    _pauseStopTimer?.cancel();
    _pauseStopTimer = null;
    _endAdvanceBuffering();
    final wasPlaying = _player?.playing ?? false;
    // Save final position locally
    if (stopItemId != null) {
      final pos = stopPosition;
      debugPrint(
        '[Player] Saving on stop: ${(pos.inMilliseconds / 1000.0).toStringAsFixed(1)}s',
      );
      await _saveProgressLocal(pos);
      debugPrint('[RemoveTrace] stop local save ${sw.elapsedMilliseconds}ms');
      // Credit the final playing tail before the push/close below. Skipped when
      // stopped from a paused state so the idle span isn't counted.
      if (wasPlaying) await _accrueListening(pos);
      debugPrint('[RemoveTrace] stop accrue ${sw.elapsedMilliseconds}ms');
    }
    if (newerStartOwnsPlayback()) {
      debugPrint('[Player] stop abandoned before sync - a newer start owns playback');
      if (stopSessionId != null && stopApi != null) {
        unawaited(
          stopApi.closePlaybackSession(stopSessionId).catchError((_) {}),
        );
      }
      return;
    }

    // Check manual offline before syncing
    final manualOffline =
        (_prefs ?? await SharedPreferences.getInstance()).getBool(
          'manual_offline_mode',
        ) ??
        false;

    if (!manualOffline) {
      // Try server sync. If stop() was called while already paused, we were
      // not playing in the interval since the last sync - pass timeListened=0
      // so the wall-clock diff doesn't inflate server listening stats.
      if (stopSessionId != null && stopApi != null) {
        _logEvent(PlaybackEventType.sessionEnd, detail: 'stop');
        debugPrint('[RemoveTrace] stop sync start ${sw.elapsedMilliseconds}ms');
        await _syncToServer(
          stopPosition,
          timeListenedOverride: wasPlaying ? null : 0,
        );
        debugPrint('[RemoveTrace] stop sync done ${sw.elapsedMilliseconds}ms');
        try {
          debugPrint('[Player] Closing session (stop)');
          await stopApi.closePlaybackSession(stopSessionId);
          debugPrint(
            '[RemoveTrace] stop session close done ${sw.elapsedMilliseconds}ms',
          );
        } catch (_) {}
      } else if (stopItemId != null && stopApi != null) {
        await _progressSync.syncToServer(api: stopApi, itemId: stopItemId);
      }
    }
    if (newerStartOwnsPlayback()) {
      debugPrint('[Player] stop abandoned before local-session pause - a newer start owns playback');
      return;
    }

    // Local-session play: push the final accrued listening, then finalize.
    // Runs even under manual offline so the session is queued for replay.
    if (_localSessionMode || _localSessionAccounting) {
      bool pushed = false;
      if (!manualOffline && _api != null) {
        pushed = await LocalSessionService().pushActive(api: _api!);
      }
      await LocalSessionService().finalizeActive(pushed: pushed);
    }

    if (newerStartOwnsPlayback()) {
      debugPrint('[Player] stop abandoned before engine stop - a newer start owns playback');
      return;
    }
    await _player?.stop();
    debugPrint('[RemoveTrace] stop engine ${sw.elapsedMilliseconds}ms');
    if (newerStartOwnsPlayback()) {
      debugPrint('[Player] stop engine finished after a newer start - keeping its state');
      return;
    }
    _onPlaybackStateChangedCallback?.call(false);
    unawaited(_persistLastUserPlaying(false));

    _clearState();
    _chapters = [];
    _handler?.updateChaptersQueue(const []);
    // Cancel sleep timer when playback is stopped - unless the caller is
    // handing off to Chromecast, where an armed timer should keep running
    // against the cast session rather than vanish (GH #338).
    if (!keepSleepTimer && SleepTimerService().isActive) {
      SleepTimerService().cancel();
    }
    // Release audio focus so other apps can use it - but not during casting,
    // because deactivating the session can interfere with cast playback.
    if (!ChromecastService().isCasting) {
      debugPrint('[Battery] AudioSession DEACTIVATED (stop)');
      try {
        (await AudioSession.instance).setActive(false);
      } catch (_) {}
    }
    debugPrint('[RemoveTrace] stop complete ${sw.elapsedMilliseconds}ms');
  }

  /// Stop playback without saving progress — used by reset progress.
  Future<void> stopWithoutSaving() async {
    _pausedForOffline = false;
    _endAdvanceBuffering();
    // Close server session without syncing position
    if (_playbackSessionId != null && _api != null) {
      try {
        debugPrint('[Player] Closing session (reset progress)');
        await _api!.closePlaybackSession(_playbackSessionId!);
      } catch (_) {}
    }
    // Local-session play: queue the accrued listening for replay (the user did
    // listen; resetting position shouldn't erase that).
    if (_localSessionMode || _localSessionAccounting) {
      await LocalSessionService().finalizeActive();
    }
    await _player?.stop();
    _clearState();
    _chapters = [];
    _handler?.updateChaptersQueue(const []);
  }

  @override
  void dispose() {
    _endAdvanceBuffering();
    _syncSub?.cancel();
    _bgSaveTimer?.cancel();
    _pauseStopTimer?.cancel();
    _prewarmSessionCloseTimer?.cancel();
    _stuckCheckTimer?.cancel();
    _playVerifyTimer?.cancel();
    _firstByteTimer?.cancel();
    _indexSub?.cancel();
    _player?.dispose();
    super.dispose();
  }
}

/// The book shown in the notification after a removal, plus everything needed
/// to start it from the notification's Play button or a headset media button.
class _IdleNotificationTarget {
  final ApiService api;
  final String itemId;
  final String title;
  final String author;
  final String? coverUrl;
  final Uri? artUri;
  final double totalDuration;
  List<dynamic> chapters;
  final Map<String, dynamic>? itemSnapshot;
  final String? episodeId;
  final String? episodeTitle;
  final String? libraryId;

  /// Where the notification's progress bar sits. Seeks/rewinds/chapter jumps
  /// move it while the player is idle, and Play starts the book here.
  double positionSec;

  /// True once the user moved [positionSec] explicitly, so the start skips
  /// the session-start rewind and lands exactly where the bar shows.
  bool positionAdjusted = false;

  String get notificationKey =>
      episodeId != null ? '$itemId-$episodeId' : itemId;

  _IdleNotificationTarget({
    required this.api,
    required this.itemId,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.artUri,
    required this.totalDuration,
    required this.chapters,
    required this.itemSnapshot,
    required this.episodeId,
    required this.episodeTitle,
    required this.libraryId,
    this.positionSec = 0,
  });
}
