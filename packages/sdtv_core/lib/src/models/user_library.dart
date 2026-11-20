/// Device-local watch library for one provider scope.
///
/// This JSON document is the unit a future paid **Wangcow Continuity**
/// service would host. Favorites, the continue-watching spot, and watched
/// movies / episodes / completed shows travel together. Local sdtv still
/// stores it only on device — no account, no network. [merge] is the
/// conflict rule that host will use. See `docs/LIBRARY.md`.
class UserLibrary {
  const UserLibrary({
    this.favorites = const [],
    this.progressSeconds = const {},
    this.progressUpdatedAt = const {},
    this.watchedKeys = const [],
    this.watchedAt = const {},
    this.seriesResume = const {},
    this.seriesResumeUpdatedAt = const {},
    this.updatedAtMs = 0,
  });

  static const schemaVersion = 1;

  static const empty = UserLibrary();

  /// Ordered favorite keys (`i:` / `u:` live, `v:` movies, `s:` shows).
  final List<String> favorites;

  /// Continue-watching: movie `v:` or episode `se:` → seconds.
  final Map<String, int> progressSeconds;

  /// Unix ms when that playhead was written. A key here with no seconds is
  /// a clear (the title was finished or rewound), so an older device cannot
  /// put the playhead back.
  final Map<String, int> progressUpdatedAt;

  /// Finished titles: movie `v:`, episode `se:`, completed series `s:`.
  final List<String> watchedKeys;

  /// Unix ms when each [watchedKeys] entry was marked watched.
  final Map<String, int> watchedAt;

  /// Last episode per series id: episodeId, season, episodeNum.
  final Map<String, Map<String, String>> seriesResume;

  /// Unix ms when each [seriesResume] entry was written.
  final Map<String, int> seriesResumeUpdatedAt;

  /// Unix ms of the last mutation. Favorite merge uses it for list order.
  final int updatedAtMs;

  bool get isEmpty =>
      favorites.isEmpty &&
      progressSeconds.isEmpty &&
      progressUpdatedAt.isEmpty &&
      watchedKeys.isEmpty &&
      watchedAt.isEmpty &&
      seriesResume.isEmpty &&
      seriesResumeUpdatedAt.isEmpty;

  static bool isVodFavoriteKey(String key) =>
      key.startsWith('v:') || key.startsWith('vn:');

  static bool isSeriesFavoriteKey(String key) => key.startsWith('s:');

  static bool isLiveFavoriteKey(String key) =>
      !isVodFavoriteKey(key) && !isSeriesFavoriteKey(key);

  UserLibrary copyWith({
    List<String>? favorites,
    Map<String, int>? progressSeconds,
    Map<String, int>? progressUpdatedAt,
    List<String>? watchedKeys,
    Map<String, int>? watchedAt,
    Map<String, Map<String, String>>? seriesResume,
    Map<String, int>? seriesResumeUpdatedAt,
    int? updatedAtMs,
  }) {
    return UserLibrary(
      favorites: favorites ?? this.favorites,
      progressSeconds: progressSeconds ?? this.progressSeconds,
      progressUpdatedAt: progressUpdatedAt ?? this.progressUpdatedAt,
      watchedKeys: watchedKeys ?? this.watchedKeys,
      watchedAt: watchedAt ?? this.watchedAt,
      seriesResume: seriesResume ?? this.seriesResume,
      seriesResumeUpdatedAt:
          seriesResumeUpdatedAt ?? this.seriesResumeUpdatedAt,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  UserLibrary withFavoriteToggled(String key, {int? atMs}) {
    if (key.isEmpty) return this;
    final now = _stamp(atMs);
    final list = List<String>.from(favorites);
    if (list.contains(key)) {
      list.remove(key);
    } else {
      list.add(key);
    }
    return copyWith(favorites: list, updatedAtMs: _maxInt(updatedAtMs, now));
  }

  /// [seconds] at or below 5 clears the playhead and leaves a timestamp so
  /// merge will not restore an older spot.
  UserLibrary withProgress(String key, int seconds, {int? atMs}) {
    if (key.isEmpty) return this;
    final now = _stamp(atMs);
    final m = Map<String, int>.from(progressSeconds);
    final at = Map<String, int>.from(progressUpdatedAt);
    if (seconds <= 5) {
      m.remove(key);
    } else {
      m[key] = seconds;
    }
    at[key] = now;
    return copyWith(
      progressSeconds: m,
      progressUpdatedAt: at,
      updatedAtMs: _maxInt(updatedAtMs, now),
    );
  }

  UserLibrary withWatched(String key, {int? atMs}) {
    if (key.isEmpty) return this;
    final now = _stamp(atMs);
    final prev = watchedAt[key] ?? 0;
    if (watchedKeys.contains(key) && prev >= now) return this;
    final at = Map<String, int>.from(watchedAt);
    at[key] = now;
    final keys = watchedKeys.contains(key)
        ? watchedKeys
        : [...watchedKeys, key];
    return copyWith(
      watchedKeys: keys,
      watchedAt: at,
      updatedAtMs: _maxInt(updatedAtMs, now),
    );
  }

  /// Replace the watched set. Existing timestamps are kept; new keys are
  /// stamped [atMs].
  UserLibrary withWatchedKeys(List<String> keys, {int? atMs}) {
    final now = _stamp(atMs);
    final cleaned = <String>[];
    final seen = <String>{};
    for (final key in keys) {
      if (key.isEmpty || !seen.add(key)) continue;
      cleaned.add(key);
    }
    final at = <String, int>{
      for (final key in cleaned) key: watchedAt[key] ?? now,
    };
    return copyWith(
      watchedKeys: cleaned,
      watchedAt: at,
      updatedAtMs: _maxInt(updatedAtMs, now),
    );
  }

  UserLibrary withSeriesResume({
    required String seriesId,
    required String episodeId,
    required int season,
    required int episodeNum,
    int? atMs,
  }) {
    if (seriesId.isEmpty || episodeId.isEmpty) return this;
    final now = _stamp(atMs);
    final m = <String, Map<String, String>>{
      for (final e in seriesResume.entries)
        e.key: Map<String, String>.from(e.value),
    };
    m[seriesId] = {
      'episodeId': episodeId,
      'season': '$season',
      'episodeNum': '$episodeNum',
    };
    final at = Map<String, int>.from(seriesResumeUpdatedAt);
    at[seriesId] = now;
    return copyWith(
      seriesResume: m,
      seriesResumeUpdatedAt: at,
      updatedAtMs: _maxInt(updatedAtMs, now),
    );
  }

  /// One playback sample. Finished titles clear the playhead and record
  /// watched in the same stamp, including [alsoWatched] (a completed show).
  UserLibrary withWatchUpdate({
    required String progressKey,
    required int positionSeconds,
    bool finished = false,
    List<String> alsoWatched = const [],
    String seriesId = '',
    String episodeId = '',
    int season = 0,
    int episodeNum = 0,
    int? atMs,
  }) {
    final now = _stamp(atMs);
    var next = withProgress(
      progressKey,
      finished ? 0 : positionSeconds,
      atMs: now,
    );
    if (finished) {
      next = next.withWatched(progressKey, atMs: now);
      for (final key in alsoWatched) {
        next = next.withWatched(key, atMs: now);
      }
    }
    if (seriesId.isNotEmpty && episodeId.isNotEmpty) {
      next = next.withSeriesResume(
        seriesId: seriesId,
        episodeId: episodeId,
        season: season,
        episodeNum: episodeNum,
        atMs: now,
      );
    }
    return next;
  }

  /// Fold [other] into this document.
  ///
  /// Watched keys union. The newer playhead wins, and a newer clear beats an
  /// older spot. The newer series episode wins. Favorites union; the document
  /// with the greater [updatedAtMs] keeps its order, then any extra stars
  /// from the other copy are appended. Removing a star on only one device
  /// does not win — there is no un-star tombstone yet.
  UserLibrary merge(UserLibrary other) {
    final watched = <String>[];
    final seenWatched = <String>{};
    for (final key in [
      ...watchedKeys,
      ...other.watchedKeys,
      ...watchedAt.keys,
      ...other.watchedAt.keys,
    ]) {
      if (key.isEmpty || !seenWatched.add(key)) continue;
      watched.add(key);
    }
    final watchedTimes = <String, int>{};
    for (final key in watched) {
      final stamp = _maxInt(watchedAt[key] ?? 0, other.watchedAt[key] ?? 0);
      if (stamp > 0) watchedTimes[key] = stamp;
    }

    final progressKeys = <String>{
      ...progressSeconds.keys,
      ...progressUpdatedAt.keys,
      ...other.progressSeconds.keys,
      ...other.progressUpdatedAt.keys,
    };
    final progress = <String, int>{};
    final progressTimes = <String, int>{};
    for (final key in progressKeys) {
      final winner = _newerProgress(_progressMark(key), other._progressMark(key));
      if (winner.at > 0) progressTimes[key] = winner.at;
      if (winner.seconds > 5) progress[key] = winner.seconds;
    }

    final resumeIds = <String>{
      ...seriesResume.keys,
      ...other.seriesResume.keys,
    };
    final resume = <String, Map<String, String>>{};
    final resumeTimes = <String, int>{};
    for (final id in resumeIds) {
      final localAt = seriesResumeUpdatedAt[id] ?? 0;
      final remoteAt = other.seriesResumeUpdatedAt[id] ?? 0;
      final Map<String, String>? chosen;
      final int chosenAt;
      if (remoteAt > localAt) {
        chosen = other.seriesResume[id];
        chosenAt = remoteAt;
      } else if (localAt > remoteAt) {
        chosen = seriesResume[id];
        chosenAt = localAt;
      } else {
        // Same stamp, including legacy 0: keep this device's pointer.
        chosen = seriesResume[id] ?? other.seriesResume[id];
        chosenAt = localAt;
      }
      if (chosen == null || chosen.isEmpty) continue;
      resume[id] = Map<String, String>.from(chosen);
      if (chosenAt > 0) resumeTimes[id] = chosenAt;
    }

    final newerFav = updatedAtMs >= other.updatedAtMs ? this : other;
    final olderFav = identical(newerFav, this) ? other : this;
    final favoritesOut = <String>[];
    final seenFav = <String>{};
    for (final key in [...newerFav.favorites, ...olderFav.favorites]) {
      if (key.isEmpty || !seenFav.add(key)) continue;
      favoritesOut.add(key);
    }

    return UserLibrary(
      favorites: favoritesOut,
      progressSeconds: progress,
      progressUpdatedAt: progressTimes,
      watchedKeys: watched,
      watchedAt: watchedTimes,
      seriesResume: resume,
      seriesResumeUpdatedAt: resumeTimes,
      updatedAtMs: _maxInt(updatedAtMs, other.updatedAtMs),
    );
  }

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'updatedAt': updatedAtMs,
        'favorites': favorites,
        'progress': progressSeconds,
        'progressAt': progressUpdatedAt,
        'watched': watchedKeys,
        'watchedAt': watchedAt,
        'seriesResume': {
          for (final e in seriesResume.entries) e.key: e.value,
        },
        'seriesResumeAt': seriesResumeUpdatedAt,
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
        final sec = _secondsOf(e.value);
        if (sec > 0) progress['${e.key}'] = sec;
      }
    }

    final progressAt = _msMap(json['progressAt']);
    // A progress value may itself be `{s, t}` from a future writer.
    if (rawProgress is Map) {
      for (final e in rawProgress.entries) {
        final embedded = _embeddedMs(e.value);
        if (embedded > 0) progressAt['${e.key}'] = embedded;
      }
    }

    final watched = <String>[];
    final watchedTimes = _msMap(json['watchedAt']);
    final rawWatched = json['watched'];
    if (rawWatched is List) {
      final seen = <String>{};
      for (final x in rawWatched) {
        final k = '$x';
        if (k.isEmpty || !seen.add(k)) continue;
        watched.add(k);
      }
    } else if (rawWatched is Map) {
      for (final e in rawWatched.entries) {
        final k = '${e.key}';
        if (k.isEmpty) continue;
        watched.add(k);
        final stamp = _asMs(e.value);
        if (stamp > 0) watchedTimes[k] = stamp;
      }
    }

    final resume = <String, Map<String, String>>{};
    final resumeAt = _msMap(json['seriesResumeAt']);
    final rawResume = json['seriesResume'];
    if (rawResume is Map) {
      for (final e in rawResume.entries) {
        final id = '${e.key}';
        final val = e.value;
        if (id.isEmpty || val is! Map) continue;
        final inner = <String, String>{};
        for (final p in val.entries) {
          if ('${p.key}' == 't' || '${p.key}' == 'updatedAt') {
            final stamp = _asMs(p.value);
            if (stamp > 0) resumeAt[id] = stamp;
            continue;
          }
          final v = '${p.value}';
          if (v.isNotEmpty) inner['${p.key}'] = v;
        }
        if (inner.isNotEmpty) resume[id] = inner;
      }
    }

    return UserLibrary(
      favorites: favorites,
      progressSeconds: progress,
      progressUpdatedAt: progressAt,
      watchedKeys: watched,
      watchedAt: watchedTimes,
      seriesResume: resume,
      seriesResumeUpdatedAt: resumeAt,
      updatedAtMs: _asMs(json['updatedAt']),
    );
  }

  ({int seconds, int at}) _progressMark(String key) {
    final seconds = progressSeconds[key] ?? 0;
    final stamped = progressUpdatedAt[key] ?? 0;
    if (seconds > 5) return (seconds: seconds, at: stamped);
    if (stamped > 0) return (seconds: 0, at: stamped);
    if (watchedKeys.contains(key)) {
      return (seconds: 0, at: watchedAt[key] ?? 0);
    }
    return (seconds: 0, at: 0);
  }
}

int _stamp(int? atMs) => atMs ?? DateTime.now().millisecondsSinceEpoch;

int _maxInt(int a, int b) => a > b ? a : b;

int _asMs(Object? value) {
  if (value is int) return value < 0 ? 0 : value;
  return int.tryParse('$value') ?? 0;
}

int _secondsOf(Object? value) {
  if (value is int) return value;
  if (value is Map) {
    final raw = value['s'] ?? value['seconds'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }
  return int.tryParse('$value') ?? 0;
}

int _embeddedMs(Object? value) {
  if (value is! Map) return 0;
  return _asMs(value['t'] ?? value['updatedAt']);
}

Map<String, int> _msMap(Object? raw) {
  final out = <String, int>{};
  if (raw is! Map) return out;
  for (final e in raw.entries) {
    final key = '${e.key}';
    final stamp = _asMs(e.value);
    if (key.isEmpty || stamp <= 0) continue;
    out[key] = stamp;
  }
  return out;
}

({int seconds, int at}) _newerProgress(
  ({int seconds, int at}) a,
  ({int seconds, int at}) b,
) {
  if (a.at != b.at) return a.at > b.at ? a : b;
  final aClear = a.seconds <= 5;
  final bClear = b.seconds <= 5;
  if (aClear && bClear) return a;
  if (aClear != bClear) return aClear ? b : a;
  return a.seconds >= b.seconds ? a : b;
}
