import 'package:flutter/foundation.dart';

const bool _devBuild = bool.fromEnvironment('DEV_BUILD');

/// Compile-time flag for detailed diagnostics. Only debug/profile runs and the
/// dev flavor carry them; distribution releases (github / playstore, built via
/// the release workflows with `--release`) compile them out so the shipped app
/// only writes the basic [basicLog] lines.
const bool verboseDiagnostics = kDebugMode || kProfileMode || _devBuild;

/// Detailed diagnostic chatter (per-step decisions, timer heartbeats, resolver
/// internals, queue plans). Compiled out of distribution release builds.
void verboseLog(String message) {
  if (!verboseDiagnostics) return;
  debugPrint(message);
}

/// Basic status/error lines that stay in every build, including releases.
void basicLog(String message) {
  debugPrint(message);
}