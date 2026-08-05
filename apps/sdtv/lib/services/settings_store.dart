import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv_core/sdtv_core.dart';

import 'saved_source.dart';

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
  /// JSON map: scope → list of hidden category_id strings.
  static const _kHiddenCategories = 'hidden_categories.v1';
  /// JSON map: scope → { categoryId, favoriteKey, name }.
  static const _kLastPlayed = 'last_played.v1';
  /// JSON list of [SavedSource] maps.
  static const _kSavedSources = 'saved_sources.v1';
  static const _kActiveSourceId = 'saved_sources.activeId';

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
    // Favorites, hidden categories, last-played, saved sources kept across sign-out.
  }

  // —— Saved playlists / panels (multi-source) ——

  String? get activeSourceId {
    final id = _prefs.getString(_kActiveSourceId);
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> setActiveSourceId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(_kActiveSourceId);
    } else {
      await _prefs.setString(_kActiveSourceId, id);
    }
  }

  List<SavedSource> savedSources() {
    final raw = _prefs.getString(_kSavedSources);
    if (raw == null || raw.isEmpty) {
      return _migrateLegacyIntoSavedSourcesSync();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <SavedSource>[];
      for (final item in decoded) {
        if (item is Map) {
          final s = SavedSource.fromJson(Map<String, dynamic>.from(item));
          if (s.id.isNotEmpty) out.add(s);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// One-time: seed saved list from legacy single-session fields if empty.
  List<SavedSource> _migrateLegacyIntoSavedSourcesSync() {
    final seeded = <SavedSource>[];
    final m3u = m3uUrl;
    if (m3u != null && m3u.isNotEmpty) {
      seeded.add(SavedSource.m3u(url: m3u));
    }
    final creds = credentials;
    if (creds != null) {
      seeded.add(SavedSource.xtream(credentials: creds));
    }
    if (seeded.isEmpty) return const [];
    // Persist async-friendly: write immediately (sync API via setString).
    // ignore: discarded_futures
    _writeSavedSources(seeded);
    return seeded;
  }

  Future<void> _writeSavedSources(List<SavedSource> list) async {
    await _prefs.setString(
      _kSavedSources,
      jsonEncode(list.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> upsertSavedSource(SavedSource source) async {
    if (source.id.isEmpty) return;
    final list = List<SavedSource>.from(savedSources());
    final i = list.indexWhere((s) => s.id == source.id);
    if (i >= 0) {
      list[i] = source;
    } else {
      list.add(source);
    }
    await _writeSavedSources(list);
    await setActiveSourceId(source.id);
  }

  Future<void> removeSavedSource(String id) async {
    final list = savedSources().where((s) => s.id != id).toList();
    await _writeSavedSources(list);
    if (activeSourceId == id) {
      await setActiveSourceId(null);
    }
  }
}

  // —— Scoped string-list maps (favorites, hidden categories) ——

  Map<String, List<String>> _stringListMap(String prefKey) {
    final raw = _prefs.getString(prefKey);
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

  Future<void> _setStringListMap(
    String prefKey,
    String scope,
    List<String> keys,
  ) async {
    if (scope.isEmpty) return;
    final map = _stringListMap(prefKey);
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
    await _prefs.setString(prefKey, jsonEncode(map));
  }

  // —— Favorites (scoped by playlist / panel) ——

  /// Favorite channel keys for a provider scope (see [SessionController.favoritesScope]).
  List<String> favoriteKeys(String scope) {
    if (scope.isEmpty) return const [];
    return List<String>.from(_stringListMap(_kFavorites)[scope] ?? const []);
  }

  Future<void> setFavoriteKeys(String scope, List<String> keys) async {
    await _setStringListMap(_kFavorites, scope, keys);
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

  // —— Hidden categories (scoped by playlist / panel) ——

  List<String> hiddenCategoryIds(String scope) {
    if (scope.isEmpty) return const [];
    return List<String>.from(
      _stringListMap(_kHiddenCategories)[scope] ?? const [],
    );
  }

  Future<void> setHiddenCategoryIds(String scope, List<String> ids) async {
    await _setStringListMap(_kHiddenCategories, scope, ids);
  }

  /// Returns true if [categoryId] is now hidden.
  Future<bool> toggleHiddenCategoryId(String scope, String categoryId) async {
    final list = hiddenCategoryIds(scope);
    final had = list.contains(categoryId);
    if (had) {
      list.remove(categoryId);
    } else {
      list.add(categoryId);
    }
    await setHiddenCategoryIds(scope, list);
    return !had;
  }

  // —— Last played channel (scoped by playlist / panel) ——

  /// Returns map with keys: categoryId, favoriteKey, name (all optional strings).
  Map<String, String> lastPlayed(String scope) {
    if (scope.isEmpty) return const {};
    final raw = _prefs.getString(_kLastPlayed);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final entry = decoded[scope];
      if (entry is! Map) return const {};
      final out = <String, String>{};
      for (final e in entry.entries) {
        final v = '${e.value}';
        if (v.isNotEmpty) out['${e.key}'] = v;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<void> setLastPlayed(
    String scope, {
    required String categoryId,
    required String favoriteKey,
    String name = '',
    int? streamId,
  }) async {
    if (scope.isEmpty || favoriteKey.isEmpty) return;
    final raw = _prefs.getString(_kLastPlayed);
    Map<String, dynamic> root = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          root = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    root[scope] = {
      'categoryId': categoryId,
      'favoriteKey': favoriteKey,
      if (name.isNotEmpty) 'name': name,
      if (streamId != null && streamId != 0) 'streamId': '$streamId',
    };
    await _prefs.setString(_kLastPlayed, jsonEncode(root));
  }
}
