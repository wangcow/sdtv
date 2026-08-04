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

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  bool _showHud = true;
  DateTime? _lastZapAt;

  /// Keep the same [Video] widget instance across HUD rebuilds so media_kit
  /// does not thrash the platform view on every setState (that was starving
  /// input once bipbop frames started).
  Widget? _stableVideo;

  /// Only show spinner after sustained buffering (avoid stuck/flash overlays).
  bool _showBufferChrome = false;
  Timer? _bufferChromeTimer;

  static const _zapCooldown = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _syncBufferChrome(widget.session.player.state);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Deck sleep / return: mpv flags may desync from our UI state.
    if (state == AppLifecycleState.resumed) {
      widget.session.player.resyncState();
      if (mounted) setState(() {});
    }
  }

  void _onTick() {
    if (!mounted) return;
    _syncBufferChrome(widget.session.player.state);
    setState(() {});
  }

  void _syncBufferChrome(SdtvPlayerState state) {
    final want = state == SdtvPlayerState.opening ||
        state == SdtvPlayerState.buffering;
    if (!want) {
      _bufferChromeTimer?.cancel();
      _bufferChromeTimer = null;
      _showBufferChrome = false;
      return;
    }
    if (_showBufferChrome) return;
    // Opening: show soon. Buffering mid-play: delay so brief rebuffers
    // (and stuck buffering flags with audio still rolling) don't paint forever.
    final delay = state == SdtvPlayerState.opening
        ? const Duration(milliseconds: 200)
        : const Duration(milliseconds: 900);
    _bufferChromeTimer?.cancel();
    _bufferChromeTimer = Timer(delay, () {
      if (!mounted) return;
      final s = widget.session.player.state;
      if (s == SdtvPlayerState.opening || s == SdtvPlayerState.buffering) {
        setState(() => _showBufferChrome = true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bufferChromeTimer?.cancel();
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

            if (_showBufferChrome)
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
                    if (widget.session.useDemo || widget.session.mockCatalog)
                      Text(
                        canZap
                            ? 'Demo stream · channel name zaps only'
                            : 'Demo stream · only channel in this category',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                      )
                    else if (widget.session.useM3u)
                      Text(
                        'M3U · ${ch?.name ?? "channel"}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text(
                        'Live · ${ch?.name ?? "channel"}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
