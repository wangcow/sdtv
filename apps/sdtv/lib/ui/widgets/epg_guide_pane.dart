import 'package:flutter/material.dart';
import 'package:sdtv_core/sdtv_core.dart';

import '../../services/artwork_cache.dart';
import '../epg_grid.dart';
import 'cached_artwork.dart';

/// Gap between grid cells (rows and programmes). The background shows
/// through, which draws the grid lines.
const _kGap = 2.0;

/// Live-pane TV Guide: programme info on top, then a time axis and a flat
/// channel × time grid (TiviMate-style).
class EpgGuidePane extends StatelessWidget {
  const EpgGuidePane({
    super.key,
    required this.channels,
    required this.channelIndex,
    required this.categoryTitle,
    required this.windowStart,
    required this.focusTime,
    required this.now,
    required this.epgFor,
    required this.scrollController,
    required this.onTapChannel,
    required this.onTapProgram,
    this.onLongPressChannel,
    this.onProgramWidth,
    this.gridFocused = true,
    this.m3u = false,
    this.emptyMessage,
    this.isFavorite,
    this.artwork,
    this.artworkScope = '',
  });

  final List<LiveChannel> channels;
  final int channelIndex;
  final String categoryTitle;
  final DateTime windowStart;
  final DateTime focusTime;
  final DateTime now;
  final ShortEpg? Function(LiveChannel channel) epgFor;
  final ScrollController scrollController;
  final ValueChanged<int> onTapChannel;
  final void Function(int channelIndex, EpgProgram program) onTapProgram;
  final ValueChanged<int>? onLongPressChannel;
  final ValueChanged<double>? onProgramWidth;

  /// Pad is on the grid (not the category column).
  final bool gridFocused;
  final bool m3u;
  final String? emptyMessage;

  /// ★ next to favourite channels.
  final bool Function(LiveChannel channel)? isFavorite;

  /// Channel logos (provider `stream_icon`). Null hides the logo tile.
  final ArtworkCache? artwork;
  final String artworkScope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chans = channels;
    final ci = chans.isEmpty ? 0 : channelIndex.clamp(0, chans.length - 1);
    final focused = chans.isEmpty ? null : chans[ci];
    final epg = focused == null ? null : epgFor(focused);
    final listings = epg?.listings ?? const <EpgProgram>[];
    final sel = listings.isEmpty
        ? null
        : listings[epg!.indexForTime(focusTime).clamp(0, listings.length - 1)];

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoPanel(channel: focused, program: sel, now: now, m3u: m3u),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final programWidth = (constraints.maxWidth - kEpgGutterWidth)
                    .clamp(120.0, 4000.0);
                final onWidth = onProgramWidth;
                if (onWidth != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    onWidth(programWidth);
                  });
                }
                final layout = epgLayoutFor(
                  windowStart: windowStart,
                  programWidth: programWidth,
                );
                return Column(
                  children: [
                    SizedBox(
                      height: kEpgTimeHeaderHeight,
                      child: _EpgLane(
                        gutter: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              categoryTitle.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                                letterSpacing: 1.1,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        program: _TimeAxis(layout: layout, now: now),
                      ),
                    ),
                    Expanded(
                      child: chans.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                emptyMessage ?? 'No channels in this category.',
                                style: theme.textTheme.bodyLarge,
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemExtent: kEpgRowExtent,
                              itemCount: chans.length,
                              padding: const EdgeInsets.only(bottom: 8),
                              itemBuilder: (context, i) {
                                final ch = chans[i];
                                final selected = i == ci;
                                return _EpgRow(
                                  channel: ch,
                                  selected: selected,
                                  gridFocused: gridFocused,
                                  layout: layout,
                                  now: now,
                                  epg: epgFor(ch),
                                  focusTime: selected ? focusTime : null,
                                  m3u: m3u,
                                  favorite: isFavorite?.call(ch) ?? false,
                                  artwork: artwork,
                                  artworkScope: artworkScope,
                                  onTapChannel: () => onTapChannel(i),
                                  onLongPressChannel: onLongPressChannel == null
                                      ? null
                                      : () => onLongPressChannel!(i),
                                  onTapProgram: (p) => onTapProgram(i, p),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Channel gutter + program column. Header and every row must use this so
/// tick x-coordinates line up with program edges.
class _EpgLane extends StatelessWidget {
  const _EpgLane({required this.gutter, required this.program});

  final Widget gutter;
  final Widget program;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: kEpgGutterWidth, child: gutter),
        Expanded(child: program),
      ],
    );
  }
}

class _TimeAxis extends StatelessWidget {
  const _TimeAxis({required this.layout, required this.now});

  final EpgLayout layout;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nowX = layout.contains(now) ? layout.xFor(now) : null;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        for (final tick in layout.ticks)
          Positioned(
            left: layout.xFor(tick) + 8,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                epgAxisLabel(tick),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (nowX != null)
          Positioned(
            left: nowX - 4,
            bottom: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

class _EpgRow extends StatelessWidget {
  const _EpgRow({
    required this.channel,
    required this.selected,
    required this.gridFocused,
    required this.layout,
    required this.now,
    required this.epg,
    required this.onTapChannel,
    required this.onTapProgram,
    this.onLongPressChannel,
    this.focusTime,
    this.m3u = false,
    this.favorite = false,
    this.artwork,
    this.artworkScope = '',
  });

  final LiveChannel channel;
  final bool selected;
  final bool gridFocused;
  final EpgLayout layout;
  final DateTime now;
  final ShortEpg? epg;
  final DateTime? focusTime;
  final bool m3u;
  final bool favorite;
  final ArtworkCache? artwork;
  final String artworkScope;
  final VoidCallback onTapChannel;
  final VoidCallback? onLongPressChannel;
  final ValueChanged<EpgProgram> onTapProgram;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final programs =
        epg?.inWindow(layout.windowStart, layout.windowEnd) ??
        const <EpgProgram>[];
    final focusIdx = epg == null || focusTime == null
        ? -1
        : epg!.indexForTime(focusTime!);
    final focusedProgram = (focusIdx >= 0 && epg != null)
        ? epg!.listings[focusIdx.clamp(0, epg!.listings.length - 1)]
        : null;
    final nowX = layout.contains(now) ? layout.xFor(now) : null;

    // The channel cell lights up while the categories have the pad, so the
    // row you will return to is obvious; in the grid the programme does.
    final channelBg = selected
        ? (gridFocused
              ? scheme.primary.withValues(alpha: 0.22)
              : scheme.primary.withValues(alpha: 0.32))
        : scheme.surfaceContainerHigh;
    final fg = scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(bottom: _kGap),
      child: _EpgLane(
        gutter: GestureDetector(
          onTap: onTapChannel,
          onLongPress: onLongPressChannel,
          child: Container(
            margin: const EdgeInsets.only(right: _kGap),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: channelBg,
              border: selected
                  ? Border(left: BorderSide(color: scheme.primary, width: 3))
                  : null,
            ),
            child: Row(
              children: [
                if (channel.num > 0)
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${channel.num}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: fg.withValues(alpha: 0.55),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (artwork != null) ...[
                  ChannelLogo(
                    channel: channel,
                    cache: artwork!,
                    scope: artworkScope,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                if (favorite)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.star_rounded,
                      size: 16,
                      color: Colors.amber.shade400,
                    ),
                  ),
              ],
            ),
          ),
        ),
        program: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: scheme.surfaceContainer.withValues(alpha: 0.6),
              ),
            ),
            if (programs.isEmpty)
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      epg == null && !m3u ? 'Loading…' : 'No programme info',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
            for (final p in programs)
              Builder(
                builder: (context) {
                  final left = layout.clipLeft(p.start);
                  final width = layout.clipWidth(p.start, p.end);
                  if (width < 6) return const SizedBox.shrink();
                  final focused =
                      focusedProgram != null && _sameProgram(p, focusedProgram);
                  return Positioned(
                    left: left,
                    width: width,
                    top: 0,
                    bottom: 0,
                    child: _EpgCell(
                      program: p,
                      now: now,
                      focused: focused && gridFocused,
                      onTap: () => onTapProgram(p),
                    ),
                  );
                },
              ),
            if (nowX != null)
              Positioned(
                left: nowX - 1,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(width: 2, color: scheme.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

bool _sameProgram(EpgProgram a, EpgProgram b) {
  if (a.id.isNotEmpty && b.id.isNotEmpty) return a.id == b.id;
  return a.start == b.start && a.title == b.title;
}

class _EpgCell extends StatelessWidget {
  const _EpgCell({
    required this.program,
    required this.now,
    required this.focused,
    required this.onTap,
  });

  final EpgProgram program;
  final DateTime now;
  final bool focused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final live = program.isLiveAt(now);
    final bg = focused
        ? scheme.primary
        : live
        ? scheme.surfaceContainerHighest
        : scheme.surfaceContainerHigh;
    final fg = focused ? scheme.onPrimary : scheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: _kGap),
        color: bg,
        child: LayoutBuilder(
          builder: (context, c) {
            final roomy = c.maxWidth >= 110;
            return Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        program.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: fg,
                          fontWeight: focused || live
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      if (roomy) ...[
                        const SizedBox(height: 2),
                        Text(
                          program.timeRangeLabel(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: fg.withValues(alpha: focused ? 0.85 : 0.55),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (live)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: program.progressAt(now).clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(
                        focused ? scheme.onPrimary : scheme.primary,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Selected programme at the top of the guide, like TiviMate.
class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.channel,
    required this.program,
    required this.now,
    required this.m3u,
  });

  final LiveChannel? channel;
  final EpgProgram? program;
  final DateTime now;
  final bool m3u;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ch = channel;
    final p = program;
    final chName = ch == null
        ? ''
        : (ch.num > 0 ? '${ch.num}  ${ch.name}' : ch.name);
    final live = p != null && p.isLiveAt(now);
    String body;
    if (m3u) {
      body = 'M3U playlists have no panel EPG. A still plays the channel.';
    } else if (p == null) {
      body = 'No programme data for this time. A plays the live channel.';
    } else {
      body = p.description.trim();
    }

    return Container(
      height: 132,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      color: scheme.surfaceContainerLow,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p?.title ?? (chName.isEmpty ? 'TV Guide' : chName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (live) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade700,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'LIVE',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        [
                          if (p != null) p.timeRangeLabel(),
                          if (chName.isNotEmpty) chName,
                        ].join('   ·   '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (live) ...[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: p.progressAt(now).clamp(0.0, 1.0),
                            minHeight: 4,
                            backgroundColor: scheme.outline.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (body.isNotEmpty)
                  Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.75),
                      height: 1.35,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Text(
            epgAxisLabel(now),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Provider channel logo in a fixed tile, so names line up with or without
/// one. Shows a faint TV glyph until (or unless) the logo loads.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({
    super.key,
    required this.channel,
    required this.cache,
    required this.scope,
    this.width = 48,
    this.height = 34,
  });

  final LiveChannel channel;
  final ArtworkCache cache;
  final String scope;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = Center(
      child: Icon(
        Icons.tv_rounded,
        size: height * 0.55,
        color: Colors.white.withValues(alpha: 0.25),
      ),
    );
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: channel.streamIcon.trim().isEmpty
          ? placeholder
          : CachedArtwork(
              cache: cache,
              scope: scope,
              kind: ArtworkCache.kindChannel,
              id: '${channel.streamId}',
              url: channel.streamIcon,
              fit: BoxFit.contain,
              alignment: Alignment.center,
              cacheHeight: (height * dpr * 1.5).round(),
              placeholder: placeholder,
            ),
    );
  }
}
