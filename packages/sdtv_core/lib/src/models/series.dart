import 'vod_info.dart';
import 'vod_item.dart';

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String _ext(Object? raw) {
  final s = '${raw ?? 'mp4'}'.trim().replaceAll('.', '');
  return s.isEmpty ? 'mp4' : s;
}

/// Xtream `get_series` row.
class SeriesItem {
  const SeriesItem({
    required this.seriesId,
    required this.name,
    required this.categoryId,
    this.cover = '',
    this.plot = '',
    this.rating = '',
    this.director = '',
    this.cast = '',
    this.genre = '',
    this.releaseDate = '',
  });

  final int seriesId;
  final String name;
  final String categoryId;
  final String cover;
  final String plot;
  final String rating;
  final String director;
  final String cast;
  final String genre;
  final String releaseDate;

  String get favoriteKey => 's:$seriesId';

  /// Shape the movie landing pane expects.
  VodItem get asVodItem => VodItem(
        streamId: seriesId,
        name: name,
        categoryId: categoryId,
        streamIcon: cover,
        plot: plot,
        rating: rating,
      );

  factory SeriesItem.fromJson(Map<String, dynamic> json) {
    return SeriesItem(
      seriesId: _asInt(json['series_id'] ?? json['id']),
      name: '${json['name'] ?? ''}',
      categoryId: '${json['category_id'] ?? ''}',
      cover: '${json['cover'] ?? json['stream_icon'] ?? ''}',
      plot: '${json['plot'] ?? json['description'] ?? ''}',
      rating: '${json['rating'] ?? json['rating_5based'] ?? ''}',
      director: '${json['director'] ?? ''}',
      cast: '${json['cast'] ?? json['actors'] ?? ''}',
      genre: '${json['genre'] ?? ''}',
      releaseDate: '${json['releaseDate'] ?? json['releasedate'] ?? ''}',
    );
  }
}

class SeriesEpisode {
  const SeriesEpisode({
    required this.id,
    required this.season,
    required this.episodeNum,
    required this.title,
    this.containerExtension = 'mp4',
    this.plot = '',
    this.durationSecs = 0,
  });

  final String id;
  final int season;
  final int episodeNum;
  final String title;
  final String containerExtension;
  final String plot;
  final int durationSecs;

  String get progressKey => 'se:$id';

  String get label {
    final n = episodeNum > 0 ? 'E$episodeNum' : 'E?';
    if (title.trim().isEmpty) return n;
    return '$n  ${title.trim()}';
  }

  factory SeriesEpisode.fromJson(
    Map<String, dynamic> json, {
    required int season,
  }) {
    Map<String, dynamic> info = const {};
    final raw = json['info'];
    if (raw is Map<String, dynamic>) {
      info = raw;
    } else if (raw is Map) {
      info = Map<String, dynamic>.from(raw);
    }
    final title = '${json['title'] ?? json['name'] ?? ''}'.trim();
    return SeriesEpisode(
      id: '${json['id'] ?? json['episode_id'] ?? ''}',
      season: season,
      episodeNum: _asInt(json['episode_num']),
      title: title,
      containerExtension: _ext(json['container_extension']),
      plot: '${info['plot'] ?? json['plot'] ?? ''}',
      durationSecs: _asInt(info['duration_secs'] ?? json['duration_secs']),
    );
  }
}

class SeriesSeason {
  const SeriesSeason({
    required this.seasonNumber,
    required this.name,
    required this.episodes,
  });

  final int seasonNumber;
  final String name;
  final List<SeriesEpisode> episodes;
}

/// `get_series_info` payload: landing metadata + seasons/episodes.
class SeriesCatalog {
  const SeriesCatalog({
    required this.info,
    required this.seasons,
  });

  final VodInfo info;
  final List<SeriesSeason> seasons;

  SeriesEpisode? get firstEpisode {
    for (final s in seasons) {
      if (s.episodes.isNotEmpty) return s.episodes.first;
    }
    return null;
  }

  SeriesEpisode? episodeById(String id) {
    for (final s in seasons) {
      for (final e in s.episodes) {
        if (e.id == id) return e;
      }
    }
    return null;
  }

  /// Next episode after [current] in season/episode order, or null if last.
  SeriesEpisode? nextEpisode(SeriesEpisode current) {
    var found = false;
    for (final s in seasons) {
      for (final e in s.episodes) {
        if (found) return e;
        if (e.id == current.id) found = true;
      }
    }
    return null;
  }

  factory SeriesCatalog.fromXtreamJson(
    Map<String, dynamic> json, {
    SeriesItem? fallback,
  }) {
    final info = VodInfo.fromXtreamJson(json, fallback: fallback?.asVodItem);
    final patched = VodInfo(
      title: info.title.isNotEmpty ? info.title : (fallback?.name ?? ''),
      plot: info.plot.isNotEmpty ? info.plot : (fallback?.plot ?? ''),
      director:
          info.director.isNotEmpty ? info.director : (fallback?.director ?? ''),
      cast: info.cast.isNotEmpty
          ? info.cast
          : (fallback?.cast ?? '')
              .split(RegExp(r'\s*,\s*'))
              .where((s) => s.isNotEmpty)
              .toList(),
      rating: info.rating.isNotEmpty ? info.rating : (fallback?.rating ?? ''),
      ratingSource: info.ratingSource.isNotEmpty
          ? info.ratingSource
          : ((fallback?.rating ?? '').isEmpty ? '' : 'Provider'),
      genre: info.genre.isNotEmpty ? info.genre : (fallback?.genre ?? ''),
      released: info.released.isNotEmpty
          ? info.released
          : (fallback?.releaseDate ?? ''),
      posterUrl:
          info.posterUrl.isNotEmpty ? info.posterUrl : (fallback?.cover ?? ''),
      youtubeTrailer: info.youtubeTrailer,
      durationSecs: info.durationSecs,
    );

    final bySeason = <int, List<SeriesEpisode>>{};
    final rawEps = json['episodes'];
    if (rawEps is Map) {
      for (final e in rawEps.entries) {
        final season = int.tryParse('${e.key}') ?? 0;
        final list = e.value;
        if (list is! List) continue;
        final out = <SeriesEpisode>[];
        for (final row in list) {
          if (row is! Map) continue;
          final map = row is Map<String, dynamic>
              ? row
              : Map<String, dynamic>.from(row);
          final ep = SeriesEpisode.fromJson(map, season: season);
          if (ep.id.isEmpty) continue;
          out.add(ep);
        }
        out.sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
        if (out.isNotEmpty) bySeason[season] = out;
      }
    }

    final seasons = bySeason.keys.toList()..sort();
    final named = <SeriesSeason>[];
    for (final n in seasons) {
      named.add(
        SeriesSeason(
          seasonNumber: n,
          name: n <= 0 ? 'Specials' : 'Season $n',
          episodes: bySeason[n]!,
        ),
      );
    }
    return SeriesCatalog(info: patched, seasons: named);
  }
}
