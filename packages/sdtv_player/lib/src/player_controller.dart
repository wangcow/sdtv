import 'dart:async';

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
        bufferSize: 32 * 1024 * 1024,
        title: 'sdtv',
      ),
    );
    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _subs.add(_player.stream.playing.listen((_) {
      if (_disposed) return;
      _resyncFromNative();
    }));

    _subs.add(_player.stream.buffering.listen((_) {
      if (_disposed) return;
      _resyncFromNative();
    }));

    // Position ticks while audio/video advances — clears stuck "buffering" UI
    // after long idle / brief rebuffer (bipbop still audible but spinner stuck).
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
  bool _disposed = false;
  Timer? _bufferStuckTimer;

  /// Map media_kit/mpv flags → UI state.
  ///
  /// **Playing wins over buffering.** HLS often reports buffering=true while
  /// still outputting audio; treating that as "buffering" left a forever
  /// spinner after rebuffer / walk-away.
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
      // Native may have recovered without a clean buffering=false edge.
      if (_player.state.playing) {
        _setState(SdtvPlayerState.playing);
        return;
      }
      // Last resort: re-read flags once more.
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
