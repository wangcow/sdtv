import 'package:flutter/material.dart';
import 'package:sdtv_input/sdtv_input.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../state/session_controller.dart';

/// Fullscreen player: media_kit [Video] surface + couch controls.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.session});

  final SessionController session;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _showHud = true;

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
    final vc = player.videoController;
    final err = player.lastError;

    return SdtvInputScope(
      onBack: _exit,
      onMenu: _exit,
      onConfirm: () async {
        if (state == SdtvPlayerState.playing) {
          await player.pause();
        } else if (state == SdtvPlayerState.paused ||
            state == SdtvPlayerState.idle ||
            state == SdtvPlayerState.error) {
          if (state == SdtvPlayerState.error && url.isNotEmpty) {
            await player.open(Uri.parse(url));
          } else {
            await player.play();
          }
        }
        setState(() => _showHud = true);
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
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            if (intent.direction == TraversalDirection.up) {
              widget.session.playAdjacent(-1);
            } else if (intent.direction == TraversalDirection.down) {
              widget.session.playAdjacent(1);
            }
            setState(() => _showHud = true);
            return null;
          },
        ),
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showHud = !_showHud),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Video surface
              if (vc != null)
                Video(
                  controller: vc,
                  controls: NoVideoControls,
                  fill: Colors.black,
                )
              else
                const ColoredBox(color: Colors.black),

              // Buffering / error / opening chrome
              if (state == SdtvPlayerState.opening ||
                  state == SdtvPlayerState.buffering)
                const Center(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              if (state == SdtvPlayerState.error)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            color: Colors.white70, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          'Playback error',
                          style: theme.textTheme.titleLarge
                              ?.copyWith(color: Colors.white),
                        ),
                        if (err != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            err,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: Colors.white54),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          'A retry · B back',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                ),

              // HUD
              if (_showHud) ...[
                Positioned(
                  left: 24,
                  right: 24,
                  top: MediaQuery.paddingOf(context).top + 16,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          ch?.name ?? 'No channel',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            shadows: const [
                              Shadow(blurRadius: 8, color: Colors.black),
                            ],
                          ),
                        ),
                      ),
                      Text(
                        state.name.toUpperCase(),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white70,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: MediaQuery.paddingOf(context).bottom + 20,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.session.useDemo)
                        Text(
                          'Demo stream (public test HLS)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white54,
                          ),
                        ),
                      Text(
                        'A pause/play · ↑↓ channel · B back',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                          shadows: const [
                            Shadow(blurRadius: 6, color: Colors.black),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
