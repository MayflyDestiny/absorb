import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/server_url.dart';
import 'api_service.dart';
import 'auth_tokens.dart';
import 'server_backend.dart';

/// Represents a saved user account (server + credentials).
class SavedAccount {
  final String serverUrl;
  final String username;
  final String token; // accessToken (or legacy token for old servers)
  final String? refreshToken;
  final String? userId;
  final bool isLegacyToken;
  final Map<String, String> customHeaders;
  final ServerBackend backend;

  /// The scope this account's data lives under, once it has been pinned.
  /// Stays fixed when the account's URL is edited (a dynamic-DNS change, a
  /// mirror address), so the per-user data does not have to be migrated.
  final String? pinnedScopeKey;

  SavedAccount({
    required this.serverUrl,
    required this.username,
    required this.token,
    this.refreshToken,
    this.userId,
    this.isLegacyToken = false,
    Map<String, String> customHeaders = const {},
    this.backend = ServerBackend.audiobookshelf,
    this.pinnedScopeKey,
  }) : customHeaders = Map.unmodifiable(customHeaders);

  /// Unique key for scoping per-user SharedPreferences data. Pinned per
  /// account once saved; otherwise derived from serverUrl + username.
  String get scopeKey => pinnedScopeKey ?? _derivedScopeKey;

  String get _derivedScopeKey {
    // Normalize: strip protocol and trailing slashes for consistency
    final cleanUrl = serverUrl
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/+$'), '');
    return '${cleanUrl}_$username';
  }

  /// Rebuild this account with [scope] pinned, keeping all other fields.
  SavedAccount withPinnedScope(String scope) => SavedAccount(
        serverUrl: serverUrl,
        username: username,
        token: token,
        refreshToken: refreshToken,
        userId: userId,
        isLegacyToken: isLegacyToken,
        customHeaders: customHeaders,
        backend: backend,
        pinnedScopeKey: scope,
      );

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'username': username,
        'token': token,
        if (refreshToken != null) 'refreshToken': refreshToken,
        'userId': userId,
        'isLegacyToken': isLegacyToken,
        'customHeaders': customHeaders,
        'backend': backend.key,
        'scopeKey': scopeKey,
      };

  factory SavedAccount.fromJson(
    Map<String, dynamic> json, {
    Map<String, String> legacyCustomHeaders = const {},
  }) =>
      SavedAccount(
        serverUrl: json['serverUrl'] as String,
        username: json['username'] as String,
        token: json['token'] as String,
        refreshToken: json['refreshToken'] as String?,
        userId: json['userId'] as String?,
        isLegacyToken: json['isLegacyToken'] as bool? ?? (json['refreshToken'] == null),
        customHeaders: json.containsKey('customHeaders')
            ? Map<String, String>.from(json['customHeaders'] as Map? ?? const {})
            : legacyCustomHeaders,
        backend: ServerBackend.fromKey(json['backend'] as String?),
        pinnedScopeKey: (json['scopeKey'] as String?)?.isNotEmpty == true
            ? json['scopeKey'] as String
            : null,
      );

  @override
  bool operator ==(Object other) =>
      other is SavedAccount &&
      other.serverUrl == serverUrl &&
      other.username == username;

  @override
  int get hashCode => Object.hash(serverUrl, username);
}

/// Manages multiple saved user accounts and provides scoped storage keys.
///
/// Downloads (audio files on disk) are shared across all users — there's no
/// point re-downloading the same audiobook for a different user on the same
/// device. But progress, absorbing lists, playback history, bookmarks, and
/// metadata overrides are all scoped per-user.
class UserAccountService {
  static final UserAccountService _instance = UserAccountService._();
  factory UserAccountService() => _instance;
  UserAccountService._();

  static const _accountsKey = 'saved_accounts';
  static const _activeKey = 'active_account_scope';
  static const _scopeHintsKey = 'account_scope_hints';

  /// Runs before a sign-in changes the active account, so anything still
  /// being recorded for the old one is saved under it first.
  static Future<void> Function(SavedAccount next)? beforeAccountChange;

  List<SavedAccount> _accounts = [];
  // URL|username -> pinned scope for accounts whose data must survive a
  // remove/re-add. Only pinned (URL-edited) accounts need one; a derived
  // scope re-derives identically.
  Map<String, String> _scopeHints = {};
  String? _activeScopeKey;

  List<SavedAccount> get accounts => List.unmodifiable(_accounts);
  String get activeScopeKey => _activeScopeKey ?? '';

  static String _hintKey(String serverUrl, String username) =>
      '$serverUrl|$username';

  /// Initialise from SharedPreferences. Call once at app startup.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    var legacyCustomHeaders = <String, String>{};
    final headersJson = prefs.getString('custom_headers');
    if (headersJson != null) {
      try {
        legacyCustomHeaders =
            Map<String, String>.from(jsonDecode(headersJson) as Map);
      } catch (_) {}
    }

    // Load saved accounts
    final json = prefs.getString(_accountsKey);
    if (json != null) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        _accounts = list
            .map((e) => SavedAccount.fromJson(
                  e as Map<String, dynamic>,
                  legacyCustomHeaders: legacyCustomHeaders,
                ))
            .toList();
      } catch (e) {
        debugPrint('[UserAccount] Failed to load accounts: $e');
      }
    }
    try {
      final hints = prefs.getString(_scopeHintsKey);
      if (hints != null) {
        _scopeHints = Map<String, String>.from(jsonDecode(hints) as Map);
      }
    } catch (_) {}

    // Load active scope
    _activeScopeKey = prefs.getString(_activeKey);
    debugPrint('[UserAccount] Loaded ${_accounts.length} accounts, active=$_activeScopeKey');
    await _alignScopeWithSession(prefs);
  }

  /// The signed-in session lives in the plain server_url / username keys
  /// while everything per account is stored under the active scope. If the
  /// two ever disagree, the app talks to the server as one user but saves
  /// progress and settings under another, so trust the session and point the
  /// scope back at it.
  Future<void> _alignScopeWithSession(SharedPreferences prefs) async {
    final server = prefs.getString('server_url');
    final username = prefs.getString('username');
    if (server == null || username == null || username.isEmpty) return;
    SavedAccount? match;
    for (final a in _accounts) {
      if (a.username == username &&
          normalizeServerUrl(a.serverUrl) == normalizeServerUrl(server)) {
        match = a;
        break;
      }
    }
    if (match == null || match.scopeKey == _activeScopeKey) return;
    debugPrint('[UserAccount] Active scope $_activeScopeKey did not match the '
        'signed-in $username - switching the scope to ${match.scopeKey}');
    _activeScopeKey = match.scopeKey;
    await _persistActiveKey();
  }

  /// Save or update an account after login. Sets it as active.
  Future<void> saveAccount(SavedAccount account) async {
    // Nothing in here may stop the account being saved: a sign-in that got
    // this far has already written the new session, and bailing out now
    // leaves the old account's scope active under it.
    try {
      await beforeAccountChange?.call(account);
    } catch (e) {
      debugPrint('[UserAccount] beforeAccountChange failed: $e');
    }
    // Re-login on the same server+username must keep the scope its data was
    // pinned to (the account's URL may have been edited since it was added).
    final previous = _accounts.where(
      (a) => a.serverUrl == account.serverUrl && a.username == account.username,
    );
    final hinted = _scopeHints[_hintKey(account.serverUrl, account.username)];
    final pinned = previous.isEmpty ? hinted : previous.first.pinnedScopeKey;
    final saved = pinned == null ? account : account.withPinnedScope(pinned);
    if (previous.isEmpty && hinted != null) {
      _scopeHints.remove(_hintKey(account.serverUrl, account.username));
      await _persistScopeHints();
    }
    _accounts.removeWhere(
        (a) => a.serverUrl == saved.serverUrl && a.username == saved.username);
    _accounts.insert(0, saved); // Most recent first
    _activeScopeKey = saved.scopeKey;
    await _persist();
    debugPrint('[UserAccount] Saved & activated: ${saved.username}@${saved.serverUrl}');
  }

  /// Switch to a different saved account. Returns the account or null if not found.
  SavedAccount? switchTo(String serverUrl, String username) {
    final account = _accounts.firstWhere(
      (a) => a.serverUrl == serverUrl && a.username == username,
      orElse: () => SavedAccount(serverUrl: '', username: '', token: ''),
    );
    if (account.token.isEmpty) return null;
    _activeScopeKey = account.scopeKey;
    _persistActiveKey();
    debugPrint('[UserAccount] Switched to: ${account.username}@${account.serverUrl}');
    return account;
  }

  /// Remove a saved account. Does NOT delete its scoped data (in case the
  /// user wants to re-add later). Returns true if found and removed.
  Future<bool> removeAccount(String serverUrl, String username) async {
    final index = _accounts.indexWhere(
        (a) => a.serverUrl == serverUrl && a.username == username);
    if (index < 0) return false;
    final removed = _accounts.removeAt(index);
    if (removed.pinnedScopeKey != null) {
      // A pinned scope would otherwise be unreachable after a re-add: remember
      // it by the connection the user will type again.
      _scopeHints[_hintKey(removed.serverUrl, removed.username)] =
          removed.scopeKey;
      await _persistScopeHints();
    }
    await _persist();
    debugPrint('[UserAccount] Removed: $username@$serverUrl');
    return true;
  }

  /// Update tokens for the active account (e.g. after token refresh).
  Future<void> updateTokens(String serverUrl, String username, String newToken, {String? refreshToken}) async {
    final idx = _accounts.indexWhere(
        (a) => a.serverUrl == serverUrl && a.username == username);
    if (idx >= 0) {
      final old = _accounts[idx];
      if (old.token == newToken &&
          (refreshToken == null || old.refreshToken == refreshToken)) {
        return;
      }
      _accounts[idx] = SavedAccount(
        serverUrl: old.serverUrl,
        username: old.username,
        token: newToken,
        refreshToken: refreshToken ?? old.refreshToken,
        userId: old.userId,
        isLegacyToken: old.isLegacyToken,
        customHeaders: old.customHeaders,
        backend: old.backend,
        pinnedScopeKey: old.scopeKey,
      );
      await _persist();
    }
  }

  /// Persist tokens refreshed outside the live session (background isolates,
  /// widget cold paths). The server rotates refresh tokens - each one is
  /// single-use - so a refresh whose result is only kept in memory strands
  /// the on-disk session with an expired access token and a consumed refresh
  /// token, and the next app launch can't sign in.
  /// Persist a rotated token pair. Returns whether the pair actually reached
  /// storage.
  ///
  /// The server rotates refresh tokens single-use, so a new access token stored
  /// beside the PREVIOUS refresh token is a dead session: the stored refresh
  /// token has already been spent and every later refresh 401s, with no way
  /// back short of a re-login. That is exactly what happened on 2026-08-13.
  ///
  /// SharedPreferences has no multi-key transaction, so the two keys are
  /// written in the order that makes a crash between them survivable: refresh
  /// FIRST. Dying after it leaves the old access token beside the NEW refresh
  /// token, which self-heals - the stale access token 401s and the refresh
  /// succeeds. The other order is the unrecoverable one. The write is also read
  /// back before it is called a success.
  Future<bool> persistRefreshedTokens(
    String accessToken,
    String? refreshToken, {
    required String serverUrl,
    required String? username,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final activeServer = prefs.getString('server_url');
    final activeUsername = prefs.getString('username');
    if (activeServer == null ||
        normalizeServerUrl(activeServer) != normalizeServerUrl(serverUrl) ||
        activeUsername != username) {
      debugPrint(
        '[Accounts] Not persisting rotated tokens: active session is '
        '${activeServer == null ? "(none)" : "$activeUsername@$activeServer"}, '
        'rotation was for $username@$serverUrl',
      );
      return false;
    }
    // Half a pair is worse than none: keep the old, still-valid pair rather
    // than pairing a fresh access token with a spent refresh token.
    if (refreshToken == null && prefs.getString('refresh_token') != null) {
      debugPrint(
        '[Accounts] Not persisting rotated tokens: response carried no refresh '
        'token and storage already holds one - refusing to store half a pair',
      );
      return false;
    }
    if (refreshToken != null) await prefs.setString('refresh_token', refreshToken);
    await prefs.setString('token', accessToken);
    if (username != null) {
      if (_accounts.isEmpty) await init();
      await updateTokens(serverUrl, username, accessToken, refreshToken: refreshToken);
    }
    // Read back: another isolate holding stale state can clobber these keys
    // between the write and the next launch, and the failure is silent until
    // the session is already dead.
    await prefs.reload();
    final storedAccess = prefs.getString('token');
    final storedRefresh = prefs.getString('refresh_token');
    if (storedAccess != accessToken ||
        (refreshToken != null && storedRefresh != refreshToken)) {
      debugPrint(
        '[Accounts] Rotated tokens did NOT survive the write: '
        'wrote access=${ApiService.tokenFp(accessToken)} '
        'refresh=${ApiService.tokenFp(refreshToken)}, '
        'read back access=${ApiService.tokenFp(storedAccess)} '
        'refresh=${ApiService.tokenFp(storedRefresh)}',
      );
      return false;
    }
    return true;
  }

  /// Reload the active session from disk. SharedPreferences keeps an
  /// isolate-local cache, so reload is required before a foreground client can
  /// see a token rotation performed by background work.
  Future<AuthTokens?> loadPersistedTokens(
      String serverUrl, String? username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final activeServer = prefs.getString('server_url');
    final activeUsername = prefs.getString('username');
    if (activeServer == null ||
        normalizeServerUrl(activeServer) != normalizeServerUrl(serverUrl) ||
        activeUsername != username) {
      return null;
    }
    final accessToken = prefs.getString('token');
    if (accessToken == null || accessToken.isEmpty) return null;
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: prefs.getString('refresh_token'),
    );
  }

  /// Keep the server/account available for a prefilled re-login while making
  /// sure a rejected token cannot be quick-switched back into the app.
  Future<void> clearTokens(String serverUrl, String username) async {
    final idx = _accounts.indexWhere(
        (a) => a.serverUrl == serverUrl && a.username == username);
    if (idx < 0) return;
    final old = _accounts[idx];
    _accounts[idx] = SavedAccount(
      serverUrl: old.serverUrl,
      username: old.username,
      token: '',
      userId: old.userId,
      isLegacyToken: old.isLegacyToken,
      customHeaders: old.customHeaders,
      backend: old.backend,
      pinnedScopeKey: old.scopeKey,
    );
    await _persist();
  }

  /// Change the server URL of a saved account (e.g. a dynamic-DNS hostname
  /// changed) WITHOUT losing the account's per-user data. The data scope is
  /// pinned to the account, so it stays valid under the new URL and nothing
  /// has to be copied. Returns true if the account was found.
  Future<bool> updateAccountUrl(
      String oldServerUrl, String username, String newServerUrl) async {
    final index = _accounts.indexWhere(
        (a) => a.serverUrl == oldServerUrl && a.username == username);
    if (index < 0) return false;
    return updateAccountConnection(
      oldServerUrl,
      username,
      newServerUrl,
      _accounts[index].customHeaders,
    );
  }

  /// Update the URL and proxy headers for one saved account. The account keeps
  /// its pinned scope, so stats, progress and downloads stay attached to it
  /// without migrating every stored key.
  Future<bool> updateAccountConnection(
    String oldServerUrl,
    String username,
    String newServerUrl,
    Map<String, String> customHeaders,
  ) async {
    final sw = Stopwatch()..start();
    final idx = _accounts.indexWhere(
        (a) => a.serverUrl == oldServerUrl && a.username == username);
    if (idx < 0) return false;

    final old = _accounts[idx];
    final updated = SavedAccount(
      serverUrl: newServerUrl,
      username: old.username,
      token: old.token,
      refreshToken: old.refreshToken,
      userId: old.userId,
      isLegacyToken: old.isLegacyToken,
      customHeaders: customHeaders,
      backend: old.backend,
      pinnedScopeKey: old.scopeKey,
    );

    _accounts[idx] = updated;
    // The scope did not change, but keep the pointer aligned if it was this
    // account's.
    if (_activeScopeKey == old.scopeKey) {
      _activeScopeKey = updated.scopeKey;
    }
    await _persist();
    debugPrint(
        '[UserAccount] Updated server URL for $username: $oldServerUrl -> '
        '$newServerUrl in ${sw.elapsedMilliseconds}ms (data scope kept)');
    return true;
  }

  // ── Scoped key helpers ──────────────────────────────────

  /// Returns a SharedPreferences key scoped to the active user.
  /// Example: `scopedKey('progress_li_123')` → `abs.example.com_nathan:progress_li_123`
  String scopedKey(String key) {
    if (_activeScopeKey == null || _activeScopeKey!.isEmpty) return key;
    return '$_activeScopeKey:$key';
  }

  /// Check if we have a scope (i.e. at least one login has occurred).
  bool get hasScope => _activeScopeKey != null && _activeScopeKey!.isNotEmpty;

  // ── Persistence ─────────────────────────────────────────

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_accounts.map((a) => a.toJson()).toList());
    await prefs.setString(_accountsKey, json);
    if (_activeScopeKey != null) {
      await prefs.setString(_activeKey, _activeScopeKey!);
    }
  }

  Future<void> _persistActiveKey() async {
    final prefs = await SharedPreferences.getInstance();
    if (_activeScopeKey != null) {
      await prefs.setString(_activeKey, _activeScopeKey!);
    }
  }

  Future<void> _persistScopeHints() async {
    final prefs = await SharedPreferences.getInstance();
    if (_scopeHints.isEmpty) {
      await prefs.remove(_scopeHintsKey);
    } else {
      await prefs.setString(_scopeHintsKey, jsonEncode(_scopeHints));
    }
  }
}
