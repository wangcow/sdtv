import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _exiting = false;
  DateTime? _lastZapAt;
  SdtvPlayerState? _lastState;
  final FocusNode _rootFocus = FocusNode(debugLabel: 'player-root');

  /// One channel step per physical gesture — stick noise must not 1↔2 spam.
  static const _zapCooldown = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    widget.session.player.addListener(_onTick);
    widget.session.addListener(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimFocus());
  }

  void _claimFocus() {
    if (!mounted || _exiting) return;
    _rootFocus.requestFocus();
  }

  void _onTick() {
    if (!mounted || _exiting) return;
    final st = widget.session.player.state;
    // When bipbop actually starts, the video surface can steal focus / lag
    // the tree — re-claim input once on the buffering→playing transition.
    if (_lastState != SdtvPlayerState.playing &&
        st == SdtvPlayerState.playing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimFocus());
    }
    _lastState = st;
    setState(() {});
  }

  @override
  void dispose() {
    widget.session.player.removeListener(_onTick);
    widget.session.removeListener(_onTick);
    _rootFocus.dispose();
    super.dispose();
  }

  void _exit() {
    if (_exiting || !mounted) return;
    _exiting = true;
    // Pop immediately — do not await mpv stop here (browse stops after pop).
    Navigator.of(context).pop();
  }

  Future<void> _togglePlay() async {
    if (_exiting) return;
    final player = widget.session.player;
    final state = player.state;
    final url = player.currentUrl ?? '';
    try {
      if (state == SdtvPlayerState.playing ||
          state == SdtvPlayerState.buffering) {
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
    } catch (e, st) {
      debugPrint('sdtv player toggle: $e\n$st');
    }
    if (mounted && !_exiting) {
      setState(() => _showHud = true);
      _claimFocus();
    }
  }

  void _channel(int delta) {
    if (_exiting) return;
    final now = DateTime.now();
    if (_lastZapAt != null && now.difference(_lastZapAt!) < _zapCooldown) {
      return;
    }
    _lastZapAt = now;
    // Fire-and-forget; demo zap is sync name change.
    unawaited(widget.session.playAdjacent(delta));
    if (mounted) setState(() => _showHud = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ch = widget.session.nowPlaying;
    final player = widget.session.player;
    final state = player.state;
    final vc = player.videoController;
    final err = player.lastError;
    final inCat = widget.session.channelsInCategory;
    final canZap = inCat.length > 1;

    return SdtvInputScope(
      onBack: _exit,
      onMenu: _exit,
      onConfirm: () {
        unawaited(_togglePlay());
      },
      // Direct pad path (same reliability as B). Actions break once video plays.
      onDirection: (dir) {
        if (dir == TraversalDirection.up) {
          _channel(-1);
        } else if (dir == TraversalDirection.down) {
          _channel(1);
        } else {
          if (mounted) setState(() => _showHud = true);
        }
      },
      onPageUp: () => _channel(-1),
      onPageDown: () => _channel(1),
      extraActions: {
        SdtvChannelUpIntent: CallbackAction<SdtvChannelUpIntent>(
          onInvoke: (_) {
            _channel(1);
            return null;
          },
        ),
        SdtvChannelDownIntent: CallbackAction<SdtvChannelDownIntent>(
          onInvoke: (_) {
            _channel(-1);
            return null;
          },
        ),
        SdtvPageUpIntent: CallbackAction<SdtvPageUpIntent>(
          onInvoke: (_) {
            _channel(-1);
            return null;
          },
        ),
        SdtvPageDownIntent: CallbackAction<SdtvPageDownIntent>(
          onInvoke: (_) {
            _channel(1);
            return null;
          },
        ),
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            if (intent.direction == TraversalDirection.up) {
              _channel(-1);
            } else if (intent.direction == TraversalDirection.down) {
              _channel(1);
            } else if (mounted) {
              setState(() => _showHud = true);
            }
            return null;
          },
        ),
      },
      extraShortcuts: {
        const SingleActivator(LogicalKeyboardKey.channelUp):
            const SdtvChannelUpIntent(),
        const SingleActivator(LogicalKeyboardKey.channelDown):
            const SdtvChannelDownIntent(),
        const SingleActivator(LogicalKeyboardKey.escape):
            const SdtvBackIntent(),
        const SingleActivator(LogicalKeyboardKey.gameButtonB):
            const SdtvBackIntent(),
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        canRequestFocus: true,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          // Keyboard / Steam-injected keys once the video surface is active.
          if (event is KeyDownEvent) {
            final k = event.logicalKey;
            if (k == LogicalKeyboardKey.escape ||
                k == LogicalKeyboardKey.gameButtonB ||
                k == LogicalKeyboardKey.goBack) {
              _exit();
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowUp ||
                k == LogicalKeyboardKey.channelDown ||
                k == LogicalKeyboardKey.pageUp ||
                k == LogicalKeyboardKey.gameButtonLeft1) {
              _channel(-1);
              return KeyEventResult.handled;
            }
            if (k == LogicalKeyboardKey.arrowDown ||
                k == LogicalKeyboardKey.channelUp ||
                k == LogicalKeyboardKey.pageDown ||
                k == LogicalKeyboardKey.gameButtonRight1) {
              _channel(1);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _claimFocus();
              setState(() => _showHud = !_showHud);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video must not take pointer or focus — that is when B dies
                // after bipbop starts (buffering was fine).
                if (vc != null)
                  ExcludeFocus(
                    child: IgnorePointer(
                      child: Video(
                        controller: vc,
                        controls: NoVideoControls,
                        fill: Colors.black,
                        // Wakelock/etc. fine; keep surface passive for input.
                      ),
                    ),
                  )
                else
                  const ColoredBox(color: Colors.black),

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
        ),
      ),
    );
  }
}
