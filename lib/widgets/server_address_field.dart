import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// Builds the effective URL for [input] under [protocol].
///
/// Bare IP literals pick up the ABS LAN default port 13378; domains keep the
/// scheme's implicit port (https 443 / http 80). An explicit ":port" in the
/// field always wins, and any "/path?query" suffix is preserved.
String buildServerUrl(String input, String protocol) {
  var hostPort = input
      .trim()
      .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  final splitIdx = hostPort.indexOf(RegExp(r'[\/?#]'));
  var suffix = '';
  if (splitIdx >= 0) {
    suffix = hostPort.substring(splitIdx);
    hostPort = hostPort.substring(0, splitIdx);
  }
  if (isIpWithoutPort(hostPort) && !RegExp(r':\d+$').hasMatch(hostPort)) {
    hostPort = '$hostPort:13378';
  }
  return '$protocol$hostPort$suffix';
}

/// True when [host] is an IP literal with no port suffix - IPv4, a bracketed
/// IPv6, or a compressed bare IPv6 (contains `::`).
bool isIpWithoutPort(String host) {
  if (RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host)) return true;
  if (RegExp(r'^\[[0-9a-fA-F:]+\]$').hasMatch(host)) return true;
  if (RegExp(r'^[0-9a-fA-F:]+$').hasMatch(host) && host.contains('::')) {
    return true;
  }
  return false;
}

/// Drop a scheme's default port from [hostPort] so fields show the bare host
/// ("192.168.1.5:13378"/"example.com:443") as "192.168.1.5"/"example.com".
/// Bare IP literals default to the ABS LAN port 13378; domains keep https's
/// 443 or http's 80. Any other port is a deliberate choice and is kept, as is
/// any "/path?query" suffix. Mirrors the inference in [buildServerUrl], so a
/// stripped port is exactly re-added when the URL is rebuilt.
String stripDefaultPort(String hostPort, String protocol) {
  final splitIdx = hostPort.indexOf(RegExp(r'[\/?#]'));
  var hostPart = hostPort;
  var suffix = '';
  if (splitIdx >= 0) {
    suffix = hostPart.substring(splitIdx);
    hostPart = hostPart.substring(0, splitIdx);
  }

  String host;
  int? port;
  // Bracketed IPv6 host:port ("[::1]:13378") - split after the closing bracket.
  final bracketed = RegExp(r'^(\[[0-9a-fA-F:]+\]):(\d+)$').firstMatch(hostPart);
  if (bracketed != null) {
    host = bracketed.group(1)!;
    port = int.parse(bracketed.group(2)!);
  } else if (hostPart.contains('::')) {
    // Bare IPv6: no way to tell a trailing colons from a port, leave untouched.
    return hostPort;
  } else {
    final idx = hostPart.lastIndexOf(':');
    if (idx > 0) {
      final maybePort = hostPart.substring(idx + 1);
      if (RegExp(r'^\d+$').hasMatch(maybePort)) {
        host = hostPart.substring(0, idx);
        port = int.parse(maybePort);
      } else {
        host = hostPart;
      }
    } else {
      host = hostPart;
    }
  }
  if (port == null) return hostPort;

  final isDefault =
      (isIpWithoutPort(host) && port == 13378) ||
      (protocol == 'https://' && port == 443) ||
      (protocol == 'http://' && port == 80);
  return isDefault ? '$host$suffix' : hostPort;
}

/// Display form of a saved server URL: strips the scheme and the scheme's
/// default port, so lists and rows show "192.168.1.5" / "example.com" instead
/// of "https://192.168.1.5:13378" / "https://example.com:443". The scheme is
/// read from the URL when present; [fallbackProtocol] applies otherwise.
String displayServerUrl(String url, {String fallbackProtocol = 'https://'}) {
  var rest = url.trim();
  var protocol = fallbackProtocol;
  final scheme = RegExp(
    r'^(https?):\/\/(.*)$',
    caseSensitive: false,
  ).firstMatch(rest);
  if (scheme != null) {
    protocol = '${scheme.group(1)!.toLowerCase()}://';
    rest = scheme.group(2)!;
  }
  return stripDefaultPort(rest, protocol);
}

/// The server address field shared by first-run sign-in and the settings
/// "edit server connection" editor.
///
/// Both entry points get the protocol dropdown, scheme auto-extraction and the
/// ABS bare-IP port default, so the address is written the same way in either
/// place. Reachability probing is opt-in via [validate] because the two
/// callers disagree on whether an unreachable server is acceptable.
class ServerAddressField extends StatefulWidget {
  const ServerAddressField({
    super.key,
    this.fieldKey,
    required this.controller,
    this.validate = true,
    this.label,
    this.hint,
    this.helperText,
    this.headersProvider,
    this.onValidityChanged,
    this.onValidUrl,
    this.onSubmitted,
    this.initialProtocol = 'https://',
    this.inferProtocol = true,
    this.autofocus = false,
    this.textInputAction = TextInputAction.next,
  });

  final TextEditingController controller;

  /// Key for the inner text field, for tests. [key] itself is taken by the
  /// element key callers need in order to reach [ServerAddressFieldState].
  final Key? fieldKey;

  /// Whether to probe the server and show a reachability status.
  ///
  /// Sign-in passes `true` because an unreachable server blocks authentication.
  /// The settings editor passes `false`: the address can be saved either way
  /// (VPN toggling, server maintenance, DNS that only resolves off-device), so
  /// a verdict - green tick or red cross - would be misleading. Turning it off
  /// also skips the probe entirely instead of displaying a result nobody is
  /// allowed to act on.
  final bool validate;

  final String? label;
  final String? hint;
  final String? helperText;

  /// Extra headers sent with the reachability probe (reverse-proxy auth).
  final Map<String, String> Function()? headersProvider;

  final void Function(bool valid)? onValidityChanged;

  /// Fired with the resolved URL once a check succeeds.
  final void Function(String url)? onValidUrl;

  /// Fired when the keyboard's text-input action is triggered. Defaults to
  /// [checkNow], which is a no-op probe when [validate] is false - so a
  /// caller that only wants to persist the value (no reachability check) must
  /// pass its own handler here.
  final VoidCallback? onSubmitted;

  /// Scheme the dropdown starts on. Defaults to HTTPS because that is what a
  /// remote server almost always is. An initial value carrying its own scheme
  /// still wins - see [_adoptSchemeFromInitialValue].
  final String initialProtocol;

  /// Whether a bare host with no explicit port may pick its own scheme by
  /// looking at what was typed.
  ///
  /// The LAN server field turns this off. An ABS LAN address is served over
  /// plain HTTP, and inferring from the shape of the host meant a hostname
  /// (`absorb.lan`) silently became HTTPS - pointing the app at a TLS port
  /// nothing is listening on, with no visible reason why it would not connect.
  /// With this off the field keeps [initialProtocol] until the user picks a
  /// scheme from the dropdown themselves.
  final bool inferProtocol;

  final bool autofocus;
  final TextInputAction textInputAction;

  @override
  State<ServerAddressField> createState() => ServerAddressFieldState();
}

class ServerAddressFieldState extends State<ServerAddressField> {
  String _protocol = 'https://';

  // Set briefly while the protocol dropdown is changed by hand so the
  // auto-inference below (IP -> HTTP) doesn't override the explicit choice.
  bool _skipAutoProtocol = false;

  bool _valid = false;
  bool _checking = false;
  String? _error;
  // Technical reason the last check failed (TLS, timeout, HTTP status, etc.),
  // shown beneath the field so unreachable-in-app-but-fine-in-browser servers
  // are diagnosable instead of just "could not reach server".
  String? _errorDetail;
  Timer? _debounce;
  String _lastValidated = '';

  @override
  void initState() {
    super.initState();
    _protocol = widget.initialProtocol;
    _adoptSchemeFromInitialValue();
    widget.controller.addListener(_onChanged);
    if (widget.validate && widget.controller.text.trim().isNotEmpty) {
      // A pre-filled address (editing a saved account) gets checked right away
      // instead of waiting for the user to type something.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _check();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  /// Splits an already-complete URL ("https://host:port/path") that the caller
  /// seeded the controller with, so the scheme lands in the dropdown and the
  /// field shows the bare host the way sign-in does. A scheme-default port is
  /// dropped the same way sign-in drops it ("192.168.1.5:13378" -> host).
  void _adoptSchemeFromInitialValue() {
    final raw = widget.controller.text;
    final scheme = RegExp(
      r'^(https?):\/\/([^\/?#]*)',
      caseSensitive: false,
    ).firstMatch(raw.trim());
    if (scheme == null) return;
    _protocol = '${scheme.group(1)!.toLowerCase()}://';
    _skipAutoProtocol = true;
    widget.controller.text =
        stripDefaultPort(scheme.group(2) ?? '', _protocol);
    _skipAutoProtocol = false;
  }

  /// The URL this field currently describes, with the protocol and the implied
  /// port applied. Read this when saving rather than the raw controller text.
  String get fullUrl => buildServerUrl(widget.controller.text, _protocol);

  String get protocol => _protocol;

  /// Runs a reachability check immediately, bypassing the debounce.
  ///
  /// Returns the resulting validity, so callers can chain a focus move off a
  /// keyboard submit: an already-valid address short-circuits without spending
  /// a request, anything else is re-probed once.
  Future<bool> checkNow() async {
    if (widget.controller.text.trim().isEmpty) return false;
    if (!widget.validate) return true;
    if (_valid && _error == null) return true;
    _debounce?.cancel();
    await _check();
    return _valid;
  }

  void _onChanged() {
    final raw = widget.controller.text;
    final text = raw.trim();

    // Auto-extract the host when a full URL carrying a scheme is entered or
    // pasted ("https://github.com/MayflyDestiny/absorb" -> "github.com"): the
    // scheme moves into the protocol dropdown and any path/query is dropped.
    final scheme = RegExp(
      r'^(https?):\/\/([^\/?#]*)',
      caseSensitive: false,
    ).firstMatch(text);
    if (scheme != null) {
      final protocol = '${scheme.group(1)!.toLowerCase()}://';
      final host = stripDefaultPort(scheme.group(2) ?? '', protocol);
      if (protocol != _protocol) {
        setState(() => _protocol = protocol);
      }
      // Rewriting the field re-enters this listener with the clean host, which
      // then runs the validation below. The explicit scheme is an explicit
      // protocol choice, so the IP default below must not override it.
      if (host != raw) {
        _skipAutoProtocol = true;
        widget.controller.text = host;
        _skipAutoProtocol = false;
      }
      return;
    }

    if (text.isEmpty) {
      setState(() {
        _valid = false;
        _checking = false;
        _error = null;
        _errorDetail = null;
        _lastValidated = '';
      });
      _notify(false);
      _debounce?.cancel();
      return;
    }

    // Bare host literals auto-pick a scheme unless the user chose one by hand
    // (_skipAutoProtocol), pinned a custom port (an explicit ":port" is typed
    // in, so the scheme was chosen deliberately alongside it), or the caller
    // disabled inference entirely via [ServerAddressField.inferProtocol].
    //   - bare IP literal  -> the ABS LAN convention: HTTP + port 13378
    //   - localhost        -> HTTP (local dev servers are plain HTTP)
    //   - domain / hostname -> HTTPS by default
    // Domains keep the scheme's implicit port (https 443 / http 80); an
    // explicit ":port" typed into the field always wins either way.
    final hostPart = text.split(RegExp(r'[\/?#]')).first;
    final hasExplicitPort = RegExp(r':\d+$').hasMatch(hostPart);
    if (widget.inferProtocol && !_skipAutoProtocol && !hasExplicitPort) {
      if (isIpWithoutPort(hostPart) ||
          hostPart.toLowerCase() == 'localhost') {
        if (_protocol != 'http://') {
          setState(() => _protocol = 'http://');
        }
      } else if (_protocol != 'https://') {
        setState(() => _protocol = 'https://');
      }
    }

    if (!widget.validate) {
      // The address is accepted as typed, so there is nothing to invalidate and
      // nothing to probe. Protocol inference above still applies.
      _debounce?.cancel();
      return;
    }

    // Only invalidate if the server text actually changed from what we validated
    final fullUrl = buildServerUrl(text, _protocol);
    if (fullUrl != _lastValidated) {
      setState(() {
        _valid = false;
        _checking = true;
        _error = null;
      });
      _notify(false);
    } else {
      // Same server, just re-checking — keep fields visible
      setState(() {
        _checking = true;
        _error = null;
      });
    }

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _check);
  }

  void _notify(bool valid) {
    widget.onValidityChanged?.call(valid);
  }

  Future<void> _check() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;

    final url = buildServerUrl(text, _protocol);

    try {
      final headers = widget.headersProvider?.call() ?? const {};
      final result = await ApiService.pingServerDetailed(url, customHeaders: headers);
      if (!mounted) return;
      if (widget.controller.text.trim() != text) return;

      setState(() {
        _checking = false;
        _valid = result.ok;
        _error = result.ok
            ? null
            : AppLocalizations.of(context)!.loginCouldNotReachServer;
        _errorDetail = result.ok ? null : result.detail;
        _lastValidated = result.ok ? url : '';
      });

      if (result.ok) {
        _notify(true);
        widget.onValidUrl?.call(url);
      } else {
        _notify(false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _valid = false;
        _error = AppLocalizations.of(context)!.loginCouldNotReachServer;
        _errorDetail = e.toString();
      });
      _notify(false);
    }
  }

  void _onProtocolChanged(String? v) {
    if (v == null) return;
    setState(() {
      _skipAutoProtocol = true;
      _protocol = v;
      if (widget.validate && widget.controller.text.trim().isNotEmpty) {
        final full = buildServerUrl(widget.controller.text, v);
        if (full != _lastValidated) {
          _valid = false;
          _notify(false);
        }
        _checking = true;
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 800), _check);
      }
      _skipAutoProtocol = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          key: widget.fieldKey,
          controller: widget.controller,
          keyboardType: TextInputType.url,
          textInputAction: widget.textInputAction,
          autocorrect: false,
          enableSuggestions: false,
          autofocus: widget.autofocus,
          onFieldSubmitted: (_) {
        if (widget.onSubmitted != null) {
          widget.onSubmitted!();
        } else {
          checkNow();
        }
      },
          style: TextStyle(color: cs.onSurface),
          decoration: InputDecoration(
            labelText: widget.label ?? l.loginServerAddress,
            hintText: widget.hint ?? l.loginServerHint,
            helperText: widget.helperText ?? l.loginServerHelper,
            helperStyle: TextStyle(
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
              fontSize: 11,
            ),
            helperMaxLines: 2,
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _protocol,
                  isDense: true,
                  style: TextStyle(
                    color: cs.primary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'https://',
                      child: Text('https://'),
                    ),
                    DropdownMenuItem(
                      value: 'http://',
                      child: Text('http://'),
                    ),
                  ],
                  onChanged: _onProtocolChanged,
                ),
              ),
            ),
            suffixIcon: !widget.validate
                ? null
                : _checking
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _valid
                        ? Icon(Icons.check_circle_rounded,
                            color: Colors.green.shade400, size: 22)
                        : _error != null
                            ? Icon(Icons.error_outline_rounded,
                                color: cs.error, size: 22)
                            : null,
            errorText: widget.validate ? _error : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.2),
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: !widget.validate
                    ? cs.outlineVariant.withValues(alpha: 0.15)
                    : _valid
                        ? Colors.green.shade400.withValues(alpha: 0.4)
                        : _error != null
                            ? cs.error.withValues(alpha: 0.4)
                            : cs.outlineVariant.withValues(alpha: 0.15),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  BorderSide(color: cs.primary.withValues(alpha: 0.6), width: 1.5),
            ),
            filled: true,
            fillColor: cs.surface.withValues(alpha: 0.4),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          ),
        ),
        if (widget.validate && _errorDetail != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _errorDetail!,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
