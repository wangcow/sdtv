import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../../services/artwork_cache.dart';
import '../../state/session_controller.dart';
import 'player_chrome.dart';
import 'watch_menu_card.dart';

/// Bitmap target for [MpvFlutterHud]. Tests pass a fake; the app uses mpv.
abstract class MpvBitmapOverlay {
  /// Text playback banners should stay off while this HUD is in the tree.
  void activate();

  void deactivate();

  void markBroken();

  bool get broken;

  Future<({int w, int h})?> readOsdSize();

  /// Shows one HUD band at ([x], [y]) in OSD pixels.
  ///
  /// [rgba] is premultiplied RGBA8 (Flutter `rawRgba`), length >=
  /// width * height * 4. The overlay may convert it in place.
  Future<bool> pushBand(
    Uint8List rgba, {
    required int id,
    required int x,
    required int y,
    required int width,
    required int height,
  });

  /// mpv-pushed property changes (`pause`, `duration`, `osd-width`, …).
  Stream<({String name, Object? value})> get propertyChanges;

  Future<void> clear();

  Future<Duration> position();

  Future<Duration> length();

  Future<bool> paused();

  /// Track labels and stream facts for the chrome (one round of IPC).
  Future<HudStreamInfo> streamInfo();

  Future<void> cycleSubtitles();

  Future<void> cycleAudio();
}

/// What the chrome shows about the current stream.
class HudStreamInfo {
  const HudStreamInfo({
    this.subtitles = 'Off',
    this.audio = 'Audio',
    this.height,
    this.hardwareDecode = false,
  });

  final String subtitles;
  final String audio;

  /// Video height in pixels (e.g. 1080), if known.
  final int? height;
  final bool hardwareDecode;

  /// e.g. `['1080p', 'HW']`
  List<String> get chips => [
    if (height != null && height! > 0) '${height}p',
    if (hardwareDecode) 'HW',
  ];
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
  Future<bool> pushBand(
    Uint8List rgba, {
    required int id,
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    return mpv.showBitmapOverlay(
      rgbaPremulToBgraInPlace(rgba),
      id: id,
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  @override
  Stream<({String name, Object? value})> get propertyChanges =>
      mpv.propertyChanges;

  @override
  Future<void> clear() => mpv.hideBitmapOverlay();

  @override
  Future<Duration> position() => mpv.timePos();

  @override
  Future<Duration> length() => mpv.duration();

  @override
  Future<bool> paused() => mpv.isPaused();

  @override
  Future<HudStreamInfo> streamInfo() async {
    final sub = await mpv.subtitleLabel();
    final aud = await mpv.audioLabel();
    final h = await mpv.getProperty('height');
    final hw = await mpv.getProperty('hwdec-current');
    return HudStreamInfo(
      subtitles: sub,
      audio: aud,
      height: h is num ? h.toInt() : null,
      hardwareDecode: hw is String && hw.isNotEmpty && hw != 'no',
    );
  }

  @override
  Future<void> cycleSubtitles() => mpv.cycleSubtitleTrack();

  @override
  Future<void> cycleAudio() => mpv.cycleAudioTrack();
}

/// Rasterizes [PlayerChrome] and composites it on external mpv.
///
/// The picture stays `vo=gpu`. Focus stays in Flutter. Only the top and bottom
/// bands are captured, at mpv's OSD pixel size, as two overlays. The bitmap
/// updates on input, on mpv-pushed state (pause, duration, OSD size), and once
/// a second while a VOD clock is on screen. Auto-hides after a few seconds so a
/// volume readout can use mpv text OSD.
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
  final GlobalKey _rootKey = GlobalKey();
  final GlobalKey _topBandKey = GlobalKey();
  final GlobalKey _bottomBandKey = GlobalKey();
  final GlobalKey _menuKey = GlobalKey();

  /// Bumped when the menu opens or closes, so a capture that started before
  /// the swap does not leave the old layer on the video.
  int _layerGen = 0;
  StreamSubscription<({String name, Object? value})>? _props;

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

  /// VOD clock refresh. Pause / duration / OSD size are pushed by mpv.
  static const _tickEvery = Duration(seconds: 1);

  bool get _vod => widget.session.watchingVod;

  bool get _canSeek {
    if (!_vod) return false;
    return _duration > const Duration(seconds: 5) &&
        _duration < const Duration(hours: 12);
  }

  /// Button row, left to right. Also the ←/→ focus order.
  List<PlayerChromeFocus> get _rowFocusOrder {
    if (!_vod) {
      return [
        PlayerChromeFocus.prevChannel,
        PlayerChromeFocus.playPause,
        PlayerChromeFocus.nextChannel,
        PlayerChromeFocus.subtitles,
        PlayerChromeFocus.audio,
        if (widget.session.nowPlaying != null) PlayerChromeFocus.favorite,
        PlayerChromeFocus.back,
      ];
    }
    final seek = _canSeek;
    return [
      if (seek) PlayerChromeFocus.seekBack,
      PlayerChromeFocus.playPause,
      if (seek) PlayerChromeFocus.seekFwd,
      PlayerChromeFocus.subtitles,
      PlayerChromeFocus.audio,
      PlayerChromeFocus.back,
    ];
  }

  HudStreamInfo _info = const HudStreamInfo();
  ChromeProgramme? _programme;
  ImageProvider? _logo;

  /// Channel the programme / info was fetched for (refetch after a zap).
  String? _infoKey;
  int _infoGen = 0;

  String get _nowKey {
    final s = widget.session;
    return s.nowPlaying?.favoriteKey ??
        s.nowPlayingEpisode?.progressKey ??
        s.nowPlayingVod?.favoriteKey ??
        '';
  }

  /// Track labels, resolution / HW chips, and the live programme.
  Future<void> _refreshInfo() async {
    final gen = ++_infoGen;
    _infoKey = _nowKey;
    final info = await _overlay.streamInfo();
    final ch = widget.session.nowPlaying;
    ChromeProgramme? programme;
    if (!_vod && ch != null) {
      final epg =
          widget.session.cachedShortEpg(ch) ??
          await widget.session.fetchShortEpg(ch);
      final when = DateTime.now();
      final now = epg?.nowAt(when);
      final next = epg?.nextAt(when);
      if (now != null) {
        programme = ChromeProgramme(
          title: now.title,
          timeRange: now.timeRangeLabel(),
          progress: now.progressAt(when),
          next: next == null
              ? null
              : 'Next  ${next.startTimeLabel()}  ${next.title}',
        );
      }
    }
    final logo = ch == null ? null : await _loadLogo(ch);
    if (!mounted || gen != _infoGen) return;
    setState(() {
      _info = info;
      _programme = programme;
      _logo = logo;
    });
    _scheduleCapture();
  }

  /// The channel logo from the artwork cache, decoded before it is shown.
  Future<ImageProvider?> _loadLogo(LiveChannel ch) async {
    if (ch.streamIcon.trim().isEmpty) return null;
    final file = await widget.session.artwork.getFile(
      scope: widget.session.prefsScope,
      kind: ArtworkCache.kindChannel,
      id: '${ch.streamId}',
      url: ch.streamIcon,
    );
    if (file == null || !mounted) return null;
    final provider = ResizeImage(FileImage(file), height: 128);
    var ok = true;
    await precacheImage(provider, context, onError: (_, _) => ok = false);
    return ok ? provider : null;
  }

  /// One press of a chrome button (A on the focused one, or a tap).
  void _activate(PlayerChromeFocus f) {
    switch (f) {
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
      case PlayerChromeFocus.prevChannel || PlayerChromeFocus.nextChannel:
        _bumpHud();
        unawaited(
          widget.session.watchChannelAdjacent(
            f == PlayerChromeFocus.nextChannel ? 1 : -1,
          ),
        );
      case PlayerChromeFocus.subtitles:
        _bumpHud();
        unawaited(_overlay.cycleSubtitles().then((_) => _refreshInfo()));
      case PlayerChromeFocus.audio:
        _bumpHud();
        unawaited(_overlay.cycleAudio().then((_) => _refreshInfo()));
      case PlayerChromeFocus.favorite:
        final ch = widget.session.nowPlaying;
        if (ch != null) {
          unawaited(
            widget.session.toggleFavorite(ch).then((_) {
              if (mounted) setState(() {});
              _scheduleCapture();
            }),
          );
        }
        _bumpHud();
      case PlayerChromeFocus.scrubber:
        _bumpHud();
      case PlayerChromeFocus.back:
        unawaited(widget.session.watchQuit());
    }
  }

  static String _clockLabel(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  void initState() {
    super.initState();
    _overlay.activate();
    widget.session.addListener(_onSession);
    _props = _overlay.propertyChanges.listen(_onProperty);
    unawaited(_syncPause());
    if (_vod) unawaited(_refreshPosition());
    unawaited(_refreshInfo());
    _bumpHud();
  }

  void _onProperty(({String name, Object? value}) change) {
    if (!mounted) return;
    switch (change.name) {
      case 'pause':
        final paused = change.value == true || change.value == 'yes';
        if (paused == _paused) return;
        setState(() => _paused = paused);
        // Pausing pins the HUD up; resuming restarts its hide timer.
        if (paused || _showHud) _bumpHud();
      case 'duration':
        final v = change.value;
        if (v is! num) return;
        final dur = Duration(milliseconds: (v * 1000).round());
        if (dur == _duration) return;
        setState(() => _duration = dur);
        _scheduleCapture();
      case 'osd-width' || 'osd-height':
        _osd = null;
        _scheduleCapture();
    }
  }

  @override
  void dispose() {
    _hideHudTimer?.cancel();
    _tick?.cancel();
    unawaited(_props?.cancel());
    widget.session.removeListener(_onSession);
    _overlay.deactivate();
    super.dispose();
  }

  bool get _menuActive =>
      widget.session.isWatchMenuActive || widget.session.watchStallOpen;

  /// A capture is wanted for the chrome bands or for the menu card.
  bool get _wantCapture => _showHud || widget.session.watchMenuModel != null;

  void _onSession() {
    if (!mounted) return;
    if (_menuActive) {
      if (!_menuWasOpen) {
        _menuWasOpen = true;
        _layerGen++;
        _hideHudTimer?.cancel();
        _showHud = false;
        _syncTick();
        unawaited(_overlay.clear());
      }
      // The menu card appears once the session has its model, and redraws on
      // every selection or value change.
      setState(() {});
      _scheduleCapture();
      return;
    }
    if (_menuWasOpen) {
      _menuWasOpen = false;
      _layerGen++;
      unawaited(_overlay.clear());
      unawaited(_syncPause());
      _bumpHud();
      return;
    }
    if (_nowKey != _infoKey) unawaited(_refreshInfo()); // zapped
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
      unawaited(_refreshInfo());
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
    final want =
        _vod && _showHud && !_gaveUp && !widget.session.isWatchMenuActive;
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
    if (!mounted || !_showHud || _gaveUp || !_vod) return;
    final pos = await _overlay.position();
    if (!mounted || !_showHud) return;
    // The clock shows whole seconds; skip captures that would look the same.
    if (pos.inSeconds == _position.inSeconds) return;
    setState(() => _position = pos);
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
    _activate(_focus);
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
    final step = Duration(
      milliseconds: (_duration.inMilliseconds * 0.05).round(),
    );
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

  /// Space / P on a keyboard: pause or resume, and show the HUD.
  void togglePause() {
    if (widget.session.isWatchMenuActive) return;
    unawaited(_toggle());
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
    if (!mounted || !_wantCapture || _gaveUp) return;
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
    if (!mounted || !_wantCapture || _gaveUp) return;
    final gen = _layerGen;
    final menu = widget.session.watchMenuModel != null;
    final root = _rootKey.currentContext?.findRenderObject() as RenderBox?;
    if (root == null || !root.hasSize || root.size.isEmpty) return;
    _captureInFlight = true;
    var retry = false;
    var giveUp = false;
    try {
      final logical = root.size;
      final osd = await _osdSize();
      // Capture straight at OSD pixels so mpv never rescales (no blur).
      final forced = widget.capturePixelRatio;
      final double sx;
      final double sy;
      if (forced != null && forced > 0) {
        sx = sy = forced;
      } else if (osd != null) {
        sx = osd.w / logical.width;
        sy = osd.h / logical.height;
      } else {
        sx = sy = _ratioFor(logical);
      }
      final targetH = osd?.h ?? (logical.height * sy).round();

      final bands = menu
          ? [(id: ExternalMpvLauncher.bitmapOverlayIdMenu, key: _menuKey)]
          : [
              (id: ExternalMpvLauncher.bitmapOverlayId, key: _topBandKey),
              (
                id: ExternalMpvLauncher.bitmapOverlayIdBottom,
                key: _bottomBandKey,
              ),
            ];
      for (final band in bands) {
        final boundary =
            band.key.currentContext?.findRenderObject()
                as RenderRepaintBoundary?;
        if (boundary == null || !boundary.hasSize || boundary.size.isEmpty) {
          continue;
        }
        final offset = boundary.localToGlobal(Offset.zero, ancestor: root);
        final image = await boundary.toImage(pixelRatio: sx);
        // rawRgba is premultiplied, which is what mpv's bgra wants.
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final w = image.width;
        final h = image.height;
        image.dispose();
        if (!mounted || !_wantCapture || gen != _layerGen) return;
        final rgba = bytes?.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
        if (rgba == null || w < 1 || h < 1 || rgba.length < w * h * 4) {
          retry = true;
          continue;
        }
        final bottomAnchored =
            offset.dy + boundary.size.height >= logical.height - 0.5;
        final y = bottomAnchored
            ? (targetH - h).clamp(0, targetH)
            : (offset.dy * sy).round();
        final ok = await _overlay.pushBand(
          rgba,
          id: band.id,
          x: (offset.dx * sx).round(),
          y: y,
          width: w,
          height: h,
        );
        if (!mounted) return;
        if (gen != _layerGen) {
          // Menu opened or closed while this was in flight: drop the stale
          // layer and draw the current one.
          await _overlay.clear();
          retry = true;
          break;
        }
        if (ok) {
          _firstFail = null;
        } else {
          _firstFail ??= DateTime.now();
          if (DateTime.now().difference(_firstFail!) >
              const Duration(seconds: 8)) {
            giveUp = true;
            break;
          }
          retry = true;
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
      if (mounted && _wantCapture) _scheduleCapture();
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
    // Normally served from mpv-pushed osd-width / osd-height.
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
      return name.isEmpty
          ? '${show.name}  $code'
          : '${show.name}  $code  $name';
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

  SdtvPlayerState get _playerState =>
      _paused ? SdtvPlayerState.paused : SdtvPlayerState.playing;

  @override
  Widget build(BuildContext context) {
    if (_menuActive) {
      final menu = widget.session.watchMenuModel;
      return SizedBox.expand(
        key: _rootKey,
        child: menu == null
            ? null
            : Center(
                child: RepaintBoundary(
                  key: _menuKey,
                  // Room for the card's shadow inside the captured bitmap.
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: WatchMenuCard(model: menu),
                  ),
                ),
              ),
      );
    }
    final ch = widget.session.nowPlaying;
    return SizedBox.expand(
      key: _rootKey,
      child: PlayerChrome(
        topBandKey: _topBandKey,
        bottomBandKey: _bottomBandKey,
        animate: false,
        title: _title,
        playerState: _playerState,
        position: _position,
        duration: _duration,
        canSeek: _canSeek,
        liveMode: !_vod,
        focus: _focus,
        showChrome: _showHud,
        buttons: _rowFocusOrder,
        favorite: ch != null && widget.session.isFavorite(ch),
        logo: _vod ? null : _logo,
        programme: _programme,
        subtitleLabel: _info.subtitles,
        audioLabel: _info.audio,
        infoChips: _info.chips,
        clock: _clockLabel(DateTime.now()),
        onAction: _activate,
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
