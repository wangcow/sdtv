import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv_core/sdtv_core.dart';

/// Local-only Xtream credentials + prefs. Never phones home.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kBaseUrl = 'xtream.baseUrl';
  static const _kUsername = 'xtream.username';
  static const _kPassword = 'xtream.password';
  static const _kUseDemo = 'xtream.useDemo';
  static const _kHasSession = 'xtream.hasSession';
  static const _kUseM3u = 'playlist.useM3u';
  static const _kM3uUrl = 'playlist.m3uUrl';
  /// JSON map: scope → list of [LiveChannel.favoriteKey] strings.
  static const _kFavorites = 'favorites.v1';

  static Future<SettingsStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore(prefs);
  }

  bool get hasSavedSession => _prefs.getBool(_kHasSession) ?? false;

  bool get useDemo => _prefs.getBool(_kUseDemo) ?? true;

  bool get useM3u => _prefs.getBool(_kUseM3u) ?? false;

  String? get m3uUrl {
    final u = _prefs.getString(_kM3uUrl);
    if (u == null || u.isEmpty) return null;
    return u;
  }

  XtreamCredentials? get credentials {
    final base = _prefs.getString(_kBaseUrl);
    final user = _prefs.getString(_kUsername);
    final pass = _prefs.getString(_kPassword);
    if (base == null ||
        base.isEmpty ||
        user == null ||
        user.isEmpty ||
        pass == null ||
        pass.isEmpty) {
      return null;
    }
    return XtreamCredentials(
      baseUrl: base,
      username: user,
      password: pass,
    );
  }

  Future<void> saveSession({
    required bool useDemo,
    XtreamCredentials? credentials,
    bool useM3u = false,
    String? m3uUrl,
  }) async {
    await _prefs.setBool(_kUseDemo, useDemo);
    await _prefs.setBool(_kUseM3u, useM3u);
    await _prefs.setBool(_kHasSession, true);
    if (credentials != null) {
      await _prefs.setString(_kBaseUrl, credentials.baseUrl);
      await _prefs.setString(_kUsername, credentials.username);
      await _prefs.setString(_kPassword, credentials.password);
    }
    if (m3uUrl != null && m3uUrl.isNotEmpty) {
      await _prefs.setString(_kM3uUrl, m3uUrl);
    }
  }

  Future<void> clearSession() async {
    await _prefs.remove(_kHasSession);
    await _prefs.remove(_kUseDemo);
    await _prefs.remove(_kUseM3u);
    await _prefs.remove(_kM3uUrl);
    await _prefs.remove(_kBaseUrl);
    await _prefs.remove(_kUsername);
    await _prefs.remove(_kPassword);
    // Favorites intentionally kept across sign-out (per-scope keys remain).
  }

  // —— Favorites (scoped by playlist / panel) ——

  Map<String, List<String>> _favoritesMap() {
    final raw = _prefs.getString(_kFavorites);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, List<String>>{};
      for (final e in decoded.entries) {
        final key = '${e.key}';
        final val = e.value;
        if (val is List) {
          out[key] = val.map((x) => '$x').where((s) => s.isNotEmpty).toList();
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Favorite channel keys for a provider scope (see [SessionController.favoritesScope]).
  List<String> favoriteKeys(String scope) {
    if (scope.isEmpty) return const [];
    return List<String>.from(_favoritesMap()[scope] ?? const []);
  }

  Future<void> setFavoriteKeys(String scope, List<String> keys) async {
    if (scope.isEmpty) return;
    final map = _favoritesMap();
    // Preserve order; drop empties / dups.
    final seen = <String>{};
    final cleaned = <String>[];
    for (final k in keys) {
      if (k.isEmpty || !seen.add(k)) continue;
      cleaned.add(k);
    }
    if (cleaned.isEmpty) {
      map.remove(scope);
    } else {
      map[scope] = cleaned;
    }
    await _prefs.setString(_kFavorites, jsonEncode(map));
  }

  Future<bool> toggleFavoriteKey(String scope, String key) async {
    final list = favoriteKeys(scope);
    final had = list.contains(key);
    if (had) {
      list.remove(key);
    } else {
      list.add(key);
    }
    await setFavoriteKeys(scope, list);
    return !had;
  }
}
