import 'package:flutter/material.dart';

import '../../state/watch_menu.dart';

/// On-video pause / stall menu. Rasterized onto mpv by `MpvFlutterHud`.
///
/// No animations: the HUD captures one frame per change.
class WatchMenuCard extends StatelessWidget {
  const WatchMenuCard({super.key, required this.model});

  final WatchMenuModel model;

  static const _panel = Color(0xF2161A22);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      width: 520,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: model.isError
              ? Colors.red.shade300.withValues(alpha: 0.45)
              : Colors.white12,
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x99000000), blurRadius: 28, spreadRadius: 2),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(model: model),
          const SizedBox(height: 10),
          Text(
            model.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          if (model.timeLine != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (model.progress ?? 0).clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.14),
                      valueColor: AlwaysStoppedAnimation(scheme.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  model.timeLine!,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white70,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          for (var i = 0; i < model.rows.length; i++)
            _Row(row: model.rows[i], focused: i == model.selected),
          const SizedBox(height: 12),
          Text(
            model.hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.model});

  final WatchMenuModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (model.isError) {
      return Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Colors.red.shade300,
            size: 26,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              model.errorMessage ?? 'Playback problem',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.red.shade100,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _Chip(
            label: model.errorCode!,
            color: Colors.red.shade700.withValues(alpha: 0.85),
          ),
        ],
      );
    }
    return Row(
      children: [
        _Chip(
          label: model.live ? 'LIVE' : 'PAUSED',
          color: model.live
              ? Colors.red.shade700.withValues(alpha: 0.92)
              : Colors.white.withValues(alpha: 0.14),
        ),
        if (model.live) ...[
          const SizedBox(width: 10),
          Text(
            'Paused',
            style: theme.textTheme.labelLarge?.copyWith(color: Colors.white60),
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row, required this.focused});

  final WatchMenuRow row;
  final bool focused;

  static IconData _icon(String id) => switch (id) {
    'resume' => Icons.play_arrow_rounded,
    'retry' => Icons.refresh_rounded,
    'seekBack' => Icons.replay_10_rounded,
    'seekFwd' => Icons.forward_10_rounded,
    'subtitles' => Icons.closed_caption_outlined,
    'audio' => Icons.audiotrack_outlined,
    'mute' => Icons.volume_off_outlined,
    _ => Icons.arrow_back_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = focused ? scheme.onPrimary : Colors.white;
    final value = row.value;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: focused ? scheme.primary : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(_icon(row.id), color: fg, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              row.label,
              style: theme.textTheme.titleMedium?.copyWith(
                color: fg,
                fontWeight: focused ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
          if (value != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 230),
              child: Text(
                row.adjustable && focused ? '‹  $value  ›' : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: focused
                      ? scheme.onPrimary.withValues(alpha: 0.9)
                      : Colors.white60,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
