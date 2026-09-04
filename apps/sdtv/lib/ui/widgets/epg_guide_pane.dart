import 'package:flutter/material.dart';
import 'package:sdtv_core/sdtv_core.dart';

import '../epg_grid.dart';

/// Live-pane TV Guide grid (replaces the channel list + now/next miniguide).
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
          SizedBox(
            height: kEpgHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'GUIDE · ${categoryTitle.toUpperCase()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  Text(
                    epgAxisLabel(now),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final programWidth =
                    (constraints.maxWidth - kEpgGutterWidth).clamp(120.0, 4000.0);
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
                        gutter: const SizedBox.expand(),
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
          _EpgDetail(
            channel: focused,
            program: sel,
            m3u: m3u,
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
            left: layout.xFor(tick),
            top: 0,
            bottom: 0,
            child: Row(
              children: [
                Container(
                  width: 1,
                  color: theme.colorScheme.outline.withValues(alpha: 0.45),
                ),
                const SizedBox(width: 6),
                Text(
                  epgAxisLabel(tick),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        if (nowX != null)
          Positioned(
            left: nowX,
            top: 0,
            bottom: 0,
            child: Container(width: 2, color: theme.colorScheme.primary),
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
  });

  final LiveChannel channel;
  final bool selected;
  final bool gridFocused;
  final EpgLayout layout;
  final DateTime now;
  final ShortEpg? epg;
  final DateTime? focusTime;
  final bool m3u;
  final VoidCallback onTapChannel;
  final VoidCallback? onLongPressChannel;
  final ValueChanged<EpgProgram> onTapProgram;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = selected && gridFocused;
    final dim = selected && !gridFocused;
    final fg = active
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final programs = epg?.inWindow(layout.windowStart, layout.windowEnd) ??
        const <EpgProgram>[];
    final focusIdx = epg == null || focusTime == null
        ? -1
        : epg!.indexForTime(focusTime!);
    final focusedProgram = (focusIdx >= 0 && epg != null)
        ? epg!.listings[focusIdx.clamp(0, epg!.listings.length - 1)]
        : null;
    final nowX = layout.contains(now) ? layout.xFor(now) : null;
    final label = channel.num > 0
        ? '${channel.num}. ${channel.name}'
        : channel.name;

    return SizedBox(
      height: kEpgRowExtent,
      child: _EpgLane(
        gutter: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: GestureDetector(
            onTap: onTapChannel,
            onLongPress: onLongPressChannel,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: active
                    ? theme.colorScheme.primary
                    : dim
                        ? theme.colorScheme.primary.withValues(alpha: 0.28)
                        : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          ),
        ),
        program: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              for (final tick in layout.ticks)
                Positioned(
                  left: layout.xFor(tick),
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 1,
                      color: theme.colorScheme.outline.withValues(alpha: 0.28),
                    ),
                  ),
                ),
              if (programs.isEmpty)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        epg == null && !m3u ? 'Loading…' : 'No EPG',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.outline,
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
                    if (width < 8) return const SizedBox.shrink();
                    final focused = focusedProgram != null &&
                        _sameProgram(p, focusedProgram);
                    return Positioned(
                      left: left,
                      width: width,
                      top: 0,
                      bottom: 0,
                      child: _EpgCell(
                        program: p,
                        now: now,
                        focused: focused && gridFocused,
                        dim: focused && !gridFocused,
                        onTap: () => onTapProgram(p),
                      ),
                    );
                  },
                ),
              if (nowX != null)
                Positioned(
                  left: nowX,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
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
    required this.dim,
    required this.onTap,
  });

  final EpgProgram program;
  final DateTime now;
  final bool focused;
  final bool dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = program.isLiveAt(now);
    final bg = focused
        ? theme.colorScheme.primary
        : dim
            ? theme.colorScheme.primary.withValues(alpha: 0.28)
            : live
                ? theme.colorScheme.primary.withValues(alpha: 0.22)
                : theme.colorScheme.surfaceContainerHighest;
    final fg = focused
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: focused || dim
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withValues(alpha: 0.25),
            width: focused ? 2 : 1,
          ),
        ),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                program.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: focused || live ? FontWeight.w700 : FontWeight.w500,
                  height: 1.15,
                ),
              ),
            ),
            if (live && !focused)
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: program.progressAt(now).clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EpgDetail extends StatelessWidget {
  const _EpgDetail({
    required this.channel,
    required this.program,
    required this.m3u,
  });

  final LiveChannel? channel;
  final EpgProgram? program;
  final bool m3u;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ch = channel;
    final p = program;
    final chName = ch == null
        ? ''
        : (ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name);
    String body;
    if (m3u) {
      body = 'M3U playlists have no panel EPG. A still plays the channel.';
    } else if (p == null) {
      body = 'No program data for this time. A plays the live channel.';
    } else if (p.description.trim().isEmpty) {
      body = p.timeRangeLabel();
    } else {
      body = p.description.trim();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.25),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            p?.title ?? (chName.isEmpty ? 'TV Guide' : chName),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (p != null) ...[
            const SizedBox(height: 2),
            Text(
              '${p.timeRangeLabel()}${chName.isEmpty ? '' : '  ·  $chName'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
