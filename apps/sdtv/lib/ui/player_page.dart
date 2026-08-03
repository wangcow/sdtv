import 'dart:async';

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
  DateTime? _lastZapAt;

  /// Keep the same [Video] widget instance across HUD rebuilds so media_kit
  /// does not thrash the platform view on every setState (that was starving
  /// input once bipbop frames started).
  Widget? _stableVideo;

  static const _zapCooldown = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    widget.session.player.addListener(_onTick);
    widget.session.addListener(_onTick);
    final vc = widget.session.player.videoController;
    if (vc != null) {
      _stableVideo = ExcludeFocus(
        child: IgnorePointer(
          child: Video(
            controller: vc,
            controls: NoVideoControls,
            fill: Colors.black,
          ),
        ),
      );
    }
  }

  void _onTick() {
    if (!mounted) return;
    // HUD-only rebuild; video layer is a stable instance.
    setState(() {});
  }

  @override
  void dispose() {
    widget.session.player.removeListener(_onTick);
    widget.session.removeListener(_onTick);
    super.dispose();
  }

  void _exit() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    }
  }

  void _togglePlay() {
    final player = widget.session.player;
    final state = player.state;
    // Fire-and-forget — awaiting pause on a busy UI isolate felt like "A dead".
    if (state == SdtvPlayerState.playing ||
        state == SdtvPlayerState.buffering ||
        state == SdtvPlayerState.opening) {
      unawaited(player.pause());
    } else {
      unawaited(player.play());
    }
    if (mounted) setState(() => _showHud = true);
  }

  void _channel(int delta) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastZapAt != null && now.difference(_lastZapAt!) < _zapCooldown) {
      return;
    }
    _lastZapAt = now;
    unawaited(widget.session.playAdjacent(delta));
    setState(() => _showHud = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ch = widget.session.nowPlaying;
    final player = widget.session.player;
    final state = player.state;
    final err = player.lastError;
    final inCat = widget.session.channelsInCategory;
    final canZap = inCat.length > 1;

    return SdtvInputScope(
      onBack: _exit,
      onMenu: _exit,
      onConfirm: _togglePlay,
      onDirection: (dir) {
        if (dir == TraversalDirection.up) {
          _channel(-1);
        } else if (dir == TraversalDirection.down) {
          _channel(1);
        } else if (mounted) {
          setState(() => _showHud = true);
        }
      },
      onPageUp: () => _channel(-1),
      onPageDown: () => _channel(1),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _stableVideo ?? const ColoredBox(color: Colors.black),

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
                        canZap
                            ? 'Demo · same test stream · name zaps only'
                            : 'Demo stream · only channel in this category',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                      ),
                    Text(
                      canZap
                          ? 'A pause · D-pad/LB RB channel · B back'
                          : 'A pause · B back',
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
    );
  }
}
