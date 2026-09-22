/// Tracks temp/cache files that are currently being written by the app's own
/// export, share and update flows. The settings "clear caches" sweep consults
/// this set before deleting files, so a half-written export isn't razed while
/// it's on disk.
library;

final Set<String> _inFlightTempWrites = <String>{};

/// Marks [path] as being written right now; it becomes immune to the cache
/// sweeps until [unregisterInFlightWrite] is called (usually from a finally).
void registerInFlightWrite(String path) {
  _inFlightTempWrites.add(path);
}

/// Removes [path] from the in-flight protection set.
void unregisterInFlightWrite(String path) {
  _inFlightTempWrites.remove(path);
}

/// Whether [path] is currently registered as an in-flight write.
bool isInFlightWrite(String path) {
  return _inFlightTempWrites.contains(path);
}