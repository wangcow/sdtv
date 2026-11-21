import 'live_channel.dart';
import 'series.dart';
import 'vod_item.dart';

/// Which tab a search hit should open.
enum GuideSearchSection { live, movies, series }

/// The key a category is stored under in the hidden-categories set. Live
/// ids are stored as-is (as they always were); Movies and TV Shows ids get
/// a prefix, because a panel may reuse the same id across the three.
String hiddenCategoryKey(GuideSearchSection section, String categoryId) =>
    switch (section) {
      GuideSearchSection.live => categoryId,
      GuideSearchSection.movies => 'vod:$categoryId',
      GuideSearchSection.series => 'series:$categoryId',
    };

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

  static final _wordSplit = RegExp(r'[\s\-_/|]+');
  static final _space = RegExp(r'\s+');

  /// Match score: 0 = no match; higher is better.
  static int scoreText(String query, String text) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 0;
    final t = text.toLowerCase();
    return _score(q, _tokens(q), t, t.split(_wordSplit));
  }

  static List<String> _tokens(String q) =>
      q.split(_space).where((s) => s.isNotEmpty).toList();

  /// [scoreText] on prepared input: [q] and [t] lowercased, [words] = [t]
  /// split on separators.
  static int _score(
    String q,
    List<String> qTokens,
    String t,
    List<String> words,
  ) {
    if (t == q) return 100;
    if (t.startsWith(q)) return 80;
    // Word-prefix (e.g. "espn" in "USA ESPN HD")
    for (final part in words) {
      if (part.startsWith(q)) return 60;
    }
    if (t.contains(q)) return 40;
    // Loose: all query tokens present (one token = the contains above).
    if (qTokens.length > 1 && qTokens.every(t.contains)) return 25;
    return 0;
  }

  /// Search live **channels** (not channel categories), plus Movies / TV Shows
  /// when given. Movie and TV show categories still match.
  ///
  /// Hidden groups still surface their titles (marked) so a favorited show in
  /// a hidden list remains findable. [favoriteKeys] get a score boost.
  ///
  /// [maxResults] caps list length for huge catalogs. For repeated searches
  /// over one catalog, build a [GuideSearchIndex] once and reuse it.
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
    if (query.trim().isEmpty) return const [];
    return GuideSearchIndex(
      categories: categories,
      channels: channels,
      vodCategories: vodCategories,
      vodItems: vodItems,
      seriesCategories: seriesCategories,
      seriesItems: seriesItems,
    ).search(
      query,
      hiddenCategoryIds: hiddenCategoryIds,
      favoriteKeys: favoriteKeys,
      maxResults: maxResults,
    );
  }
}

/// One searchable title, prepared once per catalog.
class _Doc {
  _Doc({
    required this.kind,
    required this.index,
    required this.lower,
    required this.words,
    required this.categoryId,
    required this.favoriteKey,
    required this.sortTitle,
  });

  final GuideSearchKind kind;

  /// Position in the source list for that kind.
  final int index;
  final String lower;
  final List<String> words;
  final String categoryId;
  final String favoriteKey;

  /// Lowercased display title, the final tie-breaker.
  final String sortTitle;
}

/// A scored match before it is turned into a [GuideSearchHit].
class _Match {
  const _Match(this.score, this.doc);

  final int score;
  final _Doc doc;
}

/// [GuideSearch] over one catalog, with names lowercased and split once.
///
/// Searching 100k titles per keystroke used to redo that work (and a regex
/// compile) for every title, then build a hit for every match and sort them
/// all. This keeps per-keystroke work to string checks, and only the
/// [maxResults] hits that are shown get built.
class GuideSearchIndex {
  GuideSearchIndex({
    required this.categories,
    required this.channels,
    this.vodCategories = const [],
    this.vodItems = const [],
    this.seriesCategories = const [],
    this.seriesItems = const [],
  }) {
    for (var i = 0; i < channels.length; i++) {
      final ch = channels[i];
      final numPrefix = ch.num > 0 ? '${ch.num}. ' : '';
      _docs.add(
        _doc(
          GuideSearchKind.channel,
          i,
          ch.name,
          ch.categoryId,
          ch.favoriteKey,
          '$numPrefix${ch.name}',
        ),
      );
    }
    for (var i = 0; i < vodItems.length; i++) {
      final v = vodItems[i];
      _docs.add(
        _doc(
          GuideSearchKind.vod,
          i,
          v.name,
          v.categoryId,
          v.favoriteKey,
          v.name,
        ),
      );
    }
    for (var i = 0; i < seriesItems.length; i++) {
      final s = seriesItems[i];
      _docs.add(
        _doc(
          GuideSearchKind.series,
          i,
          s.name,
          s.categoryId,
          s.favoriteKey,
          s.name,
        ),
      );
    }
  }

  final List<({String id, String name})> categories;
  final List<LiveChannel> channels;
  final List<({String id, String name})> vodCategories;
  final List<VodItem> vodItems;
  final List<({String id, String name})> seriesCategories;
  final List<SeriesItem> seriesItems;

  final List<_Doc> _docs = [];

  // Category id → name. A duplicate id keeps the last name, as before.
  late final Map<String, String> _liveCatNames = {
    for (final c in categories) c.id: c.name,
  };
  late final Map<String, String> _vodCatNames = {
    for (final c in vodCategories) c.id: c.name,
  };
  late final Map<String, String> _seriesCatNames = {
    for (final c in seriesCategories) c.id: c.name,
  };

  static _Doc _doc(
    GuideSearchKind kind,
    int index,
    String name,
    String categoryId,
    String favoriteKey,
    String title,
  ) {
    final lower = name.toLowerCase();
    return _Doc(
      kind: kind,
      index: index,
      lower: lower,
      words: lower.split(GuideSearch._wordSplit),
      categoryId: categoryId,
      favoriteKey: favoriteKey,
      sortTitle: title.toLowerCase(),
    );
  }

  static int _scoreName(String q, List<String> qTokens, String name) {
    if (name.isEmpty) return 0;
    final t = name.toLowerCase();
    return GuideSearch._score(q, qTokens, t, t.split(GuideSearch._wordSplit));
  }

  List<GuideSearchHit> search(
    String query, {
    Set<String> hiddenCategoryIds = const {},
    Set<String> favoriteKeys = const {},
    int maxResults = 120,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final qTokens = GuideSearch._tokens(q);

    // Category names score once per query (half weight when an item only
    // matches through its category).
    Map<String, int> halfScores(Map<String, String> names) => {
      for (final e in names.entries)
        e.key: _scoreName(q, qTokens, e.value) ~/ 2,
    };
    final liveCat = halfScores(_liveCatNames);
    final vodCat = halfScores(_vodCatNames);
    final seriesCat = halfScores(_seriesCatNames);

    final matches = <_Match>[];
    for (final d in _docs) {
      final sName = GuideSearch._score(q, qTokens, d.lower, d.words);
      final cats = switch (d.kind) {
        GuideSearchKind.channel => liveCat,
        GuideSearchKind.vod => vodCat,
        _ => seriesCat,
      };
      final sCat = cats[d.categoryId] ?? 0;
      var s = sName >= sCat ? sName : sCat;
      if (s <= 0) continue;
      if (favoriteKeys.contains(d.favoriteKey)) s += 15;
      matches.add(_Match(s, d));
    }

    final categoryHits = <GuideSearchHit>[
      for (final c in vodCategories)
        if (_scoreName(q, qTokens, c.name) case final s when s > 0)
          GuideSearchHit(
            kind: GuideSearchKind.category,
            section: GuideSearchSection.movies,
            title: c.name,
            subtitle:
                hiddenCategoryIds.contains(
                  hiddenCategoryKey(GuideSearchSection.movies, c.id),
                )
                ? 'Movies · hidden'
                : 'Movies',
            categoryId: c.id,
            categoryName: c.name,
            score: s + 5,
          ),
      for (final c in seriesCategories)
        if (_scoreName(q, qTokens, c.name) case final s when s > 0)
          GuideSearchHit(
            kind: GuideSearchKind.category,
            section: GuideSearchSection.series,
            title: c.name,
            subtitle:
                hiddenCategoryIds.contains(
                  hiddenCategoryKey(GuideSearchSection.series, c.id),
                )
                ? 'TV Shows · hidden'
                : 'TV Shows',
            categoryId: c.id,
            categoryName: c.name,
            score: s + 5,
          ),
    ];

    // Same order as before: score, then kind, then title. Scores take few
    // values, so walk them from the top and sort only the buckets shown.
    final byScore = <int, List<Object>>{};
    for (final m in matches) {
      (byScore[m.score] ??= []).add(m);
    }
    for (final h in categoryHits) {
      (byScore[h.score] ??= []).add(h);
    }
    final scores = byScore.keys.toList()..sort((a, b) => b.compareTo(a));

    final out = <GuideSearchHit>[];
    for (final score in scores) {
      if (out.length >= maxResults) break;
      final bucket = byScore[score]!;
      bucket.sort((a, b) {
        final byKind = _kindOf(a).index.compareTo(_kindOf(b).index);
        if (byKind != 0) return byKind;
        return _sortTitleOf(a).compareTo(_sortTitleOf(b));
      });
      for (final e in bucket) {
        if (out.length >= maxResults) break;
        out.add(
          e is GuideSearchHit
              ? e
              : _hit(e as _Match, hiddenCategoryIds, favoriteKeys),
        );
      }
    }
    return out;
  }

  static GuideSearchKind _kindOf(Object e) =>
      e is GuideSearchHit ? e.kind : (e as _Match).doc.kind;

  static String _sortTitleOf(Object e) =>
      e is GuideSearchHit ? e.title.toLowerCase() : (e as _Match).doc.sortTitle;

  GuideSearchHit _hit(
    _Match m,
    Set<String> hiddenCategoryIds,
    Set<String> favoriteKeys,
  ) {
    final d = m.doc;
    final hidden = hiddenCategoryIds.contains(
      hiddenCategoryKey(switch (d.kind) {
        GuideSearchKind.channel => GuideSearchSection.live,
        GuideSearchKind.vod => GuideSearchSection.movies,
        _ => GuideSearchSection.series,
      }, d.categoryId),
    );
    final fav = favoriteKeys.contains(d.favoriteKey);
    switch (d.kind) {
      case GuideSearchKind.channel:
        final ch = channels[d.index];
        final catName = _liveCatNames[ch.categoryId] ?? '';
        final numPrefix = ch.num > 0 ? '${ch.num}. ' : '';
        return GuideSearchHit(
          kind: GuideSearchKind.channel,
          title: '$numPrefix${ch.name}',
          subtitle: [
            if (catName.isNotEmpty) catName else 'Channel',
            if (hidden) 'hidden',
            if (fav) '★',
          ].join(' · '),
          categoryId: ch.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          channel: ch,
          score: m.score,
        );
      case GuideSearchKind.vod:
        final v = vodItems[d.index];
        final catName = _vodCatNames[v.categoryId] ?? '';
        return GuideSearchHit(
          kind: GuideSearchKind.vod,
          section: GuideSearchSection.movies,
          title: v.name,
          subtitle: [
            'Movie',
            if (catName.isNotEmpty) catName,
            if (hidden) 'hidden',
            if (fav) '★',
          ].join(' · '),
          categoryId: v.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          vod: v,
          score: m.score,
        );
      default:
        final show = seriesItems[d.index];
        final catName = _seriesCatNames[show.categoryId] ?? '';
        return GuideSearchHit(
          kind: GuideSearchKind.series,
          section: GuideSearchSection.series,
          title: show.name,
          subtitle: [
            'TV Show',
            if (catName.isNotEmpty) catName,
            if (hidden) 'hidden',
            if (fav) '★',
          ].join(' · '),
          categoryId: show.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          series: show,
          score: m.score,
        );
    }
  }
}
