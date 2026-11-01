class UpdateReleaseAsset {
  final String name;
  final String downloadUrl;

  const UpdateReleaseAsset({
    required this.name,
    required this.downloadUrl,
  });
}

const supportedAndroidUpdateAbis = <String>{
  'armeabi-v7a',
  'arm64-v8a',
  'x86_64',
};

/// The GMS-free release names its APKs after the ELF architecture rather than
/// the Android ABI (`-fdroid-aarch64.apk`), so neither flavor can be handed
/// the other's file - installing the wrong kind would put Google Play Services
/// back on a device that asked not to have them.
const fdroidAbiTokens = <String, String>{
  'armeabi-v7a': 'armv7',
  'arm64-v8a': 'aarch64',
  'x86_64': 'amd64',
};

UpdateReleaseAsset? selectAndroidUpdateAsset({
  required List<UpdateReleaseAsset> assets,
  required List<String> supportedAbis,
  bool fdroid = false,
}) {
  final apks = assets
      .where((asset) => asset.name.toLowerCase().endsWith('.apk'))
      .where((asset) => _isFdroidAsset(asset.name) == fdroid)
      .toList();

  for (final abi in supportedAbis.map((value) => value.toLowerCase())) {
    if (!supportedAndroidUpdateAbis.contains(abi)) continue;
    final token = fdroid ? fdroidAbiTokens[abi]! : abi;
    for (final asset in apks) {
      if (_hasFilenameToken(asset.name, token)) return asset;
    }
  }

  final universal = fdroid ? 'all' : 'universal';
  for (final asset in apks) {
    if (_hasFilenameToken(asset.name, universal)) return asset;
  }

  if (apks.length == 1 && !_isAbiSpecific(apks.single.name, fdroid)) {
    return apks.single;
  }
  return null;
}

String currentUpdateVersion({
  required String versionName,
  required String packageBuildNumber,
  int? baseBuildNumber,
}) {
  final build = baseBuildNumber != null && baseBuildNumber > 0
      ? baseBuildNumber.toString()
      : packageBuildNumber;
  return '$versionName+$build';
}

int compareUpdateVersions(String a, String b) {
  final (aSem, aBuild) = _parseVersion(a);
  final (bSem, bBuild) = _parseVersion(b);
  for (int i = 0; i < 3; i++) {
    if (aSem[i] != bSem[i]) return aSem[i] - bSem[i];
  }
  if (aBuild != null || bBuild != null) {
    final aB = aBuild ?? 0;
    final bB = bBuild ?? 0;
    if (aB != bB) return aB - bB;
  }
  return 0;
}

String androidUpdatePackageLabel(UpdateReleaseAsset asset) {
  var packageKind = 'Universal';
  for (final entry in fdroidAbiTokens.entries) {
    if (_hasFilenameToken(asset.name, entry.key) ||
        _hasFilenameToken(asset.name, entry.value)) {
      packageKind = entry.key;
      break;
    }
  }

  final build = RegExp(
    r'-(\d+)(?:-fdroid)?-(?:universal|all|armeabi-v7a|armv7|arm64-v8a|aarch64|x86_64|amd64)(?:-pre)?\.apk$',
    caseSensitive: false,
  ).firstMatch(asset.name)?.group(1);
  return build == null
      ? '$packageKind APK'
      : '$packageKind APK • build $build';
}

bool _isFdroidAsset(String name) => _hasFilenameToken(name, 'fdroid');

bool _isAbiSpecific(String name, bool fdroid) {
  final tokens = fdroid ? fdroidAbiTokens.values : supportedAndroidUpdateAbis;
  return tokens.any((token) => _hasFilenameToken(name, token));
}

bool _hasFilenameToken(String filename, String token) {
  final pattern = RegExp(
    '(^|[-_.])${RegExp.escape(token)}(?=[-_.]|\$)',
    caseSensitive: false,
  );
  return pattern.hasMatch(filename);
}

(List<int>, int?) _parseVersion(String version) {
  final sem = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(version);
  final parts = [
    for (var i = 1; i <= 3; i++) int.parse(sem?.group(i) ?? '0'),
  ];
  final build = RegExp(r'[-+](\d+)$').firstMatch(version);
  return (parts, build == null ? null : int.parse(build.group(1)!));
}
