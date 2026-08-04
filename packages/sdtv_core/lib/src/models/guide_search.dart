import 'live_channel.dart';

/// What a guide search hit points at.
///
/// [epg] is reserved for short/full EPG search later — same result list UI.
enum GuideSearchKind {
  category,
  channel,
  /// Future: program title / description from EPG.
  epg,
}

/// One row in guide search results (categories, channels, later EPG).
class GuideSearchHit {
  const GuideSearchHit({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.categoryId,
    this.categoryName,
    this.channel,
    this.score = 0,
    // EPG hooks (unused until short EPG lands)
    this.epgChannelId,
    this.epgProgramId,
    this.epgStart,
    this.epgEnd,
  });

  final GuideSearchKind kind;
  final String title;
  final String subtitle;
  final String? categoryId;
  final String? categoryName;
  final LiveChannel? channel;

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
}

/// Pure search helpers for the live guide (no I/O).
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

  /// Search visible categories + channels. [hiddenCategoryIds] are skipped.
  ///
  /// [maxResults] caps list length for huge catalogs.
  static List<GuideSearchHit> search({
    required String query,
    required List<({String id, String name})> categories,
    required List<LiveChannel> channels,
    Set<String> hiddenCategoryIds = const {},
    int maxResults = 80,
  }) {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final catNameById = <String, String>{
      for (final c in categories) c.id: c.name,
    };

    final hits = <GuideSearchHit>[];

    for (final c in categories) {
      if (hiddenCategoryIds.contains(c.id)) continue;
      final s = scoreText(q, c.name);
      if (s <= 0) continue;
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.category,
          title: c.name,
          subtitle: 'Category',
          categoryId: c.id,
          categoryName: c.name,
          score: s + 5, // slight boost so cats surface among channels
        ),
      );
    }

    for (final ch in channels) {
      if (hiddenCategoryIds.contains(ch.categoryId)) continue;
      final sName = scoreText(q, ch.name);
      final catName = catNameById[ch.categoryId] ?? '';
      final sCat = catName.isEmpty ? 0 : (scoreText(q, catName) ~/ 2);
      final s = sName >= sCat ? sName : sCat;
      if (s <= 0) continue;
      final numPrefix = ch.num > 0 ? '${ch.num}. ' : '';
      hits.add(
        GuideSearchHit(
          kind: GuideSearchKind.channel,
          title: '$numPrefix${ch.name}',
          subtitle: catName.isEmpty ? 'Channel' : catName,
          categoryId: ch.categoryId,
          categoryName: catName.isEmpty ? null : catName,
          channel: ch,
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
