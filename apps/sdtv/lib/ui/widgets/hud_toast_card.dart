import 'package:flutter/material.dart';

import '../../state/hud_toast.dart';

/// Small message pill on the video (volume, mute, retrying, notices).
/// Rasterized onto mpv by `MpvFlutterHud`; no animations.
class HudToastCard extends StatelessWidget {
  const HudToastCard({super.key, required this.toast});

  final HudToast toast;

  IconData get _icon => switch (toast.icon) {
    'volume' => Icons.volume_up_rounded,
    'mute' => Icons.volume_off_rounded,
    'retry' => Icons.refresh_rounded,
    _ => Icons.info_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = toast.level;
    return Container(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
      decoration: BoxDecoration(
        color: const Color(0xEB161A22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 18)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, color: Colors.white, size: 26),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  toast.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (level != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 200,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: level.clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation(
                          theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
