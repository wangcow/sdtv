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
    if (_state == SdtvPlayerState.playing) {
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
        // Prefer low latency for live IPTV; still fine for VOD.
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

    _subs.add(_player.stream.playing.listen((playing) {
      if (_disposed) return;
      if (_player.state.buffering) {
        _state = SdtvPlayerState.buffering;
      } else if (playing) {
        _state = SdtvPlayerState.playing;
        _error = null;
      } else if (_url != null) {
        _state = SdtvPlayerState.paused;
      }
      notifyListeners();
    }));

    _subs.add(_player.stream.buffering.listen((buffering) {
      if (_disposed) return;
      if (buffering) {
        _state = SdtvPlayerState.buffering;
        notifyListeners();
      }
    }));

    _subs.add(_player.stream.error.listen((message) {
      if (_disposed) return;
      if (message.isEmpty) return;
      _error = message;
      _state = SdtvPlayerState.error;
      notifyListeners();
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
  Future<void> open(Uri url) async {
    if (_disposed) return;
    _url = url.toString();
    _error = null;
    _state = SdtvPlayerState.opening;
    notifyListeners();
    try {
      await _player.open(Media(url.toString()), play: true);
      // State updates via streams.
    } catch (e, st) {
      _error = e.toString();
      _state = SdtvPlayerState.error;
      notifyListeners();
      debugPrint('sdtv_player open failed: $e\n$st');
    }
  }

  @override
  Future<void> play() async {
    if (_disposed || _url == null) return;
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _player.stop();
    } catch (_) {}
    _url = null;
    _state = SdtvPlayerState.idle;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _player.dispose();
    } catch (_) {}
    super.dispose();
  }
}
