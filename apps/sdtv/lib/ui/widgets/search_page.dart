import 'package:flutter/material.dart';
import 'package:sdtv_core/sdtv_core.dart';

import '../../services/artwork_cache.dart';
import 'cached_artwork.dart';
import 'epg_guide_pane.dart' show ChannelLogo;

/// One row of the search page (Live TV, Movies, TV Shows, Categories).
class SearchRow {
  const SearchRow(this.title, this.kind, this.hits);

  final String title;
  final GuideSearchKind kind;
  final List<GuideSearchHit> hits;

  /// Live, Movies, TV Shows and Categories rows, in that order, from mixed
  /// [hits] (already ranked). Empty rows are left out; each row is capped.
  static List<SearchRow> group(List<GuideSearchHit> hits, {int perRow = 40}) {
    List<GuideSearchHit> of(GuideSearchKind k) =>
        hits.where((h) => h.kind == k).take(perRow).toList();
    return [
      SearchRow(
        'Live TV',
        GuideSearchKind.channel,
        of(GuideSearchKind.channel),
      ),
      SearchRow('Movies', GuideSearchKind.vod, of(GuideSearchKind.vod)),
      SearchRow('TV Shows', GuideSearchKind.series, of(GuideSearchKind.series)),
      SearchRow(
        'Categories',
        GuideSearchKind.category,
        of(GuideSearchKind.category),
      ),
    ].where((r) => r.hits.isNotEmpty).toList();
  }
}

/// Full-screen search, TiviMate-style: the query on top, then a row per
/// kind of result. Pad / keyboard input is routed by the page that owns it;
/// this widget draws the state and keeps the selection on screen.
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.controller,
    required this.fieldFocus,
    required this.resultsFocus,
    required this.rows,
    required this.browsing,
    required this.row,
    required this.col,
    required this.onTapHit,
    this.artwork,
    this.artworkScope = '',
    this.loading = false,
  });

  final TextEditingController controller;

  /// The query field. Has focus while typing.
  final FocusNode fieldFocus;

  /// Holds keyboard focus while browsing results, so arrow keys stay in the
  /// page's handlers instead of traversing back into the field.
  final FocusNode resultsFocus;

  final List<SearchRow> rows;

  /// The pad / keyboard is on the results, not the field.
  final bool browsing;
  final int row;
  final int col;
  final void Function(int row, int col) onTapHit;
  final ArtworkCache? artwork;
  final String artworkScope;

  /// Movies / TV Shows catalogs are still loading.
  final bool loading;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void didUpdateWidget(SearchPage old) {
    super.didUpdateWidget(old);
    if (widget.browsing &&
        (old.row != widget.row ||
            old.col != widget.col ||
            !old.browsing ||
            old.rows != widget.rows)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _selectedKey.currentContext;
        if (ctx == null || !mounted) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 90),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = widget.controller.text.trim();
    final total = widget.rows.fold<int>(0, (n, r) => n + r.hits.length);

    Widget body;
    if (query.isEmpty) {
      body = _Message(
        icon: Icons.search_rounded,
        text: 'Search Live TV, Movies and TV Shows',
      );
    } else if (widget.rows.isEmpty) {
      body = _Message(
        icon: Icons.search_off_rounded,
        text: widget.loading ? 'Searching…' : 'No matches for “$query”',
      );
    } else {
      body = Focus(
        focusNode: widget.resultsFocus,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
          children: [
            for (var r = 0; r < widget.rows.length; r++)
              _ResultRow(
                row: widget.rows[r],
                selectedCol: widget.browsing && widget.row == r
                    ? widget.col
                    : null,
                selectedKey: _selectedKey,
                artwork: widget.artwork,
                artworkScope: widget.artworkScope,
                onTap: (c) => widget.onTapHit(r, c),
              ),
          ],
        ),
      );
    }

    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 14),
            color: scheme.surfaceContainerLow,
            child: Row(
              children: [
                Text(
                  'Search',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.fieldFocus,
                    autofocus: true,
                    style: theme.textTheme.titleMedium,
                    decoration: InputDecoration(
                      hintText: 'Channel, movie or show…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      isDense: true,
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: scheme.primary, width: 2),
                      ),
                    ),
                    // Done/Search on the OSK used to submit and play the
                    // first hit. Play only after moving to a result.
                    textInputAction: TextInputAction.none,
                    onEditingComplete: () {},
                    onSubmitted: (_) {},
                  ),
                ),
                const SizedBox(width: 20),
                Text(
                  query.isEmpty ? '' : '$total result${total == 1 ? '' : 's'}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: body),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            color: scheme.surfaceContainerLow,
            alignment: Alignment.centerLeft,
            child: Text(
              widget.browsing
                  ? '←→ along a row  ·  ↑↓ rows (↑ from the top row: search box)  ·  A open  ·  B close'
                  : 'Type (Steam+X for the keyboard)  ·  B to the results (↓ on a keyboard)  ·  B again to close',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            text,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.row,
    required this.selectedCol,
    required this.selectedKey,
    required this.onTap,
    this.artwork,
    this.artworkScope = '',
  });

  final SearchRow row;
  final int? selectedCol;
  final GlobalKey selectedKey;
  final ValueChanged<int> onTap;
  final ArtworkCache? artwork;
  final String artworkScope;

  double get _height => switch (row.kind) {
    GuideSearchKind.vod || GuideSearchKind.series => 252,
    GuideSearchKind.channel => 116,
    _ => 52,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = selectedCol != null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row.title.toUpperCase()}  ·  ${row.hits.length}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: _height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: row.hits.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, c) {
                final selected = selectedCol == c;
                final hit = row.hits[c];
                final Widget card = switch (row.kind) {
                  GuideSearchKind.channel => _ChannelCard(
                    hit: hit,
                    selected: selected,
                    artwork: artwork,
                    artworkScope: artworkScope,
                  ),
                  GuideSearchKind.vod || GuideSearchKind.series => _PosterCard(
                    hit: hit,
                    selected: selected,
                    artwork: artwork,
                    artworkScope: artworkScope,
                  ),
                  _ => _CategoryCard(hit: hit, selected: selected),
                };
                return GestureDetector(
                  key: selected ? selectedKey : null,
                  onTap: () => onTap(c),
                  child: card,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

BoxDecoration _cardDecoration(ThemeData theme, bool selected) {
  final scheme = theme.colorScheme;
  return BoxDecoration(
    color: selected ? scheme.primary : scheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(10),
    border: Border.all(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      width: 3,
    ),
  );
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({
    required this.hit,
    required this.selected,
    this.artwork,
    this.artworkScope = '',
  });

  final GuideSearchHit hit;
  final bool selected;
  final ArtworkCache? artwork;
  final String artworkScope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? theme.colorScheme.onPrimary : Colors.white;
    final ch = hit.channel;
    return Container(
      width: 230,
      padding: const EdgeInsets.all(12),
      decoration: _cardDecoration(theme, selected),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ch != null && artwork != null)
            ChannelLogo(
              channel: ch,
              cache: artwork!,
              scope: artworkScope,
              width: 64,
              height: 40,
            ),
          const Spacer(),
          Text(
            hit.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            hit.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
    required this.hit,
    required this.selected,
    this.artwork,
    this.artworkScope = '',
  });

  final GuideSearchHit hit;
  final bool selected;
  final ArtworkCache? artwork;
  final String artworkScope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isShow = hit.kind == GuideSearchKind.series;
    final url = isShow
        ? (hit.series?.cover ?? '')
        : (hit.vod?.streamIcon ?? '');
    final id = isShow ? '${hit.series?.seriesId}' : '${hit.vod?.streamId}';
    final placeholder = Center(
      child: Icon(
        isShow ? Icons.tv_rounded : Icons.movie_outlined,
        size: 36,
        color: scheme.onSurface.withValues(alpha: 0.35),
      ),
    );
    return SizedBox(
      width: 136,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 136,
            height: 204,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.45),
                        blurRadius: 14,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: artwork == null || url.trim().isEmpty
                  ? placeholder
                  : CachedArtwork(
                      cache: artwork!,
                      scope: artworkScope,
                      // Same cache entries as the poster grids (shows use
                      // their series id as the stream id there).
                      kind: ArtworkCache.kindVod,
                      id: id,
                      url: url,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      cacheHeight: 408,
                      placeholder: placeholder,
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hit.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? scheme.primary : scheme.onSurface,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.hit, required this.selected});

  final GuideSearchHit hit;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = selected ? theme.colorScheme.onPrimary : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: _cardDecoration(theme, selected),
      child: Text(
        '${hit.title}  ·  ${hit.subtitle}',
        style: theme.textTheme.titleSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
