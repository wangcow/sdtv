import 'package:flutter/material.dart';
import 'package:sdtv_player/sdtv_player.dart';

/// Couch-first playback HUD.
///
/// Rasterized onto external mpv (`overlay-add`) by `MpvFlutterHud`.
/// Not mpv `show-text`.
///
/// [liveMode] swaps seek for channel buttons and shows the programme guide
/// line instead of a scrubber.
enum PlayerChromeFocus {
  prevChannel,
  seekBack,
  playPause,
  seekFwd,
  nextChannel,

  /// Flip back to the channel watched before this one.
  lastChannel,

  /// Play the next episode of the show (VOD).
  nextEpisode,
  subtitles,
  audio,
  favorite,

  /// Scrubber only when [canSeek]. Not part of [PlayerChrome.buttons].
  scrubber,
  back,
}

/// Now / next programme for the live info panel.
class ChromeProgramme {
  const ChromeProgramme({
    required this.title,
    required this.timeRange,
    required this.progress,
    this.next,
  });

  final String title;

  /// e.g. `8:00 PM–9:00 PM`
  final String timeRange;

  /// 0..1 through the programme.
  final double progress;

  /// e.g. `Next  9:00 PM  Evening News`
  final String? next;
}

/// Top bar (title, info chips, clock) + bottom panel (programme or
/// scrubber, button row, hint). Each is its own band so the HUD only sends
/// those strips to mpv.
class PlayerChrome extends StatelessWidget {
  const PlayerChrome({
    super.key,
    required this.title,
    required this.playerState,
    required this.position,
    required this.duration,
    required this.canSeek,
    required this.liveMode,
    required this.focus,
    required this.showChrome,
    required this.buttons,
    this.favorite = false,
    this.logo,
    this.logoIsPoster = false,
    this.programme,
    this.subtitleLabel,
    this.audioLabel,
    this.clock,
    this.infoChips = const [],
    this.onAction,
    this.onScrub,
    this.topBandKey,
    this.bottomBandKey,
    this.animate = true,
  });

  final String title;
  final SdtvPlayerState playerState;
  final Duration position;
  final Duration duration;
  final bool canSeek;
  final bool liveMode;
  final PlayerChromeFocus focus;
  final bool showChrome;

  /// Button row, left to right. The HUD owns the order (it also drives
  /// ←/→ focus), so both always agree.
  final List<PlayerChromeFocus> buttons;

  final bool favorite;

  /// Channel logo, already decoded (the mpv HUD captures one frame, so a
  /// still-loading image would be caught blank).
  final ImageProvider? logo;

  /// [logo] is a 2:3 poster (movie / show) rather than a channel logo.
  final bool logoIsPoster;
  final ChromeProgramme? programme;
  final String? subtitleLabel;
  final String? audioLabel;

  /// Wall clock for the top bar, e.g. `8:42 PM`.
  final String? clock;

  /// Small stream facts, e.g. `1080p`, `HW`.
  final List<String> infoChips;

  /// A tap (or A on the focused button). Pad input goes through the HUD.
  final ValueChanged<PlayerChromeFocus>? onAction;

  /// Seek to a 0..1 fraction (tap / drag on the scrubber).
  final ValueChanged<double>? onScrub;

  /// Keys for the top / bottom band [RepaintBoundary]s. The mpv HUD captures
  /// each band on its own so the clear middle of the screen is never sent.
  final Key? topBandKey;
  final Key? bottomBandKey;

  /// Focus transitions. Off for the mpv bitmap: it captures one frame per
  /// change, so a tween would be caught at its start.
  final bool animate;

  bool get _playing =>
      playerState == SdtvPlayerState.playing ||
      playerState == SdtvPlayerState.buffering;

  @override
  Widget build(BuildContext context) {
    if (!showChrome) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final progress = canSeek && duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // Each band carries its own scrim and fades to clear at its inner edge,
    // so the middle of the picture is untouched.
    final top = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x66000000), Color(0x00000000)],
          stops: [0.0, 0.6, 1.0],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(28, pad.top + 20, 28, 28),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (logo != null) ...[
              Container(
                width: logoIsPoster ? 44 : 76,
                height: logoIsPoster ? 66 : 48,
                padding: logoIsPoster
                    ? EdgeInsets.zero
                    : const EdgeInsets.all(4),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(logoIsPoster ? 6 : 8),
                ),
                child: Image(
                  image: logo!,
                  fit: logoIsPoster ? BoxFit.cover : BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: 14),
            ],
            if (favorite) ...[
              Icon(Icons.star_rounded, color: Colors.amber.shade400, size: 28),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
            ),
            const SizedBox(width: 12),
            for (final chip in infoChips) ...[
              _InfoChip(label: chip),
              const SizedBox(width: 8),
            ],
            _Badge(
              label: liveMode ? 'LIVE' : playerState.name.toUpperCase(),
              emphasized: liveMode,
            ),
            if (clock != null) ...[
              const SizedBox(width: 16),
              Text(
                clock!,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );

    final bottom = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB3000000), Color(0xE6000000)],
          stops: [0.0, 0.35, 1.0],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(28, 28, 28, pad.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (canSeek && !liveMode) ...[
              _ScrubberRow(
                position: position,
                duration: duration,
                progress: progress,
                focused: focus == PlayerChromeFocus.scrubber,
                onScrub: onScrub,
              ),
              const SizedBox(height: 10),
            ] else if (liveMode) ...[
              _ProgrammePanel(programme: programme),
              const SizedBox(height: 16),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) SizedBox(width: _gapBefore(buttons[i])),
                  _button(buttons[i]),
                ],
              ],
            ),
            // No hint line: every button is labelled, and each extra row is
            // pixels sent to mpv on every HUD update.
          ],
        ),
      ),
    );

    return SizedBox.expand(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RepaintBoundary(key: topBandKey, child: top),
          const Spacer(),
          RepaintBoundary(key: bottomBandKey, child: bottom),
        ],
      ),
    );
  }

  /// Transport buttons sit close together; settings and Back are grouped
  /// apart from them.
  static double _gapBefore(PlayerChromeFocus f) => switch (f) {
    PlayerChromeFocus.subtitles || PlayerChromeFocus.back => 36,
    _ => 16,
  };

  Widget _button(PlayerChromeFocus f) {
    final (IconData icon, String label, bool large) = switch (f) {
      PlayerChromeFocus.prevChannel => (
        Icons.skip_previous_rounded,
        'Prev ch',
        false,
      ),
      PlayerChromeFocus.nextChannel => (
        Icons.skip_next_rounded,
        'Next ch',
        false,
      ),
      PlayerChromeFocus.lastChannel => (
        Icons.swap_horiz_rounded,
        'Last ch',
        false,
      ),
      PlayerChromeFocus.nextEpisode => (
        Icons.skip_next_rounded,
        'Next ep',
        false,
      ),
      PlayerChromeFocus.seekBack => (Icons.replay_10_rounded, '−10s', false),
      PlayerChromeFocus.seekFwd => (Icons.forward_10_rounded, '+10s', false),
      PlayerChromeFocus.playPause => (
        _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        _playing ? 'Pause' : 'Play',
        true,
      ),
      PlayerChromeFocus.subtitles => (
        (subtitleLabel ?? 'Off') == 'Off'
            ? Icons.closed_caption_disabled_outlined
            : Icons.closed_caption_rounded,
        'CC · ${subtitleLabel ?? 'Off'}',
        false,
      ),
      PlayerChromeFocus.audio => (
        Icons.audiotrack_rounded,
        audioLabel ?? 'Audio',
        false,
      ),
      PlayerChromeFocus.favorite => (
        favorite ? Icons.star_rounded : Icons.star_outline_rounded,
        favorite ? 'Favourite' : 'Add fav',
        false,
      ),
      PlayerChromeFocus.back => (
        liveMode ? Icons.grid_view_rounded : Icons.arrow_back_rounded,
        liveMode ? 'Guide' : 'Back',
        false,
      ),
      PlayerChromeFocus.scrubber => (Icons.linear_scale, 'Seek', false),
    };
    return _ChromeIconButton(
      animate: animate,
      icon: icon,
      label: label,
      focused: focus == f,
      large: large,
      onTap: onAction == null ? null : () => onAction!(f),
    );
  }
}

/// Live programme: title, time range, progress, and what is next.
class _ProgrammePanel extends StatelessWidget {
  const _ProgrammePanel({required this.programme});

  final ChromeProgramme? programme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = programme;
    if (p == null) {
      return Text(
        'No programme info',
        style: theme.textTheme.titleMedium?.copyWith(color: Colors.white60),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                p.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              p.timeRange,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white70,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: p.progress.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
          ),
        ),
        if (p.next != null) ...[
          const SizedBox(height: 8),
          Text(
            p.next!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white60),
          ),
        ],
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white38),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Colors.white70,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, this.emphasized = false});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: emphasized
            ? Colors.red.shade700.withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: emphasized
              ? Colors.red.shade200.withValues(alpha: 0.5)
              : Colors.white24,
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _ScrubberRow extends StatelessWidget {
  const _ScrubberRow({
    required this.position,
    required this.duration,
    required this.progress,
    required this.focused,
    this.onScrub,
  });

  final Duration position;
  final Duration duration;
  final double progress;
  final bool focused;
  final ValueChanged<double>? onScrub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: focused ? 8 : 5,
            thumbShape: RoundSliderThumbShape(
              enabledThumbRadius: focused ? 11 : 8,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            activeTrackColor: focused
                ? theme.colorScheme.primary
                : theme.colorScheme.primary.withValues(alpha: 0.85),
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
            overlayColor: theme.colorScheme.primary.withValues(alpha: 0.25),
          ),
          child: Slider(value: progress, onChanged: onScrub),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Text(
                _fmt(position),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white70,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Text(
                _fmt(duration),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white54,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '${d.inMinutes.remainder(60)}:$s';
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({
    required this.icon,
    required this.label,
    required this.focused,
    this.large = false,
    this.onTap,
    this.animate = true,
  });

  final IconData icon;
  final String label;
  final bool focused;
  final bool large;
  final VoidCallback? onTap;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = large ? 64.0 : 48.0;
    final iconSize = large ? 36.0 : 26.0;
    final bg = focused
        ? theme.colorScheme.primary
        : Colors.white.withValues(alpha: 0.12);
    final fg = focused ? theme.colorScheme.onPrimary : Colors.white;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 92,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: animate
                  ? const Duration(milliseconds: 120)
                  : Duration.zero,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: Border.all(
                  color: focused
                      ? theme.colorScheme.primaryContainer
                      : Colors.white24,
                  width: focused ? 3 : 1.5,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.45,
                          ),
                          blurRadius: 16,
                        ),
                      ]
                    : null,
              ),
              child: Icon(icon, color: fg, size: iconSize),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: focused ? Colors.white : Colors.white60,
                fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
