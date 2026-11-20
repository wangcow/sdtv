import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../../state/session_controller.dart';
import 'player_chrome.dart';

/// Bitmap target for [MpvFlutterHud]. Tests pass a fake; the app uses mpv.
abstract class MpvBitmapOverlay {
  /// Text playback banners should stay off while this HUD is in the tree.
  void activate();

  void deactivate();

  void markBroken();

  bool get broken;

  Future<({int w, int h})?> readOsdSize();

  /// Straight RGBA8, length >= width * height * 4.
  Future<bool> pushRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int? displayWidth,
    int? displayHeight,
  });

  Future<void> clear();

  Future<Duration> position();

  Future<Duration> length();

  Future<bool> paused();
}

/// Talks to the running external mpv process.
class LauncherBitmapOverlay implements MpvBitmapOverlay {
  LauncherBitmapOverlay(this.mpv);

  final ExternalMpvLauncher mpv;

  @override
  void activate() {
    mpv.bitmapOverlayBroken = false;
    mpv.playbackBitmapHud = true;
  }

  @override
  void deactivate() {
    mpv.playbackBitmapHud = false;
  }

  @override
  void markBroken() {
    mpv.bitmapOverlayBroken = true;
    mpv.playbackBitmapHud = false;
  }

  @override
  bool get broken => mpv.bitmapOverlayBroken;

  @override
  Future<({int w, int h})?> readOsdSize() => mpv.osdPixelSize();

  @override
  Future<bool> pushRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int? displayWidth,
    int? displayHeight,
  }) {
    final bgra = rgbaStraightToBgraPremul(rgba);
    return mpv.showBitmapOverlay(
      bgra,
      width: width,
      height: height,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
    );
  }

  @override
  Future<void> clear() => mpv.hideBitmapOverlay();

  @override
  Future<Duration> position() => mpv.timePos();

  @override
  Future<Duration> length() => mpv.duration();

  @override
  Future<bool> paused() => mpv.isPaused();
}

/// Rasterizes [PlayerChrome] and composites it on external mpv.
///
/// The picture stays `vo=gpu`. Focus stays in Flutter. The bitmap updates on
/// input, and a few times a second while the VOD scrubber is on screen.
/// Auto-hides after a few seconds so a volume readout can use mpv text OSD.
class MpvFlutterHud extends StatefulWidget {
  const MpvFlutterHud({
    super.key,
    required this.session,
    this.overlay,
    this.capturePixelRatio,
  });

  final SessionController session;

  /// Null uses [session.externalMpv].
  final MpvBitmapOverlay? overlay;

  /// Overrides the capture scale. Production picks a ratio that keeps the
  /// longest side at or under 1920.
  final double? capturePixelRatio;

  @override
  State<MpvFlutterHud> createState() => MpvFlutterHudState();
}

class MpvFlutterHudState extends State<MpvFlutterHud> {
  final GlobalKey _boundaryKey = GlobalKey();

  late final MpvBitmapOverlay _overlay =
      widget.overlay ?? LauncherBitmapOverlay(widget.session.externalMpv);

  bool _showHud = true;
  bool _paused = false;
  bool _menuWasOpen = false;
  bool _gaveUp = false;
  bool _captureQueued = false;
  bool _captureInFlight = false;
  bool _captureDirty = false;
  DateTime? _firstFail;
  ({int w, int h})? _osd;
  DateTime? _osdAt;

  PlayerChromeFocus _focus = PlayerChromeFocus.playPause;
  PlayerChromeFocus _lastRowFocus = PlayerChromeFocus.playPause;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Timer? _hideHudTimer;
  Timer? _tick;

  static const _hudHideAfter = Duration(seconds: 4);
  static const _tickEvery = Duration(milliseconds: 300);

  bool get _vod => widget.session.watchingVod;

  bool get _canSeek {
    if (!_vod) return false;
    return _duration > const Duration(seconds: 5) &&
        _duration < const Duration(hours: 12);
  }

  List<PlayerChromeFocus> get _rowFocusOrder {
    final seek = _canSeek;
    return [
      if (seek) PlayerChromeFocus.seekBack,
      PlayerChromeFocus.playPause,
      if (seek) PlayerChromeFocus.seekFwd,
      PlayerChromeFocus.back,
    ];
  }

  @override
  void initState() {
    super.initState();
    _overlay.activate();
    widget.session.addListener(_onSession);
    _bumpHud();
  }

  @override
  void dispose() {
    _hideHudTimer?.cancel();
    _tick?.cancel();
    widget.session.removeListener(_onSession);
    _overlay.deactivate();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    final menu = widget.session.isWatchMenuActive || widget.session.watchStallOpen;
    if (menu) {
      if (!_menuWasOpen) {
        _menuWasOpen = true;
        _showHud = false;
        _syncTick();
        unawaited(_overlay.clear());
      }
      return;
    }
    if (_menuWasOpen) {
      _menuWasOpen = false;
      unawaited(_syncPause());
      _bumpHud();
      return;
    }
    if (_showHud) {
      setState(() {});
      _scheduleCapture();
    }
  }

  void _bumpHud() {
    _hideHudTimer?.cancel();
    if (!_showHud) {
      _showHud = true;
      if (mounted) setState(() {});
    }
    if (!_paused) {
      _hideHudTimer = Timer(_hudHideAfter, () {
        if (!mounted || _paused) return;
        setState(() => _showHud = false);
        _syncTick();
        unawaited(_overlay.clear());
      });
    }
    _syncTick();
    _scheduleCapture();
  }

  void _syncTick() {
    final want = _showHud && !_gaveUp && !widget.session.isWatchMenuActive;
    if (!want) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(_tickEvery, (_) {
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    if (!mounted || !_showHud || _gaveUp) return;
    final paused = await _overlay.paused();
    Duration? pos;
    Duration? dur;
    if (_vod) {
      pos = await _overlay.position();
      dur = await _overlay.length();
    }
    if (!mounted || !_showHud) return;
    final posChanged =
        pos != null && (pos - _position).inMilliseconds.abs() > 250;
    final durChanged = dur != null && dur != _duration;
    final pauseChanged = paused != _paused;
    if (!posChanged && !durChanged && !pauseChanged) return;
    setState(() {
      _paused = paused;
      if (paused) _hideHudTimer?.cancel();
      if (pos != null) _position = pos;
      if (dur != null) _duration = dur;
    });
    _scheduleCapture();
  }

  Future<void> _syncPause() async {
    final paused = await _overlay.paused();
    if (!mounted) return;
    if (paused == _paused) return;
    setState(() => _paused = paused);
  }

  void horizontal(int delta) {
    if (widget.session.isWatchMenuActive) return;
    if (!_showHud) {
      _bumpHud();
      return;
    }
    _moveFocus(delta);
  }

  void vertical(int delta) {
    if (widget.session.isWatchMenuActive) return;
    if (!_showHud) {
      unawaited(widget.session.watchVolumeDelta(delta < 0 ? 5 : -5));
      return;
    }
    if (_vod) {
      if (delta < 0) {
        if (_focus == PlayerChromeFocus.scrubber) {
          unawaited(_nudgeScrub(-1));
        } else {
          _focusScrubber();
        }
      } else if (_focus == PlayerChromeFocus.scrubber) {
        _leaveScrubber();
      } else {
        _bumpHud();
      }
      return;
    }
    unawaited(widget.session.watchChannelAdjacent(delta));
    _bumpHud();
  }

  /// LB/RB: live zap, or ±10s on a title. Always reveals the HUD.
  void shoulder(int delta) {
    _bumpHud();
    if (_vod) {
      unawaited(
        widget.session.seekVodBy(Duration(seconds: delta > 0 ? 10 : -10)),
      );
      unawaited(_refreshPosition());
    } else {
      unawaited(widget.session.watchChannelAdjacent(delta));
    }
  }

  void confirm() {
    if (widget.session.isWatchMenuActive) return;
    if (!_showHud) {
      _bumpHud();
      return;
    }
    switch (_focus) {
      case PlayerChromeFocus.playPause:
        unawaited(_toggle());
      case PlayerChromeFocus.seekBack:
        unawaited(widget.session.seekVodBy(const Duration(seconds: -10)));
        unawaited(_refreshPosition());
        _bumpHud();
      case PlayerChromeFocus.seekFwd:
        unawaited(widget.session.seekVodBy(const Duration(seconds: 10)));
        unawaited(_refreshPosition());
        _bumpHud();
      case PlayerChromeFocus.scrubber:
        _bumpHud();
      case PlayerChromeFocus.back:
        unawaited(widget.session.watchQuit());
    }
  }

  /// B while the HUD is up moves to Back. A second B (or B while hidden)
  /// returns false so the page can leave playback.
  bool handleBack() {
    if (!_showHud) return false;
    if (_focus == PlayerChromeFocus.back) return false;
    setState(() => _focus = PlayerChromeFocus.back);
    _bumpHud();
    return true;
  }

  void _moveFocus(int delta) {
    if (_focus == PlayerChromeFocus.scrubber) {
      unawaited(_nudgeScrub(delta));
      return;
    }
    final order = _rowFocusOrder;
    if (order.isEmpty) return;
    var i = order.indexOf(_focus);
    if (i < 0) i = order.indexOf(PlayerChromeFocus.playPause);
    if (i < 0) i = 0;
    i = (i + delta) % order.length;
    if (i < 0) i += order.length;
    setState(() => _focus = order[i]);
    _bumpHud();
  }

  void _focusScrubber() {
    if (!_canSeek) {
      _bumpHud();
      return;
    }
    if (_focus != PlayerChromeFocus.scrubber) _lastRowFocus = _focus;
    setState(() => _focus = PlayerChromeFocus.scrubber);
    _bumpHud();
  }

  void _leaveScrubber() {
    final order = _rowFocusOrder;
    var back = _lastRowFocus;
    if (!order.contains(back)) back = PlayerChromeFocus.playPause;
    setState(() => _focus = back);
    _bumpHud();
  }

  Future<void> _nudgeScrub(int dir) async {
    if (!_canSeek) return;
    final step = Duration(milliseconds: (_duration.inMilliseconds * 0.05).round());
    if (step <= Duration.zero) return;
    await widget.session.seekVodBy(dir < 0 ? -step : step);
    await _refreshPosition();
    _bumpHud();
  }

  Future<void> _refreshPosition() async {
    final pos = await _overlay.position();
    final dur = await _overlay.length();
    if (!mounted) return;
    setState(() {
      _position = pos;
      if (dur > Duration.zero) _duration = dur;
    });
    _scheduleCapture();
  }

  Future<void> _toggle() async {
    final nextPaused = !_paused;
    setState(() => _paused = nextPaused);
    _bumpHud();
    if (!_vod) {
      if (nextPaused) {
        await widget.session.externalMpv.setPaused(true);
      } else {
        await widget.session.externalMpv.resumeLiveEdge(title: _title);
      }
      return;
    }
    await widget.session.externalMpv.setPaused(nextPaused);
  }

  void _scheduleCapture() {
    if (!mounted || !_showHud || _gaveUp) return;
    if (_captureQueued) {
      _captureDirty = true;
      return;
    }
    _captureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureQueued = false;
      if (mounted) unawaited(_captureNow());
    });
  }

  Future<void> _captureNow() async {
    if (_captureInFlight) {
      _captureDirty = true;
      return;
    }
    if (!mounted || !_showHud || _gaveUp || widget.session.isWatchMenuActive) {
      return;
    }
    final boundary =
        _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize || boundary.size.isEmpty) {
      return;
    }
    _captureInFlight = true;
    var retry = false;
    var giveUp = false;
    try {
      if (boundary.debugNeedsPaint) {
        retry = true;
      } else {
        final ratio = _ratioFor(boundary.size);
        final image = await boundary.toImage(pixelRatio: ratio);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final w = image.width;
        final h = image.height;
        image.dispose();
        if (!mounted || !_showHud || widget.session.isWatchMenuActive) return;
        final rgba = bytes?.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
        if (rgba == null || w < 1 || h < 1 || rgba.length < w * h * 4) {
          retry = true;
        } else {
          final osd = await _osdSize();
          final ok = await _overlay.pushRgba(
            rgba,
            width: w,
            height: h,
            displayWidth: osd?.w,
            displayHeight: osd?.h,
          );
          if (!mounted) return;
          if (ok) {
            _firstFail = null;
          } else {
            _firstFail ??= DateTime.now();
            if (DateTime.now().difference(_firstFail!) >
                const Duration(seconds: 8)) {
              giveUp = true;
            } else {
              retry = true;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('sdtv: hud capture: $e');
      retry = true;
    } finally {
      _captureInFlight = false;
    }
    if (giveUp) {
      _giveUp();
      return;
    }
    if (retry) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (mounted && _showHud) _scheduleCapture();
      return;
    }
    if (_captureDirty && mounted) {
      _captureDirty = false;
      _scheduleCapture();
    }
  }

  void _giveUp() {
    if (_gaveUp) return;
    _gaveUp = true;
    _tick?.cancel();
    _tick = null;
    _overlay.markBroken();
    debugPrint('sdtv: bitmap HUD unavailable, using text OSD');
    final ch = widget.session.nowPlaying;
    if (ch != null) {
      unawaited(
        widget.session.showMiniGuide(channel: ch, channelLineFirst: true),
      );
    }
  }

  Future<({int w, int h})?> _osdSize() async {
    final now = DateTime.now();
    if (_osd != null &&
        _osdAt != null &&
        now.difference(_osdAt!) < const Duration(seconds: 2)) {
      return _osd;
    }
    _osd = await _overlay.readOsdSize();
    _osdAt = now;
    return _osd;
  }

  double _ratioFor(Size logical) {
    final forced = widget.capturePixelRatio;
    if (forced != null && forced > 0) return forced;
    final dpr = View.of(context).devicePixelRatio;
    final longest = logical.longestSide * dpr;
    if (longest <= 1920 || longest <= 0) return dpr;
    return dpr * (1920 / longest);
  }

  String get _title {
    final show = widget.session.nowPlayingSeries;
    final ep = widget.session.nowPlayingEpisode;
    if (show != null && ep != null) {
      final code = 'S${ep.season}E${ep.episodeNum}';
      final name = ep.title.trim();
      return name.isEmpty ? '${show.name}  $code' : '${show.name}  $code  $name';
    }
    final vod = widget.session.nowPlayingVod;
    if (vod != null) return vod.name;
    final ch = widget.session.nowPlaying;
    if (ch != null) {
      return ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;
    }
    final active = widget.session.externalMpv.activeTitle;
    if (active != null && active.trim().isNotEmpty && active != 'sdtv') {
      return active.trim();
    }
    return _vod ? 'On-demand' : 'Live';
  }

  String get _subtitle => _vod
      ? 'On-demand'
      : 'Live · LB/RB channel · ←→ chrome';

  SdtvPlayerState get _playerState =>
      _paused ? SdtvPlayerState.paused : SdtvPlayerState.playing;

  @override
  Widget build(BuildContext context) {
    if (widget.session.isWatchMenuActive || widget.session.watchStallOpen) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      key: _boundaryKey,
      child: PlayerChrome(
        title: _title,
        subtitle: _subtitle,
        playerState: _playerState,
        position: _position,
        duration: _duration,
        canSeek: _canSeek,
        liveMode: !_vod,
        focus: _focus,
        showChrome: _showHud,
        perfLabel: 'mpv · vo=gpu',
        onPlayPause: () {
          unawaited(_toggle());
        },
        onSeekBack: () {
          unawaited(widget.session.seekVodBy(const Duration(seconds: -10)));
          unawaited(_refreshPosition());
          _bumpHud();
        },
        onSeekFwd: () {
          unawaited(widget.session.seekVodBy(const Duration(seconds: 10)));
          unawaited(_refreshPosition());
          _bumpHud();
        },
        onBack: () {
          unawaited(widget.session.watchQuit());
        },
        onScrub: _canSeek
            ? (v) {
                final ms = (_duration.inMilliseconds * v).round();
                unawaited(
                  widget.session.externalMpv.seekTo(Duration(milliseconds: ms)),
                );
                setState(() => _position = Duration(milliseconds: ms));
                _bumpHud();
              }
            : null,
      ),
    );
  }
}
