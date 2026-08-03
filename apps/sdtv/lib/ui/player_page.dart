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

  /// B leaves the player immediately (do not sit on IDLE).
  void _exit() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ch = widget.session.nowPlaying;
    final player = widget.session.player;
    final state = player.state;
    final url = player.currentUrl ?? '';

    return SdtvInputScope(
      onBack: _exit,
      onMenu: _exit,
      onConfirm: () async {
        // A = pause / resume only (not B).
        if (state == SdtvPlayerState.playing) {
          await player.pause();
        } else if (state == SdtvPlayerState.paused ||
            state == SdtvPlayerState.idle) {
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
        // D-pad up/down = channel zap while watching.
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            if (intent.direction == TraversalDirection.up) {
              widget.session.playAdjacent(-1);
            } else if (intent.direction == TraversalDirection.down) {
              widget.session.playAdjacent(1);
            }
            return null;
          },
        ),
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
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
                          color:
                              theme.colorScheme.primary.withValues(alpha: 0.7),
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
                    Text(
                      'A pause/play · ↑↓ channel · B back to list',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
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
