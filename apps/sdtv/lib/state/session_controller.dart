import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../services/mock_client_factory.dart';
import '../services/settings_store.dart';

enum SessionPhase {
  boot,
  login,
  loading,
  browse,
  error,
}

/// Public HLS used in demo mode so the player can show real video without a provider.
const kDemoPlaybackUri = String.fromEnvironment(
  'SDTV_DEMO_STREAM',
  defaultValue:
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
);

/// App-wide session: Xtream client, live catalog, player.
class SessionController extends ChangeNotifier {
  SessionController({
    required SettingsStore settings,
    SdtvPlayerController? player,
  })  : _settings = settings,
        player = player ?? StubSdtvPlayerController();

  final SettingsStore _settings;
  final SdtvPlayerController player;

  SessionPhase phase = SessionPhase.boot;
  String? errorMessage;
  UserInfo? userInfo;
  XtreamClient? _client;
  bool useDemo = true;

  List<MediaCategory> categories = const [];
  List<LiveChannel> allChannels = const [];
  String? selectedCategoryId;
  LiveChannel? nowPlaying;

  List<LiveChannel> get channelsInCategory {
    final id = selectedCategoryId;
    if (id == null) return allChannels;
    return allChannels.where((c) => c.categoryId == id).toList();
  }

  /// Boot: restore saved session or land on login.
  Future<void> bootstrap() async {
    phase = SessionPhase.boot;
    errorMessage = null;
    notifyListeners();

    useDemo = _settings.useDemo;
    if (_settings.hasSavedSession) {
      try {
        if (useDemo) {
          await connectDemo(save: false);
        } else {
          final creds = _settings.credentials;
          if (creds != null) {
            await connectRemote(creds, save: false);
          } else {
            phase = SessionPhase.login;
            notifyListeners();
          }
        }
        return;
      } catch (e) {
        errorMessage = e.toString();
        phase = SessionPhase.login;
        notifyListeners();
        return;
      }
    }

    phase = SessionPhase.login;
    notifyListeners();
  }

  Future<void> connectDemo({bool save = true}) async {
    phase = SessionPhase.loading;
    errorMessage = null;
    notifyListeners();

    try {
      final client = await loadMockXtreamClient();
      await _finishConnect(client, useDemo: true, save: save);
    } catch (e) {
      errorMessage = 'Demo load failed: $e';
      phase = SessionPhase.login;
      notifyListeners();
    }
  }

  Future<void> connectRemote(
    XtreamCredentials credentials, {
    bool save = true,
  }) async {
    phase = SessionPhase.loading;
    errorMessage = null;
    notifyListeners();

    try {
      // Phase 1 default: mock catalog (no provider ban risk).
      // Real network: SDTV_ALLOW_LIVE=1 ./tool/run.sh
      final allowLive = _envFlag('SDTV_ALLOW_LIVE');

      final XtreamClient client;
      if (allowLive) {
        client = HttpXtreamClient(credentials: credentials);
      } else {
        client = await loadMockXtreamClient(credentials: credentials);
      }
      await _finishConnect(
        client,
        useDemo: false,
        save: save,
        credentials: credentials,
      );
    } on XtreamException catch (e) {
      errorMessage = e.message;
      phase = SessionPhase.login;
      notifyListeners();
    } catch (e) {
      errorMessage = e.toString();
      phase = SessionPhase.login;
      notifyListeners();
    }
  }

  Future<void> _finishConnect(
    XtreamClient client, {
    required bool useDemo,
    required bool save,
    XtreamCredentials? credentials,
  }) async {
    final info = await client.authenticate();
    final cats = await client.getLiveCategories();
    final streams = await client.getLiveStreams();

    _client = client;
    userInfo = info;
    categories = cats;
    allChannels = streams;
    selectedCategoryId = cats.isNotEmpty ? cats.first.categoryId : null;
    this.useDemo = useDemo;

    if (save) {
      await _settings.saveSession(
        useDemo: useDemo,
        credentials: credentials,
      );
    }

    phase = SessionPhase.browse;
    notifyListeners();
  }

  void selectCategory(String categoryId) {
    selectedCategoryId = categoryId;
    notifyListeners();
  }

  Future<void> playChannel(LiveChannel channel) async {
    final client = _client;
    if (client == null) return;
    final previous = nowPlaying;
    nowPlaying = channel;
    // Update HUD immediately (player page listens to session).
    notifyListeners();

    // Demo/mock playlists use a public test stream (real video, no provider).
    // Live Xtream uses the provider URL when SDTV_ALLOW_LIVE=1.
    final Uri url;
    if (useDemo) {
      url = Uri.parse(kDemoPlaybackUri);
    } else {
      url = client.livePlayUrl(channel.streamId);
    }

    // Demo: every mock channel shares one HLS. Don't restart playback on zap —
    // just change the on-screen channel name (instant, no re-buffer).
    if (useDemo &&
        previous != null &&
        player.currentUrl == url.toString() &&
        (player.state == SdtvPlayerState.playing ||
            player.state == SdtvPlayerState.paused ||
            player.state == SdtvPlayerState.buffering)) {
      return;
    }

    await player.open(url);
    notifyListeners();
  }

  Future<void> playAdjacent(int delta) async {
    final list = channelsInCategory;
    if (list.isEmpty || nowPlaying == null) return;
    if (list.length == 1) {
      // Single-channel category (News/Sports in mock): nothing to zap.
      notifyListeners();
      return;
    }
    final idx = list.indexWhere((c) => c.streamId == nowPlaying!.streamId);
    if (idx < 0) {
      await playChannel(list[0]);
      return;
    }
    // Dart `%` can be negative; normalize into [0, length).
    final next = (idx + delta) % list.length;
    final i = next < 0 ? next + list.length : next;
    if (i == idx) return;
    await playChannel(list[i]);
  }

  Future<void> stopPlayback({bool notify = true}) async {
    try {
      await player.stop();
    } catch (e, st) {
      debugPrint('sdtv: stopPlayback error: $e\n$st');
    }
    nowPlaying = null;
    if (notify) notifyListeners();
  }

  Future<void> signOut() async {
    // Single notify at end — avoids rebuild storms mid-teardown (felt like a freeze).
    try {
      await stopPlayback(notify: false);
    } catch (_) {}
    try {
      if (_client is HttpXtreamClient) {
        (_client as HttpXtreamClient).close();
      }
    } catch (e, st) {
      debugPrint('sdtv: client close error: $e\n$st');
    }
    _client = null;
    userInfo = null;
    categories = const [];
    allChannels = const [];
    selectedCategoryId = null;
    try {
      await _settings.clearSession();
    } catch (e, st) {
      debugPrint('sdtv: clearSession error: $e\n$st');
    }
    phase = SessionPhase.login;
    errorMessage = null;
    notifyListeners();
  }

  bool _envFlag(String name) {
    final compile = String.fromEnvironment(name, defaultValue: '');
    if (compile == '1' || compile.toLowerCase() == 'true') return true;
    if (kIsWeb) return false;
    final v = Platform.environment[name]?.toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }

  @override
  void dispose() {
    if (_client is HttpXtreamClient) {
      (_client as HttpXtreamClient).close();
    }
    // Player dispose is async; fire-and-forget.
    player.dispose();
    super.dispose();
  }
}
