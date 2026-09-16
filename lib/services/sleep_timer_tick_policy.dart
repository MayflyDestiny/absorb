enum SleepTimerTickAction { wait, countDown, trigger }

SleepTimerTickAction sleepTimerTickAction({
  required Duration timeRemaining,
  required bool isPlaybackActive,
  required bool isPauseRequested,
}) {
  // The countdown runs regardless of playback state — a timer set should
  // expire on schedule even when nothing is playing. While playback is paused
  // the trigger turns the timer off instead of pausing (see _triggerSleep).
  if (timeRemaining <= Duration.zero) {
    return SleepTimerTickAction.trigger;
  }
  return SleepTimerTickAction.countDown;
}
