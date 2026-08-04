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

  /// Non-null when using media_kit (for [Video] widget).
  VideoController? get videoController => null;

  Future<void> open(Uri url);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

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
  VideoController? get videoController => null;

  @override
  Future<void> open(Uri url) async {
    _url = url.toString();
    _error = null;
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
    notifyListeners();
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
    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        // Prefer VAAPI on Steam Deck; fall back to auto/software.
        // (Homebrew libmpv often has no VAAPI — run-sdtv.sh prefers system libmpv.)
        hwdec: 'vaapi,auto',
        // Cap texture size so software fallback is less brutal.
        height: 720,
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

    // Position ticks while audio/video advances — clears stuck "buffering" UI.
    _subs.add(_player.stream.position.listen((_) {
      if (_disposed) return;
      if (_state == SdtvPlayerState.buffering ||
          _state == SdtvPlayerState.opening) {
        if (_player.state.playing) {
          _setState(SdtvPlayerState.playing);
        }
      }
    }));

    _subs.add(_player.stream.error.listen((message) {
      if (_disposed) return;
      if (message.isEmpty) return;
      _error = message;
      _setState(SdtvPlayerState.error);
      debugPrint('sdtv_player error: $message');
    }));
  }

  late final Player _player;
  late final VideoController _videoController;
  final _subs = <StreamSubscription<dynamic>>[];

  SdtvPlayerState _state = SdtvPlayerState.idle;
  String? _url;
  String? _error;
  String _decodeLabel = 'decode: —';
  bool _disposed = false;
  Timer? _bufferStuckTimer;

  /// libmpv properties that reduce rebuffer/stutter on weak live HLS.
  Future<void> _applyLinuxPerfProps() async {
    if (!Platform.isLinux) return;
    try {
      final platform = _player.platform;
      if (platform == null) return;
      // NativePlayer.setProperty — not on the public Player type.
      final dynamic native = platform;
      if (native.setProperty is! Function) return;

      const props = <String, String>{
        // Comma = priority list (mpv). Needs libmpv built with VAAPI.
        'hwdec': 'vaapi,vaapi-copy,auto-safe,auto',
        'vo': 'libmpv',
        'gpu-context': 'auto',
        'cache': 'yes',
        'demuxer-max-bytes': '104857600', // 100 MiB
        'demuxer-max-back-bytes': '52428800',
        'demuxer-readahead-secs': '20',
        'cache-secs': '60',
        'interpolation': 'no',
        'video-sync': 'audio',
        'framedrop': 'vo',
        'vd-lavc-threads': '0',
      };
      for (final e in props.entries) {
        try {
          await native.setProperty(e.key, e.value) as Future?;
        } catch (err) {
          debugPrint('sdtv_player setProperty ${e.key}: $err');
        }
      }
      debugPrint('sdtv_player: applied Linux demuxer/hwdec props');
    } catch (e) {
      debugPrint('sdtv_player tune: $e');
    }
  }

  Future<void> _refreshDecodeLabel() async {
    var hw = '';
    var codec = '';
    try {
      final dynamic native = _player.platform;
      if (native != null && native.getProperty is Function) {
        try {
          hw = ((await native.getProperty('hwdec-current')) as String? ?? '')
              .trim();
        } catch (_) {}
        try {
          // e.g. h264, hevc
          codec =
              ((await native.getProperty('video-codec')) as String? ?? '')
                  .trim();
        } catch (_) {}
        if (codec.isEmpty) {
          try {
            codec =
                ((await native.getProperty('video-format')) as String? ?? '')
                    .trim();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('sdtv_player decode query: $e');
    }

    // Fallback from media_kit video params if mpv strings empty.
    if (codec.isEmpty) {
      try {
        final vp = _player.state.videoParams;
        final pix = vp.pixelformat;
        if (pix != null && pix.isNotEmpty) codec = pix;
      } catch (_) {}
    }

    final src = Platform.environment['SDTV_MPV_SOURCE'] ?? '?';
    final hwPart = hw.isEmpty || hw == 'no' ? 'cpu/software' : hw;
    final codecPart = codec.isEmpty ? '' : ' · $codec';
    _decodeLabel = 'decode: $hwPart$codecPart · mpv=$src';
    debugPrint('sdtv_player $_decodeLabel');
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
  VideoController get videoController => _videoController;

  Player get rawPlayer => _player;

  @override
  void resyncState() => _resyncFromNative();

  @override
  Future<void> open(Uri url) async {
    if (_disposed) return;
    _url = url.toString();
    _error = null;
    _bufferStuckTimer?.cancel();
    _setState(SdtvPlayerState.opening);
    try {
      await _player.open(Media(url.toString()), play: true);
      // Query after a beat — hwdec-current is often empty at open edge.
      unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (!_disposed) unawaited(_refreshDecodeLabel());
      }));
      await _refreshDecodeLabel();
      _resyncFromNative();
    } catch (e, st) {
      _error = e.toString();
      _setState(SdtvPlayerState.error);
      debugPrint('sdtv_player open failed: $e\n$st');
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
    _setState(SdtvPlayerState.idle);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _bufferStuckTimer?.cancel();
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
