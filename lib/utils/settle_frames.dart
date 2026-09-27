import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Resolves once [frames] consecutive frames have been drawn, or after
/// [maxWait] — whichever happens first.
///
/// Used to hold a first-run dialog back until the shell has actually settled
/// instead of guessing with a fixed delay. A fixed delay is wrong in both
/// directions: on a fast device the dialog lands while covers are still
/// decoding (the `showDialog` overlay forces a full-screen repaint that shows
/// up as jank), and on a slow one it fires long before the layout it was meant
/// to wait for is done.
///
/// `scheduleFrame` is required because a callback registered from a post-frame
/// hook never runs on its own — without an explicit request no further frame is
/// drawn and `endOfFrame` would never complete.
Future<void> waitForFramesSettled({
  int frames = 2,
  Duration maxWait = const Duration(milliseconds: 2000),
}) async {
  final binding = SchedulerBinding.instance;
  final settle = () async {
    for (var i = 0; i < frames; i++) {
      binding.scheduleFrame();
      await binding.endOfFrame;
    }
  }();
  // The cap keeps a caller from hanging forever if frames stop being produced.
  await Future.any<void>([settle, Future<void>.delayed(maxWait)]);
}
