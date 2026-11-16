/// A process-wide note that a playback start is using the network pipe.
///
/// Why a separate file: both the player and the background pullers need this,
/// and the player already imports the sync service, so putting the flag on
/// either side would make the import graph circular.
///
/// The start is the only party that cannot wait: on a server that doesn't
/// compress its API JSON, a `/play` body is several MB (measured 4.2 MB, and a
/// 2.87 MB item beside it), so anything else that fires a large read at the
/// same moment pushes the first audio bytes behind it. Background work asks
/// here first and yields instead of competing.
class PlaybackQuietGate {
  PlaybackQuietGate._();

  /// A start that somehow never reports back must not park the background work
  /// for the whole session: every start is bounded well below this by its own
  /// network timeouts, so past it the flag is treated as stale.
  static const _staleAfter = Duration(seconds: 90);

  static bool _starting = false;
  static DateTime? _startedAt;
  static DateTime? _lastStartEndedAt;

  /// A start began asking for its source.
  static void beginStart() {
    _starting = true;
    _startedAt = DateTime.now();
  }

  /// A start finished, successfully or not.
  static void endStart() {
    _starting = false;
    _startedAt = null;
    _lastStartEndedAt = DateTime.now();
  }

  /// True while a start is loading, or one finished within [tail]: its first
  /// audio bytes are still settling into the buffer then, and a multi-MB read
  /// started at that moment still costs the listener a stall.
  static bool ownsPipe({Duration tail = const Duration(seconds: 3)}) {
    if (_starting) {
      final began = _startedAt;
      if (began == null || DateTime.now().difference(began) < _staleAfter) {
        return true;
      }
    }
    final ended = _lastStartEndedAt;
    return ended != null && DateTime.now().difference(ended) < tail;
  }
}
