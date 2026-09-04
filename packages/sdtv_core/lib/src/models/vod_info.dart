import 'vod_item.dart';

/// Extra metadata from Xtream `get_vod_info` (plus a fallback from [VodItem]).
class VodInfo {
  const VodInfo({
    required this.title,
    this.plot = '',
    this.director = '',
    this.cast = const [],
    this.rating = '',
    this.ratingSource = '',
    this.genre = '',
    this.released = '',
    this.posterUrl = '',
    this.youtubeTrailer = '',
    this.durationSecs = 0,
  });

  final String title;
  final String plot;
  final String director;
  final List<String> cast;
  final String rating;
  final String ratingSource;
  final String genre;
  final String released;
  final String posterUrl;

  /// YouTube video id or a full http(s) URL.
  final String youtubeTrailer;
  final int durationSecs;

  bool get hasTrailer => youtubeTrailer.trim().isNotEmpty;

  List<String> get billedCast => cast.take(6).toList();

  /// Xtream `youtube_trailer` is usually an 11-char id, sometimes a youtu.be URL.
  bool get isYoutubeTrailer => youtubeVideoId(youtubeTrailer) != null;

  Uri? get trailerUri {
    final t = youtubeTrailer.trim();
    if (t.isEmpty) return null;
    final id = youtubeVideoId(t);
    if (id != null) {
      return Uri.parse('https://www.youtube.com/watch?v=$id');
    }
    if (t.startsWith('http://') || t.startsWith('https://')) {
      return Uri.tryParse(t);
    }
    return null;
  }

  /// YouTube video id from a bare Xtream token or a watch/embed/youtu.be URL.
  static String? youtubeVideoId(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (!t.contains('/') && !t.contains('?') && !t.contains('.')) {
      if (RegExp(r'^[A-Za-z0-9_-]{8,16}$').hasMatch(t)) return t;
      return null;
    }
    final uri = Uri.tryParse(t);
    if (uri == null || uri.host.isEmpty) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
      if (uri.pathSegments.isEmpty) return null;
      final id = uri.pathSegments.first;
      if (RegExp(r'^[A-Za-z0-9_-]{8,16}$').hasMatch(id)) return id;
      return null;
    }
    if (!host.contains('youtube.com')) return null;
    final v = uri.queryParameters['v'];
    if (v != null && RegExp(r'^[A-Za-z0-9_-]{8,16}$').hasMatch(v)) return v;
    final parts = uri.pathSegments;
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i] == 'embed' || parts[i] == 'shorts' || parts[i] == 'v') {
        final id = parts[i + 1];
        if (RegExp(r'^[A-Za-z0-9_-]{8,16}$').hasMatch(id)) return id;
      }
    }
    return null;
  }

  factory VodInfo.fromVodItem(VodItem item) {
    return VodInfo(
      title: item.name,
      plot: item.plot,
      rating: item.rating,
      ratingSource: item.rating.isEmpty ? '' : 'Provider',
      posterUrl: item.streamIcon,
      durationSecs: item.durationSecs,
    );
  }

  factory VodInfo.fromXtreamJson(
    Map<String, dynamic> json, {
    VodItem? fallback,
  }) {
    Map<String, dynamic> asMap(Object? raw) {
      if (raw is Map<String, dynamic>) return raw;
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return const {};
    }

    final info = asMap(json['info']).isNotEmpty ? asMap(json['info']) : json;
    final movie = asMap(json['movie_data']);

    String s(Object? v) => '${v ?? ''}'.trim();

    final title = s(info['name']).isNotEmpty
        ? s(info['name'])
        : (s(movie['name']).isNotEmpty
            ? s(movie['name'])
            : (fallback?.name ?? ''));
    final plot = s(info['plot']).isNotEmpty
        ? s(info['plot'])
        : (s(info['description']).isNotEmpty
            ? s(info['description'])
            : (fallback?.plot ?? ''));
    final actorsRaw = s(info['actors']).isNotEmpty
        ? s(info['actors'])
        : s(info['cast']);
    final cast = actorsRaw
        .split(RegExp(r'\s*,\s*'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final rating = s(info['rating']).isNotEmpty
        ? s(info['rating'])
        : (s(info['rating_5based']).isNotEmpty
            ? s(info['rating_5based'])
            : (fallback?.rating ?? ''));
    final poster = s(info['movie_image']).isNotEmpty
        ? s(info['movie_image'])
        : (s(info['cover_big']).isNotEmpty
            ? s(info['cover_big'])
            : (s(info['cover']).isNotEmpty
                ? s(info['cover'])
                : (fallback?.streamIcon ?? '')));
    final trailer = s(info['youtube_trailer']).isNotEmpty
        ? s(info['youtube_trailer'])
        : s(info['trailer']);
    var duration = _asInt(info['duration_secs']);
    if (duration <= 0) duration = fallback?.durationSecs ?? 0;

    return VodInfo(
      title: title,
      plot: plot,
      director: s(info['director']),
      cast: cast,
      rating: rating,
      ratingSource: rating.isEmpty ? '' : 'Provider',
      genre: s(info['genre']),
      released: s(info['releasedate']).isNotEmpty
          ? s(info['releasedate'])
          : s(info['releaseDate']),
      posterUrl: poster,
      youtubeTrailer: trailer,
      durationSecs: duration,
    );
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
