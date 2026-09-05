import 'live_channel.dart';
import 'series.dart';
import 'vod_item.dart';

/// Which tab a search hit should open.
enum GuideSearchSection { live, movies, series }

/// What a guide search hit points at.
///
/// [epg] is reserved for short/full EPG search later — same result list UI.
enum GuideSearchKind {
  category,
  channel,
  /// Future: program title / description from EPG.
  epg,
  vod,
  series,
}

/// One row in guide search results (categories, channels, movies, TV shows).
class GuideSearchHit {
  const GuideSearchHit({
    required this.kind,
    required this.title,
    this.section = GuideSearchSection.live,
    this.subtitle = '',
    this.categoryId,
    this.categoryName,
    this.channel,
    this.vod,
    this.series,
    this.score = 0,
    // EPG hooks (unused until short EPG lands)
    this.epgChannelId,
    this.epgProgramId,
    this.epgStart,
    this.epgEnd,
  });

  final GuideSearchKind kind;
  final GuideSearchSection section;
  final String title;
  final String subtitle;
  final String? categoryId;
  final String? categoryName;
  final LiveChannel? channel;
  final VodItem? vod;
  final SeriesItem? series;

  /// Higher = better match (prefix beats contains, etc.).
  final int score;

  /// Reserved for EPG hits.
  final String? epgChannelId;
  final String? epgProgramId;
  final DateTime? epgStart;
  final DateTime? epgEnd;

  bool get isCategory => kind == GuideSearchKind.category;
  bool get isChannel => kind == GuideSearchKind.channel;
  bool get isEpg => kind == GuideSearchKind.epg;
  bool get isVod => kind == GuideSearchKind.vod;
  bool get isSeries => kind == GuideSearchKind.series;
}

/// Pure search helpers for Live / Movies / TV Shows (no I/O).
class GuideSearch {
  GuideSearch._();

  /// Match score: 0 = no match; higher is better.
  static int scoreText(String query, String text) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 0;
    final t = text.toLowerCase();
    if (t == q) return 100;
    if (t.startsWith(q)) return 80;
    // Word-prefix (e.g. "espn" in "USA ESPN HD")
    for (final part in t.split(RegExp(r'[\s\-_/|]+'))) {
      if (part.startsWith(q)) return 60;
    }
    if (t.contains(q)) return 40;
    // Loose: all query tokens present
    final tokens = q.split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    if (tokens.every(t.contains)) return 25;
    return 0;
  }

  /// Search live **channels** (not channel categories), plus Movies / TV Shows
  /// when given. Movie and TV show categories still match.
  ///
  /// Hidden groups still surface their titles (marked) so a favorited show in
  /// a hidden list remains findable. [favoriteKeys] get a score boost (live
  /// channels).
  ///
  /// [maxResults] caps list length for huge catalogs.
  static List<GuideSearchHit> search({
    required String query,
    required List<({String id, String name})> categories,
    required List<LiveChannel> channels,
    List<({String id, String name})> vodCategories = const [],
    List<VodItem> vodItems = const [],
    List<({String id, String name})> seriesCategories = const [],
    List<SeriesItem> seriesItems = const [],
    Set<String> hiddenCategoryIds = const {},
    Set<String> favoriteKeys = const {},
    int maxResults = 120,
  }) {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final catNameById = <String, String>{
      for (final c in categories) c.id: c.name,
    };

    final hits = <GuideSearchHit>[];

    for (final ch in channels) {
      final hidden = hiddenCategoryIds.contains(ch.categoryId);
      final sName = scoreText(q, ch.name);
      final catName = catNameById[ch.categoryId] ?? '';
      final sCat = catName.isEmpty ? 0 : (scoreText(q, catName) ~/ 2);
      var s = sName >= sCat ? sName : sCat;
      if (s <= 0) continue;
      if (favoriteKeys.contains(ch.favoriteKey)) {
        s += 15; // boost ★ so favorited channels stay easy to re-find
      }
      final numPrefix = ch.num > 0 ? '${ch.num}. ' : '';
      final bits = <String>[
        if (catName.isNotEmpty) catName else 'Channel',
        if (hidden) 'hidden',
        if (favoriteKeys.contains(ch.favoriteKey)) '★',
      ];
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.channel,
          title: '$numPrefix${ch.name}',
          subtitle: bits.join(' · '),
          categoryId: ch.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          channel: ch,
          score: s,
        ),
      );
    }

    final vodNameById = <String, String>{
      for (final c in vodCategories) c.id: c.name,
    };
    for (final c in vodCategories) {
      final hidden = hiddenCategoryIds.contains(c.id);
      final s = scoreText(q, c.name);
      if (s <= 0) continue;
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.category,
          section: GuideSearchSection.movies,
          title: c.name,
          subtitle: hidden ? 'Movies · hidden' : 'Movies',
          categoryId: c.id,
          categoryName: c.name,
          score: s + 5,
        ),
      );
    }
    for (final v in vodItems) {
      final hidden = hiddenCategoryIds.contains(v.categoryId);
      final catName = vodNameById[v.categoryId] ?? '';
      final sName = scoreText(q, v.name);
      final sCat = catName.isEmpty ? 0 : (scoreText(q, catName) ~/ 2);
      var s = sName >= sCat ? sName : sCat;
      if (s <= 0) continue;
      if (favoriteKeys.contains(v.favoriteKey)) {
        s += 15;
      }
      final bits = <String>[
        'Movie',
        if (catName.isNotEmpty) catName,
        if (hidden) 'hidden',
        if (favoriteKeys.contains(v.favoriteKey)) '★',
      ];
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.vod,
          section: GuideSearchSection.movies,
          title: v.name,
          subtitle: bits.join(' · '),
          categoryId: v.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          vod: v,
          score: s,
        ),
      );
    }

    final seriesNameById = <String, String>{
      for (final c in seriesCategories) c.id: c.name,
    };
    for (final c in seriesCategories) {
      final hidden = hiddenCategoryIds.contains(c.id);
      final s = scoreText(q, c.name);
      if (s <= 0) continue;
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.category,
          section: GuideSearchSection.series,
          title: c.name,
          subtitle: hidden ? 'TV Shows · hidden' : 'TV Shows',
          categoryId: c.id,
          categoryName: c.name,
          score: s + 5,
        ),
      );
    }
    for (final show in seriesItems) {
      final hidden = hiddenCategoryIds.contains(show.categoryId);
      final catName = seriesNameById[show.categoryId] ?? '';
      final sName = scoreText(q, show.name);
      final sCat = catName.isEmpty ? 0 : (scoreText(q, catName) ~/ 2);
      var s = sName >= sCat ? sName : sCat;
      if (s <= 0) continue;
      if (favoriteKeys.contains(show.favoriteKey)) {
        s += 15;
      }
      final bits = <String>[
        'TV Show',
        if (catName.isNotEmpty) catName,
        if (hidden) 'hidden',
        if (favoriteKeys.contains(show.favoriteKey)) '★',
      ];
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.series,
          section: GuideSearchSection.series,
          title: show.name,
          subtitle: bits.join(' · '),
          categoryId: show.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          series: show,
          score: s,
        ),
      );
    }

    // Future: append EPG hits here with GuideSearchKind.epg

    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byKind = a.kind.index.compareTo(b.kind.index);
      if (byKind != 0) return byKind;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    if (hits.length <= maxResults) return hits;
    return hits.sublist(0, maxResults);
  }
}
