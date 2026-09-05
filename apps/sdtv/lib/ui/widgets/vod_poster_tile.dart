import 'package:flutter/material.dart';

import '../../services/artwork_cache.dart';
import '../vod_grid.dart';
import 'cached_artwork.dart';

/// Movie poster tile. Provider art fills in via [ArtworkCache]; monogram
/// placeholder until then.
class VodPosterTile extends StatelessWidget {
  const VodPosterTile({
    super.key,
    required this.title,
    required this.selected,
    required this.focused,
    required this.onTap,
    this.subtitle,
    this.progress = 0,
    this.watched = false,
    this.posterUrl = '',
    this.artId = '',
    this.artScope = '',
    this.artCache,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final bool focused;
  final VoidCallback onTap;
  final String posterUrl;
  final String artId;
  final String artScope;
  final ArtworkCache? artCache;

  /// 0–1 continue-watching bar on the poster. 0 hides it.
  final double progress;

  /// Finished this title (movie, or every episode of a show).
  final bool watched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = focused || selected;
    final border = focused
        ? theme.colorScheme.primary
        : selected
            ? theme.colorScheme.primary.withValues(alpha: 0.45)
            : Colors.transparent;
    final letters = _monogram(title);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 100),
        scale: focused ? 1.04 : 1.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: kVodPosterAspect,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: border, width: 3),
                  boxShadow: focused
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.4),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Color.lerp(
                            theme.colorScheme.surfaceContainerHighest,
                            theme.colorScheme.primary,
                            0.12,
                          ) ??
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.movie_outlined,
                            size: 36,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.45),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            letters,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (artCache != null && posterUrl.trim().isNotEmpty)
                      Positioned.fill(
                        child: CachedArtwork(
                          cache: artCache!,
                          scope: artScope,
                          kind: ArtworkCache.kindVod,
                          id: artId,
                          url: posterUrl,
                          fit: BoxFit.cover,
                          placeholder: const SizedBox.expand(),
                        ),
                      ),
                    if (progress > 0.02)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: Colors.black38,
                        ),
                      ),
                    if (watched)
                      const Positioned(
                        top: 6,
                        right: 6,
                        child: WatchedCheckMark(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                height: 1.15,
                color: focused
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Green check on a dark disc — readable on any poster.
class WatchedCheckMark extends StatelessWidget {
  const WatchedCheckMark({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    final iconSize = (size * 0.72).clamp(12.0, 22.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 6,
          ),
        ],
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(
            Icons.check_rounded,
            size: iconSize,
            color: const Color(0xFF4ADE80),
          ),
        ),
      ),
    );
  }
}

String _monogram(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'^\d+\.\s*'), '')
      .trim();
  if (cleaned.isEmpty) return '·';
  final parts = cleaned
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length == 1) {
    final w = parts.first;
    return w.length >= 2 ? w.substring(0, 2).toUpperCase() : w.toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}
