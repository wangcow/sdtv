import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sdtv_input/sdtv_input.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../state/session_controller.dart';
import 'widgets/player_chrome.dart';

/// Fullscreen **embedded** player: media_kit [Video] + [PlayerChrome] HUD.
///
/// This is the **player chrome spike** path (TiviMate-like controls on top of
/// video). Daily live TV still defaults to external mpv; open this via
/// ☰ → **Chrome spike (embedded)** or the Embedded snack action.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.session});

  final SessionController session;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  bool _showHud = true;
  DateTime? _lastZapAt;
  Timer? _hideHudTimer;

  PlayerChromeFocus _focus = PlayerChromeFocus.playPause;

  /// Keep the same [Video] widget instance across HUD rebuilds so media_kit
  /// does not thrash the platform view on every setState.
  Widget? _stableVideo;

  bool _showBufferChrome = false;
  Timer? _bufferChromeTimer;

  static const _zapCooldown = Duration(milliseconds: 280);
  static const _hudHideAfter = Duration(seconds: 4);

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
          child: RepaintBoundary(
            child: Video(
              controller: vc,
              controls: NoVideoControls,
              fill: Colors.black,
              filterQuality: FilterQuality.none,
            ),
          ),
        ),
      );
    }
    _syncBufferChrome(widget.session.player.state);
    _bumpHud();
  }

  bool get _liveMode {
    // Finite demo HLS can seek; treat provider live as live when !canSeek.
    final p = widget.session.player;
    if (p.canSeek) return false;
    return true;
  }

  List<PlayerChromeFocus> get _focusOrder {
    final live = _liveMode;
    final seek = widget.session.player.canSeek && !live;
    return [
      if (seek) PlayerChromeFocus.seekBack,
      PlayerChromeFocus.playPause,
      if (seek) PlayerChromeFocus.seekFwd,
      if (seek) PlayerChromeFocus.scrubber,
      PlayerChromeFocus.back,
    ];
  }

  void _bumpHud() {
    if (!_showHud && mounted) setState(() => _showHud = true);
    _hideHudTimer?.cancel();
    // Stay visible while paused.
    if (widget.session.player.state == SdtvPlayerState.paused) return;
    _hideHudTimer = Timer(_hudHideAfter, () {
      if (!mounted) return;
      if (widget.session.player.state == SdtvPlayerState.paused) return;
      setState(() => _showHud = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.session.player.resyncState();
      if (mounted) setState(() {});
    }
  }

  SdtvPlayerState? _lastPaintedState;
  String? _lastPaintedDecode;
  Duration? _lastPos;
  Duration? _lastDur;

  void _onTick() {
    if (!mounted) return;
    final p = widget.session.player;
    final st = p.state;
    _syncBufferChrome(st);
    if (st == SdtvPlayerState.paused) {
      if (!_showHud) setState(() => _showHud = true);
    }
    // Avoid full rebuilds when nothing HUD-visible changed.
    if (st == _lastPaintedState &&
        p.decodeLabel == _lastPaintedDecode &&
        p.position == _lastPos &&
        p.duration == _lastDur &&
        !_showBufferChrome) {
      return;
    }
    _lastPaintedState = st;
    _lastPaintedDecode = p.decodeLabel;
    _lastPos = p.position;
    _lastDur = p.duration;
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
    _hideHudTimer?.cancel();
    widget.session.player.removeListener(_onTick);
    widget.session.removeListener(_onTick);
    super.dispose();
  }

  void _exit() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  void _togglePlay() {
    final player = widget.session.player;
    final state = player.state;
    if (state == SdtvPlayerState.playing ||
        state == SdtvPlayerState.buffering ||
        state == SdtvPlayerState.opening) {
      unawaited(player.pause());
    } else {
      unawaited(player.play());
    }
    _bumpHud();
  }

  void _channel(int delta) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastZapAt != null && now.difference(_lastZapAt!) < _zapCooldown) {
      return;
    }
    _lastZapAt = now;
    unawaited(widget.session.playAdjacent(delta));
    _bumpHud();
  }

  void _moveFocus(int delta) {
    final order = _focusOrder;
    if (order.isEmpty) return;
    var i = order.indexOf(_focus);
    if (i < 0) i = order.indexOf(PlayerChromeFocus.playPause);
    if (i < 0) i = 0;
    i = (i + delta) % order.length;
    if (i < 0) i += order.length;
    setState(() => _focus = order[i]);
    _bumpHud();
  }

  void _activateFocus() {
    switch (_focus) {
      case PlayerChromeFocus.playPause:
        _togglePlay();
      case PlayerChromeFocus.seekBack:
        unawaited(
          widget.session.player.seekBy(const Duration(seconds: -10)),
        );
        _bumpHud();
      case PlayerChromeFocus.seekFwd:
        unawaited(
          widget.session.player.seekBy(const Duration(seconds: 10)),
        );
        _bumpHud();
      case PlayerChromeFocus.scrubber:
        // Up/down adjust scrub; A is no-op beyond showing HUD.
        _bumpHud();
      case PlayerChromeFocus.back:
        _exit();
    }
  }

  void _nudgeScrub(int dir) {
    if (!widget.session.player.canSeek) return;
    final d = widget.session.player.duration;
    if (d.inMilliseconds <= 0) return;
    // 5% steps with D-pad up/down on scrubber.
    final step = Duration(milliseconds: (d.inMilliseconds * 0.05).round());
    unawaited(
      widget.session.player.seekBy(dir < 0 ? -step : step),
    );
    _bumpHud();
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
    final live = _liveMode;

    final title = ch == null
        ? 'No channel'
        : (ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name);
    final subtitle = live
        ? (canZap
            ? 'Live · LB/RB or ↑↓ zap channel'
            : 'Live · single channel in list')
        : (player.canSeek ? 'On-demand · scrubber active' : 'Stream');

    return SdtvInputScope(
      onBack: () {
        if (!_showHud) {
          _bumpHud();
          return;
        }
        if (_focus == PlayerChromeFocus.back) {
          _exit();
        } else {
          setState(() => _focus = PlayerChromeFocus.back);
          _bumpHud();
        }
      },
      onMenu: _exit,
      onConfirm: () {
        if (!_showHud) {
          _bumpHud();
          return;
        }
        _activateFocus();
      },
      onDirection: (dir) {
        if (!_showHud) {
          _bumpHud();
          return;
        }
        if (dir == TraversalDirection.left) {
          _moveFocus(-1);
        } else if (dir == TraversalDirection.right) {
          _moveFocus(1);
        } else if (dir == TraversalDirection.up) {
          if (_focus == PlayerChromeFocus.scrubber) {
            _nudgeScrub(-1);
          } else if (live && canZap) {
            _channel(-1);
          } else {
            _bumpHud();
          }
        } else if (dir == TraversalDirection.down) {
          if (_focus == PlayerChromeFocus.scrubber) {
            _nudgeScrub(1);
          } else if (live && canZap) {
            _channel(1);
          } else {
            _bumpHud();
          }
        }
      },
      onPageUp: () => _channel(-1),
      onPageDown: () => _channel(1),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _bumpHud,
              child: _stableVideo ?? const ColoredBox(color: Colors.black),
            ),

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

            PlayerChrome(
              title: title,
              subtitle: subtitle,
              playerState: state,
              position: player.position,
              duration: player.duration,
              canSeek: player.canSeek,
              liveMode: live,
              focus: _focus,
              showChrome: _showHud && state != SdtvPlayerState.error,
              decodeLabel: player.decodeLabel,
              onPlayPause: _togglePlay,
              onSeekBack: () {
                unawaited(
                  player.seekBy(const Duration(seconds: -10)),
                );
                _bumpHud();
              },
              onSeekFwd: () {
                unawaited(
                  player.seekBy(const Duration(seconds: 10)),
                );
                _bumpHud();
              },
              onBack: _exit,
              onScrub: player.canSeek
                  ? (v) {
                      final d = player.duration;
                      unawaited(
                        player.seek(
                          Duration(
                            milliseconds:
                                (d.inMilliseconds * v).round(),
                          ),
                        ),
                      );
                      _bumpHud();
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
