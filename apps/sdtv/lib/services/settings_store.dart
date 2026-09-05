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
  /// Legacy; new writes go to [_kUserLibrary].
  static const _kFavorites = 'favorites.v1';
  /// JSON map: scope → [UserLibrary] document (favorites, progress, watched).
  static const _kUserLibrary = 'user_library.v1';
  /// JSON map: scope → list of hidden category_id strings.
  static const _kHiddenCategories = 'hidden_categories.v1';
  /// JSON map: scope → { categoryId, favoriteKey, name }.
  static const _kLastPlayed = 'last_played.v1';
  /// JSON list of [SavedSource] maps.
  static const _kSavedSources = 'saved_sources.v1';
  static const _kActiveSourceId = 'saved_sources.activeId';
  /// JSON map: scope → { vodKey → seconds }.
  static const _kVodProgress = 'vod_progress.v1';
  /// JSON map: scope → list of watched movie / episode / series keys.
  static const _kVodWatched = 'vod_watched.v1';
  /// JSON map: scope → { section: live|movies, vodCategoryId }.
  static const _kGuideLanding = 'guide_landing.v1';

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

  // —— User library (favorites + resume + watched; future sync document) ——

  final Map<String, UserLibrary> _libraryCache = {};

  UserLibrary library(String scope) {
    if (scope.isEmpty) return UserLibrary.empty;
    final cached = _libraryCache[scope];
    if (cached != null) return cached;
    final loaded = _readLibrary(scope) ?? _legacyLibrary(scope);
    _libraryCache[scope] = loaded;
    return loaded;
  }

  UserLibrary? _readLibrary(String scope) {
    final raw = _prefs.getString(_kUserLibrary);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entry = decoded[scope];
      if (entry is! Map) return null;
      return UserLibrary.fromJson(entry);
    } catch (_) {
      return null;
    }
  }

  UserLibrary _legacyLibrary(String scope) {
    return UserLibrary(
      favorites: List<String>.from(_stringListMap(_kFavorites)[scope] ?? const []),
      progressSeconds: Map<String, int>.from(_vodProgressRoot()[scope] ?? const {}),
      watchedKeys: List<String>.from(_stringListMap(_kVodWatched)[scope] ?? const []),
      seriesResume: _legacySeriesResume(scope),
    );
  }

  Map<String, Map<String, String>> _legacySeriesResume(String scope) {
    final raw = _prefs.getString(_kSeriesResume);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final byScope = decoded[scope];
      if (byScope is! Map) return const {};
      final out = <String, Map<String, String>>{};
      for (final e in byScope.entries) {
        final id = '${e.key}';
        final val = e.value;
        if (id.isEmpty || val is! Map) continue;
        final inner = <String, String>{};
        for (final p in val.entries) {
          final v = '${p.value}';
          if (v.isNotEmpty) inner['${p.key}'] = v;
        }
        if (inner.isNotEmpty) out[id] = inner;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<void> _setLibrary(String scope, UserLibrary lib) async {
    if (scope.isEmpty) return;
    _libraryCache[scope] = lib;
    final raw = _prefs.getString(_kUserLibrary);
    Map<String, dynamic> root = {};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) root = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    // Always persist, including empty — otherwise a cleared library would
    // fall back to stale legacy favorites.v1 / vod_progress.v1 keys.
    root[scope] = lib.toJson();
    await _prefs.setString(_kUserLibrary, jsonEncode(root));
  }

  // —— Favorites (scoped by playlist / panel) ——

  /// Favorite keys for a provider scope (live `i:`, movies `v:`, shows `s:`).
  List<String> favoriteKeys(String scope) {
    if (scope.isEmpty) return const [];
    return List<String>.from(library(scope).favorites);
  }

  Future<void> setFavoriteKeys(String scope, List<String> keys) async {
    await _setLibrary(scope, library(scope).copyWith(favorites: keys));
  }

  Future<bool> toggleFavoriteKey(String scope, String key) async {
    if (scope.isEmpty || key.isEmpty) return false;
    final lib = library(scope);
    final had = lib.favorites.contains(key);
    await _setLibrary(scope, lib.withFavoriteToggled(key));
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

  /// Last guide tab + Movies category (not last-played live channel).
  Map<String, String> guideLanding(String scope) {
    if (scope.isEmpty) return const {};
    final raw = _prefs.getString(_kGuideLanding);
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

  Future<void> setGuideLanding(
    String scope, {
    required String section,
    String? vodCategoryId,
    String? seriesCategoryId,
  }) async {
    if (scope.isEmpty) return;
    final raw = _prefs.getString(_kGuideLanding);
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
      'section': section,
      if (vodCategoryId != null && vodCategoryId.isNotEmpty)
        'vodCategoryId': vodCategoryId,
      if (seriesCategoryId != null && seriesCategoryId.isNotEmpty)
        'seriesCategoryId': seriesCategoryId,
    };
    await _prefs.setString(_kGuideLanding, jsonEncode(root));
  }

  // —— VOD continue-watching (seconds, scoped) ——

  Map<String, Map<String, int>> _vodProgressRoot() {
    final raw = _prefs.getString(_kVodProgress);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, Map<String, int>>{};
      for (final e in decoded.entries) {
        final inner = e.value;
        if (inner is! Map) continue;
        final m = <String, int>{};
        for (final p in inner.entries) {
          final sec = p.value is int
              ? p.value as int
              : int.tryParse('${p.value}') ?? 0;
          if (sec > 0) m['${p.key}'] = sec;
        }
        if (m.isNotEmpty) out['${e.key}'] = m;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  int vodProgressSeconds(String scope, String vodKey) {
    if (scope.isEmpty || vodKey.isEmpty) return 0;
    return library(scope).progressSeconds[vodKey] ?? 0;
  }

  Future<void> setVodProgressSeconds(
    String scope,
    String vodKey,
    int seconds,
  ) async {
    if (scope.isEmpty || vodKey.isEmpty) return;
    await _setLibrary(scope, library(scope).withProgress(vodKey, seconds));
  }

  // —— Watched movies / episodes / completed series (scoped) ——

  List<String> watchedKeys(String scope) {
    if (scope.isEmpty) return const [];
    return List<String>.from(library(scope).watchedKeys);
  }

  Future<void> setWatchedKeys(String scope, List<String> keys) async {
    await _setLibrary(scope, library(scope).copyWith(watchedKeys: keys));
  }

  Future<void> addWatchedKey(String scope, String key) async {
    if (scope.isEmpty || key.isEmpty) return;
    await _setLibrary(scope, library(scope).withWatched(key));
  }

  static const _kSeriesResume = 'series_resume.v1';

  /// Last episode for a series: episodeId, season, episodeNum.
  Map<String, String> seriesResume(String scope, String seriesId) {
    if (scope.isEmpty || seriesId.isEmpty) return const {};
    final entry = library(scope).seriesResume[seriesId];
    if (entry == null) return const {};
    return Map<String, String>.from(entry);
  }

  Future<void> setSeriesResume(
    String scope, {
    required String seriesId,
    required String episodeId,
    required int season,
    required int episodeNum,
  }) async {
    await _setLibrary(
      scope,
      library(scope).withSeriesResume(
        seriesId: seriesId,
        episodeId: episodeId,
        season: season,
        episodeNum: episodeNum,
      ),
    );
  }
}
