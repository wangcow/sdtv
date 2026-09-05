import 'package:flutter/material.dart';
import 'package:sdtv_core/sdtv_core.dart';

import '../../services/artwork_cache.dart';
import 'cached_artwork.dart';
import 'vod_poster_tile.dart';

/// Right-pane title landing (Movies / TV Shows). Pad-driven actions.
///
/// Deck handheld: copy on the left, 2:3 poster top-right, actions under the
/// poster at the same width. The poster must not stretch with the pane height
/// or [BoxFit.cover] crops letterboxing (e.g. "THE GATES" → "E GAT").
class VodTitlePane extends StatelessWidget {
  const VodTitlePane({
    super.key,
    required this.item,
    required this.info,
    required this.actions,
    required this.actionIndex,
    required this.onAction,
    this.loading = false,
    this.watched = false,
    this.artCache,
    this.artScope = '',
  });

  final VodItem item;
  final VodInfo info;
  final List<({String id, String label, IconData icon})> actions;
  final int actionIndex;
  final ValueChanged<String> onAction;
  final bool loading;
  final bool watched;
  final ArtworkCache? artCache;
  final String artScope;

  static const _posterAspect = 2 / 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = <String>[
      if (info.released.isNotEmpty) info.released,
      if (info.genre.isNotEmpty) info.genre,
      if (info.durationSecs > 0) _durationLabel(info.durationSecs),
      if (info.rating.isNotEmpty)
        info.ratingSource.isEmpty
            ? info.rating
            : '${info.rating} · ${info.ratingSource}',
    ];
    final cast = info.billedCast;
    final title = info.title.isEmpty ? item.name : info.title;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 20, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final posterW = _posterWidth(
            paneW: constraints.maxWidth,
            paneH: constraints.maxHeight,
            actionCount: actions.length,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta.join('  ·  '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (info.director.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Director  ${info.director}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    if (cast.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Cast  ${cast.join(', ')}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    const SizedBox(height: 10),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Text(
                          info.plot.isEmpty
                              ? 'No description from the provider.'
                              : info.plot,
                          style:
                              theme.textTheme.bodyLarge?.copyWith(height: 1.35),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: posterW,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: _posterAspect,
                      child: _Poster(
                        url: info.posterUrl.isNotEmpty
                            ? info.posterUrl
                            : item.streamIcon,
                        cache: artCache,
                        scope: artScope,
                        id: '${item.streamId}',
                        watched: watched,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _ActionTile(
                        label: actions[i].label,
                        icon: actions[i].icon,
                        selected: actionIndex == i,
                        onTap: () => onAction(actions[i].id),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '↑↓ actions · A select · B back',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Size the 2:3 poster so it and the action stack fit Deck handheld height.
  static double _posterWidth({
    required double paneW,
    required double paneH,
    required int actionCount,
  }) {
    const gap = 10.0;
    const actionH = 52.0;
    const actionGap = 8.0;
    const hintH = 28.0;
    final n = actionCount.clamp(1, 4);
    final actionsBlock =
        gap + n * actionH + (n - 1) * actionGap + hintH;
    final maxPosterH = (paneH - actionsBlock).clamp(180.0, 420.0);
    final fromHeight = maxPosterH * _posterAspect;
    final fromWidth = paneW * 0.42;
    return fromHeight.clamp(168.0, fromWidth.clamp(168.0, 280.0));
  }
}

class _Poster extends StatelessWidget {
  const _Poster({
    required this.url,
    this.cache,
    this.scope = '',
    this.id = '',
    this.watched = false,
  });

  final String url;
  final ArtworkCache? cache;
  final String scope;
  final String id;
  final bool watched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 48,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
        ),
      ),
    );
    final art = (cache != null && url.trim().isNotEmpty)
        ? CachedArtwork(
            cache: cache!,
            scope: scope,
            kind: ArtworkCache.kindVod,
            id: id,
            url: url,
            fit: BoxFit.contain,
            placeholder: placeholder,
          )
        : placeholder;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: art),
            if (watched)
              const Positioned(
                top: 8,
                right: 8,
                child: WatchedCheckMark(size: 28),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final fg =
        selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primaryContainer
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _durationLabel(int secs) {
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
