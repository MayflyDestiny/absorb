import 'package:flutter/foundation.dart';

/// Marks a locally-installed, non-distribution build. Nothing in CI passes it,
/// so it has to be set by hand (`flutter build apk --release --flavor dev
/// --dart-define=DEV_BUILD=true`); a dev build made without it is treated as a
/// distribution build.
const bool _devBuild = bool.fromEnvironment('DEV_BUILD');

/// Compile-time flag for detailed diagnostics. Only debug/profile runs and the
/// dev flavor carry them; distribution releases (github / playstore / fdroid,
/// built via the release workflows with `--release`) compile them out so the
/// shipped app only writes the basic [basicLog] lines.
const bool verboseDiagnostics = kDebugMode || kProfileMode || _devBuild;

/// Detailed diagnostic chatter (per-step decisions, timer heartbeats, resolver
/// internals, queue plans). Compiled out of distribution release builds.
void verboseLog(String message) {
  if (!verboseDiagnostics) return;
  debugPrint(message);
}

/// Basic status/error lines that stay in every build, including releases. The
/// `[L]` marker lets the release-mode [debugPrint] filter recognize these and
/// drop everything else; debug/profile/dev runs print all lines regardless.
void basicLog(String message) {
  debugPrint('[L] $message');
}