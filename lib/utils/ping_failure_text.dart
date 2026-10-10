import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// Localized, user-facing explanation for a failed server reachability probe.
///
/// The raw exception text is appended as a small diagnostic tail (kept for
/// support), matching the previous inline English behavior.
String pingFailureText(
  AppLocalizations l,
  PingFailure failure, {
  int? statusCode,
  String? raw,
}) {
  switch (failure) {
    case PingFailure.none:
      return '';
    case PingFailure.timeout:
      return l.pingFailureTimeout;
    case PingFailure.dns:
      return _withRaw(l.pingFailureDns, raw);
    case PingFailure.tls:
      return _withRaw(l.pingFailureTls, raw);
    case PingFailure.refused:
      return _withRaw(l.pingFailureRefused, raw);
    case PingFailure.earlyClose:
      return _withRaw(l.pingFailureEarlyClose, raw);
    case PingFailure.reset:
      return _withRaw(l.pingFailureReset, raw);
    case PingFailure.httpStatus:
      return l.pingFailureHttpStatus(statusCode ?? 0);
    case PingFailure.notBookOrbit:
      return l.pingFailureNotBookOrbit;
    case PingFailure.passwordLoginOff:
      return l.pingFailurePasswordLoginOff;
    case PingFailure.unknown:
      return raw ?? '';
  }
}

String _withRaw(String message, String? raw) =>
    raw == null || raw.isEmpty ? message : '$message\n$raw';
