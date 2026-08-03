import 'package:flutter/material.dart';
import 'package:sdtv_input/sdtv_input.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../state/session_controller.dart';

/// Fullscreen-ish player shell. Stub playback until media_kit is wired.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.session});

  final SessionController session;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  @override
  void initState() {
    super.initState();
    widget.session.player.addListener(_onPlayer);
  }

  void _onPlayer() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.player.removeListener(_onPlayer);
    super.dispose();
  }

  Future<void> _back() async {
    await widget.session.stopPlayback();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ch = widget.session.nowPlaying;
    final player = widget.session.player;
    final state = player.state;
    final url = player.currentUrl ?? '';

    return SdtvInputScope(
      onBack: _back,
      onConfirm: () async {
        if (state == SdtvPlayerState.playing) {
          await player.pause();
        } else {
          await player.play();
        }
      },
      extraActions: {
        SdtvChannelUpIntent: CallbackAction<SdtvChannelUpIntent>(
          onInvoke: (_) {
            widget.session.playAdjacent(1);
            return null;
          },
        ),
        SdtvChannelDownIntent: CallbackAction<SdtvChannelDownIntent>(
          onInvoke: (_) {
            widget.session.playAdjacent(-1);
            return null;
          },
        ),
        SdtvPageUpIntent: CallbackAction<SdtvPageUpIntent>(
          onInvoke: (_) {
            widget.session.playAdjacent(-1);
            return null;
          },
        ),
        SdtvPageDownIntent: CallbackAction<SdtvPageDownIntent>(
          onInvoke: (_) {
            widget.session.playAdjacent(1);
            return null;
          },
        ),
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              // Video surface placeholder
              Positioned.fill(
                child: Container(
                  color: const Color(0xFF0A0A0C),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.live_tv,
                          size: 96,
                          color: theme.colorScheme.primary.withValues(alpha: 0.7),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          state.name.toUpperCase(),
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: Colors.white70,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Stub player — media_kit / libmpv next',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // OSD top
              Positioned(
                left: 24,
                right: 24,
                top: 24,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ch?.name ?? 'No channel',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      ch != null ? '#${ch.streamId}' : '',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ),
              ),
              // OSD bottom
              Positioned(
                left: 24,
                right: 24,
                bottom: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      url.isEmpty ? '' : url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white38,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SdtvFocusTile(
                          label: 'Previous ch',
                          icon: Icons.skip_previous,
                          onActivate: () => widget.session.playAdjacent(-1),
                        ),
                        SdtvFocusTile(
                          label: state == SdtvPlayerState.paused
                              ? 'Play'
                              : 'Pause',
                          icon: state == SdtvPlayerState.paused
                              ? Icons.play_arrow
                              : Icons.pause,
                          autofocus: true,
                          onActivate: () async {
                            if (state == SdtvPlayerState.playing) {
                              await player.pause();
                            } else {
                              await player.play();
                            }
                          },
                        ),
                        SdtvFocusTile(
                          label: 'Next ch',
                          icon: Icons.skip_next,
                          onActivate: () => widget.session.playAdjacent(1),
                        ),
                        SdtvFocusTile(
                          label: 'Back to list',
                          icon: Icons.list,
                          onActivate: _back,
                        ),
                      ],
                ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
