import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// High-level player state.
enum SdtvPlayerState {
  idle,
  opening,
  playing,
  paused,
  buffering,
  error,
}

/// Playback API shared by stub (tests) and media_kit (app).
abstract class SdtvPlayerController extends Listenable {
  SdtvPlayerState get state;
  String? get currentUrl;
  String? get lastError;

  /// Decode path summary for HUD (never empty after first open attempt).
  String get decodeLabel => 'decode: —';

  /// Embed perf line (FPS + texture + decode). Empty for stub.
  String get perfLabel => '';

  /// Estimated output FPS (0 if unknown).
  double get estimatedFps => 0;

  /// Texture height cap used by the video controller (0 if N/A).
  int get textureHeight => 0;

  /// Playback position (VOD / when stream reports time).
  Duration get position => Duration.zero;

  /// Total duration when known; [Duration.zero] for live / unknown.
  Duration get duration => Duration.zero;

  /// True when a scrubber is meaningful (finite duration, not live).
  bool get canSeek {
    final d = duration;
    return d > const Duration(seconds: 5) &&
        d < const Duration(hours: 12);
  }

  /// Non-null when using media_kit (for [Video] widget).
  VideoController? get videoController => null;

  /// Open [url] for playback. Optional [httpHeaders] (User-Agent, etc.).
  Future<void> open(Uri url, {Map<String, String>? httpHeaders});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Seek to [position] when [canSeek]; no-op for live.
  Future<void> seek(Duration position) async {}

  /// Relative seek (e.g. ±10s) when [canSeek].
  Future<void> seekBy(Duration delta) async {
    if (!canSeek) return;
    final next = position + delta;
    final d = duration;
    final clamped = next < Duration.zero
        ? Duration.zero
        : (next > d ? d : next);
    await seek(clamped);
  }

  /// Re-read native player flags into [state] (sleep/resume, stuck spinner).
  void resyncState() {}

  @override
  Future<void> dispose();
}

/// No-op player for unit tests (no native libs).
class StubSdtvPlayerController extends ChangeNotifier
    implements SdtvPlayerController {
  SdtvPlayerState _state = SdtvPlayerState.idle;
  String? _url;
  String? _error;

  @override
  SdtvPlayerState get state => _state;

  @override
  String? get currentUrl => _url;

  @override
  String? get lastError => _error;

  @override
  String get decodeLabel => 'decode: stub';

  @override
  String get perfLabel => 'perf: stub';

  @override
  double get estimatedFps => 0;

  @override
  int get textureHeight => 0;

  @override
  VideoController? get videoController => null;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  bool get canSeek {
    final d = duration;
    return d > const Duration(seconds: 5) && d < const Duration(hours: 12);
  }

  @override
  Future<void> open(Uri url, {Map<String, String>? httpHeaders}) async {
    _url = url.toString();
    _error = null;
    _position = Duration.zero;
    // Demo-ish finite duration so scrubber can be exercised in tests.
    _duration = const Duration(minutes: 5);
    _state = SdtvPlayerState.opening;
    notifyListeners();
    _state = SdtvPlayerState.playing;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    if (_url == null) return;
    _state = SdtvPlayerState.playing;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    if (_state == SdtvPlayerState.playing ||
        _state == SdtvPlayerState.buffering) {
      _state = SdtvPlayerState.paused;
      notifyListeners();
    }
  }

  @override
  Future<void> stop() async {
    _state = SdtvPlayerState.idle;
    _url = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    if (!canSeek) return;
    _position = position < Duration.zero
        ? Duration.zero
        : (position > _duration ? _duration : position);
    notifyListeners();
  }

  @override
  Future<void> seekBy(Duration delta) async {
    if (!canSeek) return;
    final next = position + delta;
    final d = duration;
    final clamped = next < Duration.zero
        ? Duration.zero
        : (next > d ? d : next);
    await seek(clamped);
  }

  @override
  void resyncState() {}

  @override
  Future<void> dispose() async {
    await stop();
    super.dispose();
  }
}

/// Real libmpv-backed player via media_kit.
class MediaKitSdtvPlayerController extends ChangeNotifier
    implements SdtvPlayerController {
  MediaKitSdtvPlayerController() {
    _player = Player(
      configuration: const PlayerConfiguration(
        // Larger demuxer buffer helps janky HLS/M3U feeds on Wi‑Fi.
        bufferSize: 64 * 1024 * 1024,
        title: 'sdtv',
        // Quieter default; set MPV_VERBOSE=1 via env later if needed.
        logLevel: MPVLogLevel.warn,
      ),
    );
    // Embed/texture path is experimental. Forcing a small FBO and then
    // fighting media_kit's video-params resize dropped Deck to ~2fps.
    // Daily watch is external mpv (vo=gpu), not this texture.
    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        hwdec: 'vaapi-copy,auto-copy,auto',
      ),
    );

    unawaited(_applyLinuxPerfProps());

    _subs.add(_player.stream.playing.listen((_) {
      if (_disposed) return;
      _resyncFromNative();
    }));

    _subs.add(_player.stream.buffering.listen((_) {
      if (_disposed) return;
      _resyncFromNative();
    }));

    // Position ticks — keep _position hot but rarely notify (HUD thrash kills FPS).
    _subs.add(_player.stream.position.listen((pos) {
      if (_disposed) return;
      _position = pos;
      if (_state == SdtvPlayerState.buffering ||
          _state == SdtvPlayerState.opening) {
        if (_player.state.playing) {
          _setState(SdtvPlayerState.playing);
          return;
        }
      }
      // ~1 Hz while playing: scrubber does not need 4+ rebuilds/sec.
      final now = DateTime.now();
      if (_lastPosNotify == null ||
          now.difference(_lastPosNotify!) > const Duration(milliseconds: 900)) {
        _lastPosNotify = now;
        notifyListeners();
      }
    }));

    _subs.add(_player.stream.duration.listen((d) {
      if (_disposed) return;
      if (_duration == d) return;
      _duration = d;
      notifyListeners();
    }));

    _subs.add(_player.stream.error.listen((message) {
      if (_disposed) return;
      if (message.isEmpty) return;
      _error = message;
      _setState(SdtvPlayerState.error);
      debugPrint('sdtv_player error: $message');
    }));

    // Sample mpv FPS / decode path while a stream is open.
    _perfTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_samplePerf());
    });
  }

  late final Player _player;
  late final VideoController _videoController;
  final _subs = <StreamSubscription<dynamic>>[];

  SdtvPlayerState _state = SdtvPlayerState.idle;
  String? _url;
  String? _error;
  String _decodeLabel = 'decode: —';
  String _perfLabel = 'perf: —';
  double _estimatedFps = 0;
  final int _textureHeight = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime? _lastPosNotify;
  bool _disposed = false;
  Timer? _bufferStuckTimer;
  Timer? _perfTimer;

  /// libmpv properties that reduce rebuffer/stutter on weak live HLS.
  Future<void> _applyLinuxPerfProps() async {
    if (!Platform.isLinux) return;
    try {
      final platform = _player.platform;
      if (platform == null) return;
      // NativePlayer.setProperty — not on the public Player type.
      final dynamic native = platform;
      if (native.setProperty is! Function) return;

      // Texture VO path: drop frames freely, cheapest scale, keep audio locked.
      final props = <String, String>{
        'hwdec': 'vaapi-copy',
        'hwdec-codecs': 'all',
        'vo': 'libmpv',
        'gpu-hwdec-interop': 'auto',
        'profile': 'fast',
        'video-latency-hacks': 'yes',
        'cache': 'yes',
        'cache-pause': 'no',
        'cache-pause-initial': 'no',
        'demuxer-max-bytes': '83886080',
        'demuxer-max-back-bytes': '33554432',
        'demuxer-readahead-secs': '8',
        'cache-secs': '20',
        'interpolation': 'no',
        // Prefer audio clock; drop video rather than stutter audio.
        'video-sync': 'audio',
        'framedrop': 'decoder+vo',
        'opengl-pbo': 'yes',
        'opengl-swapinterval': '0',
        'vd-lavc-threads': '0',
        'audio-buffer': '0.05',
        // Cheapest scaling into the small texture.
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'dscale': 'bilinear',
        'correct-downscaling': 'no',
        'linear-downscaling': 'no',
        'sigmoid-upscaling': 'no',
        'deband': 'no',
        'dither': 'no',
      };
      for (final e in props.entries) {
        try {
          await native.setProperty(e.key, e.value) as Future?;
        } catch (err) {
          debugPrint('sdtv_player setProperty ${e.key}: $err');
        }
      }
      try {
        await native.setProperty(
          'hwdec',
          'vaapi-copy,auto-copy,auto-safe,auto',
        ) as Future?;
      } catch (_) {}
      debugPrint('sdtv_player: texture perf props (no size cap)');
    } catch (e) {
      debugPrint('sdtv_player tune: $e');
    }
  }

  Future<void> _samplePerf() async {
    if (_disposed || _url == null) return;
    if (_state != SdtvPlayerState.playing &&
        _state != SdtvPlayerState.buffering) {
      return;
    }
    try {
      final dynamic native = _player.platform;
      if (native == null || native.getProperty is! Function) return;

      Future<String> prop(String name) async {
        try {
          final v = await native.getProperty(name);
          if (v == null || v == false) return '';
          return '$v'.trim();
        } catch (_) {
          return '';
        }
      }

      // Prefer measured filter FPS; fall back to container.
      var fpsStr = await prop('estimated-vf-fps');
      if (fpsStr.isEmpty || fpsStr == '0' || fpsStr == '0.000') {
        fpsStr = await prop('container-fps');
      }
      final fps = double.tryParse(fpsStr) ?? 0;
      if (fps > 0) _estimatedFps = fps;

      final hw = await prop('hwdec-current');
      final w = await prop('width');
      final h = await prop('height');
      final src = w.isNotEmpty && h.isNotEmpty ? '${w}x$h' : '?';
      final fpsShow = _estimatedFps > 0 ? _estimatedFps.toStringAsFixed(0) : '—';
      final hwShow = (hw.isEmpty || hw == 'no')
          ? (hw == 'no' ? 'cpu' : '?')
          : hw;
      final next = 'perf: mpv ${fpsShow}fps · $hwShow · src $src';
      if (next != _perfLabel) {
        _perfLabel = next;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('sdtv_player perf sample: $e');
    }
  }

  Future<void> _refreshDecodeLabel() async {
    var hw = '';
    var codec = '';
    var hwdecReq = '';
    try {
      final dynamic native = _player.platform;
      if (native != null && native.getProperty is Function) {
        Future<String> prop(String name) async {
          try {
            return ((await native.getProperty(name)) as String? ?? '').trim();
          } catch (_) {
            return '';
          }
        }

        hw = await prop('hwdec-current');
        hwdecReq = await prop('hwdec');
        codec = await prop('video-codec');
        if (codec.isEmpty) codec = await prop('video-format');
        if (codec.isEmpty) codec = await prop('current-vo');
      }
    } catch (e) {
      debugPrint('sdtv_player decode query: $e');
    }

    if (codec.isEmpty) {
      try {
        final vp = _player.state.videoParams;
        final pix = vp.pixelformat;
        if (pix != null && pix.isNotEmpty) codec = pix;
      } catch (_) {}
    }

    final src = Platform.environment['SDTV_MPV_SOURCE'] ?? '?';
    // Empty hwdec-current with hwdec request still set often means copy-path
    // hasn't reported yet — don't always call that "cpu/software".
    String hwPart;
    if (hw.isNotEmpty && hw != 'no') {
      hwPart = hw;
    } else if (hw == 'no') {
      hwPart = 'cpu/software';
    } else if (hwdecReq.contains('vaapi')) {
      hwPart = 'vaapi?'; // requested; may still be probing
    } else {
      hwPart = 'cpu/software';
    }
    final codecPart = codec.isEmpty ? '' : ' · $codec';
    _decodeLabel = 'decode: $hwPart$codecPart · mpv=$src';
    debugPrint('sdtv_player $_decodeLabel (hwdec=$hwdecReq current=$hw)');
    unawaited(_samplePerf());
    if (!_disposed) notifyListeners();
  }

  void _resyncFromNative() {
    if (_disposed) return;
    if (_url == null) {
      _bufferStuckTimer?.cancel();
      _setState(SdtvPlayerState.idle);
      return;
    }

    final s = _player.state;
    if (s.playing) {
      _error = null;
      _bufferStuckTimer?.cancel();
      _setState(SdtvPlayerState.playing);
      return;
    }

    if (s.buffering) {
      _setState(SdtvPlayerState.buffering);
      _armBufferStuckWatch();
      return;
    }

    _bufferStuckTimer?.cancel();
    _setState(SdtvPlayerState.paused);
  }

  void _armBufferStuckWatch() {
    _bufferStuckTimer?.cancel();
    _bufferStuckTimer = Timer(const Duration(seconds: 4), () {
      if (_disposed) return;
      if (_state != SdtvPlayerState.buffering) return;
      if (_player.state.playing) {
        _setState(SdtvPlayerState.playing);
        return;
      }
      _resyncFromNative();
    });
  }

  void _setState(SdtvPlayerState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  @override
  SdtvPlayerState get state => _state;

  @override
  String? get currentUrl => _url;

  @override
  String? get lastError => _error;

  @override
  String get decodeLabel => _decodeLabel;

  @override
  String get perfLabel => _perfLabel;

  @override
  double get estimatedFps => _estimatedFps;

  @override
  int get textureHeight => _textureHeight;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  bool get canSeek {
    final d = duration;
    return d > const Duration(seconds: 5) && d < const Duration(hours: 12);
  }

  @override
  VideoController get videoController => _videoController;

  Player get rawPlayer => _player;

  @override
  void resyncState() => _resyncFromNative();

  @override
  Future<void> open(Uri url, {Map<String, String>? httpHeaders}) async {
    if (_disposed) return;
    _url = url.toString();
    _error = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferStuckTimer?.cancel();
    _setState(SdtvPlayerState.opening);
    try {
      // Stop previous item so a failed .ts does not leave a dead demuxer.
      try {
        await _player.stop().timeout(const Duration(milliseconds: 600));
      } catch (_) {}

      final headers = httpHeaders ?? const <String, String>{};
      final media = headers.isEmpty
          ? Media(url.toString())
          : Media(url.toString(), httpHeaders: headers);
      debugPrint(
        'sdtv_player: open $url'
        '${headers.isEmpty ? '' : ' (headers=${headers.keys.join(",")})'}',
      );
      await _player.open(media, play: true);

      // Wait briefly for playing or error (live open is async).
      for (var i = 0; i < 20; i++) {
        if (_disposed) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_state == SdtvPlayerState.error) return;
        if (_player.state.playing) {
          _error = null;
          _setState(SdtvPlayerState.playing);
          break;
        }
        if (_player.state.buffering) {
          _setState(SdtvPlayerState.buffering);
        }
      }

      unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (!_disposed) unawaited(_refreshDecodeLabel());
      }));
      await _refreshDecodeLabel();
      if (_state != SdtvPlayerState.error) {
        _resyncFromNative();
      }
    } catch (e, st) {
      _error = e.toString();
      _setState(SdtvPlayerState.error);
      debugPrint('sdtv_player open failed: $e\n$st');
    }
  }

  /// Soften decode path after a hard fail (chrome spike / Deck texture).
  Future<void> preferSoftwareDecode() async {
    if (_disposed) return;
    try {
      final dynamic native = _player.platform;
      if (native != null && native.setProperty is Function) {
        await native.setProperty('hwdec', 'no') as Future?;
        debugPrint('sdtv_player: hwdec=no (software fallback)');
      }
    } catch (e) {
      debugPrint('sdtv_player preferSoftwareDecode: $e');
    }
  }

  @override
  Future<void> play() async {
    if (_disposed || _url == null) return;
    _setState(SdtvPlayerState.playing);
    try {
      await _player.play().timeout(const Duration(milliseconds: 800));
    } catch (e) {
      debugPrint('sdtv_player play: $e');
    }
    _resyncFromNative();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    _setState(SdtvPlayerState.paused);
    try {
      await _player.pause().timeout(const Duration(milliseconds: 800));
    } catch (e) {
      debugPrint('sdtv_player pause: $e');
    }
    _resyncFromNative();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _bufferStuckTimer?.cancel();
    try {
      await _player.stop().timeout(const Duration(milliseconds: 900));
    } catch (e) {
      debugPrint('sdtv_player stop: $e');
    }
    _url = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _setState(SdtvPlayerState.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed || !canSeek) return;
    try {
      await _player.seek(position).timeout(const Duration(milliseconds: 900));
      _position = position;
      notifyListeners();
    } catch (e) {
      debugPrint('sdtv_player seek: $e');
    }
  }

  @override
  Future<void> seekBy(Duration delta) async {
    if (_disposed || !canSeek) return;
    final next = position + delta;
    final d = duration;
    final clamped = next < Duration.zero
        ? Duration.zero
        : (next > d ? d : next);
    await seek(clamped);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _bufferStuckTimer?.cancel();
    _perfTimer?.cancel();
    _perfTimer = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _player.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    super.dispose();
  }
}
