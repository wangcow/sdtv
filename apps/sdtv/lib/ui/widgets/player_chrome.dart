import 'package:flutter/material.dart';
import 'package:sdtv_player/sdtv_player.dart';

/// Couch-first playback HUD drawn **on top of** an embedded video surface.
///
/// Spike for TiviMate-like controls (not external-mpv `show-text` OSD).
///
/// [liveMode] hides seek: live IPTV usually has no useful timeline.
enum PlayerChromeFocus {
  seekBack,
  playPause,
  seekFwd,
  /// Scrubber only when [canSeek].
  scrubber,
  back,
}

/// Bottom + top chrome: title, transport, optional scrubber, hints.
class PlayerChrome extends StatelessWidget {
  const PlayerChrome({
    super.key,
    required this.title,
    required this.subtitle,
    required this.playerState,
    required this.position,
    required this.duration,
    required this.canSeek,
    required this.liveMode,
    required this.focus,
    required this.showChrome,
    this.decodeLabel,
    this.perfLabel,
    this.onPlayPause,
    this.onSeekBack,
    this.onSeekFwd,
    this.onBack,
    this.onScrub,
  });

  final String title;
  final String subtitle;
  final SdtvPlayerState playerState;
  final Duration position;
  final Duration duration;
  final bool canSeek;
  final bool liveMode;
  final PlayerChromeFocus focus;
  final bool showChrome;
  final String? decodeLabel;
  /// e.g. perf: 28fps · tex360p · vaapi-copy · src 1280x720
  final String? perfLabel;

  final VoidCallback? onPlayPause;
  final VoidCallback? onSeekBack;
  final VoidCallback? onSeekFwd;
  final VoidCallback? onBack;
  final ValueChanged<double>? onScrub;

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

    return Stack(
      fit: StackFit.expand,
      children: [
        // Soft top/bottom scrims so white type stays readable.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xCC000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xE6000000),
                ],
                stops: [0.0, 0.28, 0.55, 1.0],
              ),
            ),
          ),
        ),

        // —— Top: title + live badge ——
        Positioned(
          left: 28,
          right: 28,
          top: pad.top + 20,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Badge(
                label: liveMode ? 'LIVE' : playerState.name.toUpperCase(),
                emphasized: liveMode,
              ),
            ],
          ),
        ),

        // —— Bottom: scrubber + transport ——
        Positioned(
          left: 24,
          right: 24,
          bottom: pad.bottom + 18,
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
                const SizedBox(height: 14),
              ] else if (liveMode) ...[
                Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: Colors.red.shade400),
                    const SizedBox(width: 8),
                    Text(
                      'Live · no scrubber',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: Colors.white60,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!liveMode && canSeek) ...[
                    _ChromeIconButton(
                      icon: Icons.replay_10_rounded,
                      label: '−10s',
                      focused: focus == PlayerChromeFocus.seekBack,
                      onTap: onSeekBack,
                    ),
                    const SizedBox(width: 18),
                  ],
                  _ChromeIconButton(
                    icon: _playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    label: _playing ? 'Pause' : 'Play',
                    focused: focus == PlayerChromeFocus.playPause,
                    large: true,
                    onTap: onPlayPause,
                  ),
                  if (!liveMode && canSeek) ...[
                    const SizedBox(width: 18),
                    _ChromeIconButton(
                      icon: Icons.forward_10_rounded,
                      label: '+10s',
                      focused: focus == PlayerChromeFocus.seekFwd,
                      onTap: onSeekFwd,
                    ),
                  ],
                  const SizedBox(width: 28),
                  _ChromeIconButton(
                    icon: Icons.arrow_back_rounded,
                    label: 'Back',
                    focused: focus == PlayerChromeFocus.back,
                    onTap: onBack,
                  ),
                ],
              ),

              const SizedBox(height: 12),
              Text(
                liveMode
                    ? 'A play/pause · LB/RB channel · B back · ←→ move chrome'
                    : canSeek
                        ? '←→ buttons · ↑ scrubber · ←→ seek on bar · ↓ back · A · B'
                        : 'A play/pause · B back · ←→ move chrome',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white54,
                ),
              ),
              if (perfLabel != null && perfLabel!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  perfLabel!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.lightGreenAccent.withValues(alpha: 0.85),
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (decodeLabel != null && decodeLabel!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  decodeLabel!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white38,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
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
          child: Slider(
            value: progress,
            onChanged: onScrub,
          ),
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
  });

  final IconData icon;
  final String label;
  final bool focused;
  final bool large;
  final VoidCallback? onTap;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
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
                        color: theme.colorScheme.primary.withValues(alpha: 0.45),
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
            style: theme.textTheme.labelMedium?.copyWith(
              color: focused ? Colors.white : Colors.white60,
              fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
