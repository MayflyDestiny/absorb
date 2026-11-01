/// Which beta of the current release cycle this build belongs to. Bump it in
/// the same commit as the version bump for each beta. Full releases use an
/// even patch number and never show it, so a stale value can't leak into a
/// stable build - it only has to be right during a beta cycle.
const int kBetaNumber = 0;

/// The F-Droid (Google-services-free) build. Passed as a dart-define by the
/// release workflow's fdroid job only - not by `fdroid/com.barnabas.absorb.yml`,
/// whose builds must stay free of any self-update.
const bool kFdroidBuild = bool.fromEnvironment('FDROID_BUILD');

/// Whether this build can update itself from the GitHub releases. Both the
/// GitHub and the GMS-free builds ship their own assets on the same release
/// and pick them apart by name (see `selectAndroidUpdateAsset`), so each only
/// ever offers its own kind; Play Store builds and plain local builds don't.
const bool kUpdatesFromReleases =
    bool.fromEnvironment('GITHUB_BUILD') || kFdroidBuild;

/// The beta number to show for [version] (`1.9.3+240` or `1.9.3`), or null
/// when this isn't a beta build. Odd patch = beta cycle, even = full release.
int? betaNumberFor(String version) {
  final parts = version.split('+').first.split('.');
  if (parts.length < 3) return null;
  final patch = int.tryParse(parts[2]);
  if (patch == null || patch.isEven || kBetaNumber <= 0) return null;
  return kBetaNumber;
}

/// `1.9.3+240 (Beta 6)` for logs and other unlocalized places; the settings
/// screen formats its own copy through l10n.
String versionWithBeta(String version) {
  final beta = betaNumberFor(version);
  return beta == null ? version : '$version (Beta $beta)';
}
