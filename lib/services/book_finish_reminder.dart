import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:vibration/vibration.dart';

import 'player_settings.dart';

/// Fires the optional book-finished cues (chime / voice / vibration) when a
/// book reaches the end. No system notification is posted by design — the user
/// usually listens without looking at the screen, so audio/haptic cues are
/// preferred over a notification entry.
///
/// The cue mode doubles as the on/off switch: 'off' (the default) is silent;
/// picking chime / voice / vibration enables that cue directly.
class BookFinishReminder {
  BookFinishReminder._();
  static final BookFinishReminder instance = BookFinishReminder._();

  final FlutterTts _tts = FlutterTts();
  ja.AudioPlayer? _chimePlayer;
  bool _ttsReady = false;

  /// Fire the configured cues.
  ///
  /// [onAutoAdvance] is true when the queue auto-advanced to the next book
  /// instead of parking on the finished book; these only fire when the user
  /// opted into reminding during auto-advance.
  Future<void> fire({bool onAutoAdvance = false}) async {
    final mode = await PlayerSettings.getBookFinishMode();
    if (mode == 'off') return;
    if (onAutoAdvance &&
        !await PlayerSettings.getBookFinishReminderOnAutoAdvance()) {
      return;
    }

    switch (mode) {
      case 'chime':
        await _playChime();
      case 'voice':
        await _speak();
      case 'vibrate':
        await _vibrate();
      default:
        break;
    }
  }

  Future<void> _playChime() async {
    try {
      _chimePlayer?.dispose();
      final player = ja.AudioPlayer();
      _chimePlayer = player;
      await player.setVolume(1.0);
      await player.setAsset('assets/audio/bell.mp3');
      await player.play();
      player.playerStateStream
          .where((s) => s.processingState == ja.ProcessingState.completed)
          .first
          .then((_) {
            player.dispose();
            if (_chimePlayer == player) _chimePlayer = null;
          });
    } catch (e) {
      debugPrint('[BookFinish] chime error: $e');
    }
  }

  /// Play the bundled natural-voice cue first; fall back to system TTS only
  /// when the asset is missing so the cue never goes silent.
  Future<void> _speak() async {
    // Match the language the UI actually shows: a manually picked language
    // wins, otherwise fall back to the system locale.
    final savedLang = await PlayerSettings.getLanguage();
    final langCode = savedLang.isNotEmpty
        ? savedLang.toLowerCase()
        : WidgetsBinding.instance.platformDispatcher.locale.languageCode
              .toLowerCase();
    final isZh = langCode.startsWith('zh');
    final asset = isZh
        ? 'assets/audio/finish_cn.wav'
        : 'assets/audio/finish_en.wav';
    try {
      final player = ja.AudioPlayer();
      await player.setAsset(asset);
      await player.setVolume(1.0);
      await player.play();
      player.playerStateStream
          .where((s) => s.processingState == ja.ProcessingState.completed)
          .first
          .then((_) => player.dispose());
      return;
    } catch (e) {
      debugPrint(
        '[BookFinish] bundled cue unavailable, falling back to TTS: $e',
      );
    }

    // System-TTS fallback for locales without a bundled cue.
    try {
      if (!_ttsReady) {
        await _tts.awaitSpeakCompletion(true);
        _ttsReady = true;
      }
      await _tts.setLanguage(isZh ? 'zh-CN' : 'en-US');
      // Slower rate + slightly lower pitch keeps the cue from sounding
      // robotic and abrupt; the trailing pause softens the ending.
      await _tts.setSpeechRate(0.45);
      await _tts.setPitch(0.95);
      await _tts.speak(
        isZh ? '本书已播完。' : 'This book has finished playing.',
      );
    } catch (e) {
      debugPrint('[BookFinish] tts error: $e');
    }
  }

  Future<void> _vibrate() async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 250]);
      }
    } catch (e) {
      debugPrint('[BookFinish] vibrate error: $e');
    }
  }
}
