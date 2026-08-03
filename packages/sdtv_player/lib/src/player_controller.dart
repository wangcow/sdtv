import 'package:flutter/foundation.dart';

/// High-level player state. Concrete libmpv backend comes later.
enum SdtvPlayerState {
  idle,
  opening,
  playing,
  paused,
  buffering,
  error,
}

/// Minimal playback controller API. Stub implementation logs only.
abstract class SdtvPlayerController {
  SdtvPlayerState get state;
  String? get currentUrl;
  String? get lastError;

  Future<void> open(Uri url);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> dispose();
}

/// No-op player used until media_kit is wired.
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
  Future<void> open(Uri url) async {
    _url = url.toString();
    _error = null;
    _state = SdtvPlayerState.opening;
    notifyListeners();
    // Simulate successful open without real decode.
    _state = SdtvPlayerState.playing;
    notifyListeners();
    debugPrint('sdtv_player stub open: $url');
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
