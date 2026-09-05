/// Device-local watch library for one provider scope.
///
/// This JSON document is the unit a future paid **Wangcow Continuity**
/// service would host so favorites, resume positions, and watched flags
/// follow the user across devices. Local sdtv still stores it only on
/// device — no account, no network. See `docs/LIBRARY.md`.
class UserLibrary {
  const UserLibrary({
    this.favorites = const [],
    this.progressSeconds = const {},
    this.watchedKeys = const [],
    this.seriesResume = const {},
  });

  static const schemaVersion = 1;

  static const empty = UserLibrary();

  /// Ordered favorite keys (`i:` / `u:` live, `v:` movies, `s:` shows).
  final List<String> favorites;

  /// Continue-watching: movie `v:` or episode `se:` → seconds.
  final Map<String, int> progressSeconds;

  /// Finished titles: movie `v:`, episode `se:`, completed series `s:`.
  final List<String> watchedKeys;

  /// Last episode per series id: episodeId, season, episodeNum.
  final Map<String, Map<String, String>> seriesResume;

  bool get isEmpty =>
      favorites.isEmpty &&
      progressSeconds.isEmpty &&
      watchedKeys.isEmpty &&
      seriesResume.isEmpty;

  static bool isVodFavoriteKey(String key) =>
      key.startsWith('v:') || key.startsWith('vn:');

  static bool isSeriesFavoriteKey(String key) => key.startsWith('s:');

  static bool isLiveFavoriteKey(String key) =>
      !isVodFavoriteKey(key) && !isSeriesFavoriteKey(key);

  UserLibrary copyWith({
    List<String>? favorites,
    Map<String, int>? progressSeconds,
    List<String>? watchedKeys,
    Map<String, Map<String, String>>? seriesResume,
  }) {
    return UserLibrary(
      favorites: favorites ?? this.favorites,
      progressSeconds: progressSeconds ?? this.progressSeconds,
      watchedKeys: watchedKeys ?? this.watchedKeys,
      seriesResume: seriesResume ?? this.seriesResume,
    );
  }

  UserLibrary withFavoriteToggled(String key) {
    if (key.isEmpty) return this;
    final list = List<String>.from(favorites);
    if (list.contains(key)) {
      list.remove(key);
    } else {
      list.add(key);
    }
    return copyWith(favorites: list);
  }

  UserLibrary withProgress(String key, int seconds) {
    if (key.isEmpty) return this;
    final m = Map<String, int>.from(progressSeconds);
    if (seconds <= 5) {
      m.remove(key);
    } else {
      m[key] = seconds;
    }
    return copyWith(progressSeconds: m);
  }

  UserLibrary withWatched(String key) {
    if (key.isEmpty || watchedKeys.contains(key)) return this;
    return copyWith(watchedKeys: [...watchedKeys, key]);
  }

  UserLibrary withSeriesResume({
    required String seriesId,
    required String episodeId,
    required int season,
    required int episodeNum,
  }) {
    if (seriesId.isEmpty || episodeId.isEmpty) return this;
    final m = <String, Map<String, String>>{
      for (final e in seriesResume.entries)
        e.key: Map<String, String>.from(e.value),
    };
    m[seriesId] = {
      'episodeId': episodeId,
      'season': '$season',
      'episodeNum': '$episodeNum',
    };
    return copyWith(seriesResume: m);
  }

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'favorites': favorites,
        'progress': progressSeconds,
        'watched': watchedKeys,
        'seriesResume': {
          for (final e in seriesResume.entries) e.key: e.value,
        },
      };

  factory UserLibrary.fromJson(Map<dynamic, dynamic> json) {
    final favorites = <String>[];
    final rawFav = json['favorites'];
    if (rawFav is List) {
      final seen = <String>{};
      for (final x in rawFav) {
        final k = '$x';
        if (k.isEmpty || !seen.add(k)) continue;
        favorites.add(k);
      }
    }

    final progress = <String, int>{};
    final rawProgress = json['progress'];
    if (rawProgress is Map) {
      for (final e in rawProgress.entries) {
        final sec = e.value is int
            ? e.value as int
            : int.tryParse('${e.value}') ?? 0;
        if (sec > 0) progress['${e.key}'] = sec;
      }
    }

    final watched = <String>[];
    final rawWatched = json['watched'];
    if (rawWatched is List) {
      final seen = <String>{};
      for (final x in rawWatched) {
        final k = '$x';
        if (k.isEmpty || !seen.add(k)) continue;
        watched.add(k);
      }
    }

    final resume = <String, Map<String, String>>{};
    final rawResume = json['seriesResume'];
    if (rawResume is Map) {
      for (final e in rawResume.entries) {
        final id = '${e.key}';
        final val = e.value;
        if (id.isEmpty || val is! Map) continue;
        final inner = <String, String>{};
        for (final p in val.entries) {
          final v = '${p.value}';
          if (v.isNotEmpty) inner['${p.key}'] = v;
        }
        if (inner.isNotEmpty) resume[id] = inner;
      }
    }

    return UserLibrary(
      favorites: favorites,
      progressSeconds: progress,
      watchedKeys: watched,
      seriesResume: resume,
    );
  }
}
