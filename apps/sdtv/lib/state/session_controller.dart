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

/// Public HLS used in demo / forced-mock mode.
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

  /// True when catalog/playback is fixture-based (demo or SDTV_FORCE_MOCK).
  bool mockCatalog = true;

  List<MediaCategory> categories = const [];
  List<LiveChannel> allChannels = const [];
  String? selectedCategoryId;
  LiveChannel? nowPlaying;

  /// Real HTTP Xtream provider (not demo, not forced mock).
  bool get isLiveProvider => !useDemo && !mockCatalog;

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
      await _finishConnect(
        client,
        useDemo: true,
        mockCatalog: true,
        save: save,
      );
    } catch (e) {
      errorMessage = 'Demo load failed: $e';
      phase = SessionPhase.login;
      notifyListeners();
    }
  }

  /// Failures against a real panel — used to enforce cooldown (avoid bans).
  int _liveFailCount = 0;
  DateTime? _liveCooldownUntil;

  /// Remaining live-connect cooldown, if any.
  Duration? get liveConnectCooldownRemaining {
    final until = _liveCooldownUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left.isNegative) return null;
    return left;
  }

  /// Connect to a provider (or mock if [SDTV_FORCE_MOCK]=1).
  Future<void> connectRemote(
    XtreamCredentials credentials, {
    bool save = true,
  }) async {
    phase = SessionPhase.loading;
    errorMessage = null;
    notifyListeners();

    try {
      if (!XtreamCredentials.isPlausibleServerUrl(credentials.baseUrl)) {
        throw XtreamException(
          'Server URL must look like http://host:port (not a placeholder).',
        );
      }

      // Product default: Connect = real Xtream.
      // CI / safe offline: SDTV_FORCE_MOCK=1 (or legacy SDTV_ALLOW_LIVE=0).
      final forceMock = _envFlag('SDTV_FORCE_MOCK') ||
          _envIsFalse('SDTV_ALLOW_LIVE');

      if (!forceMock) {
        final left = liveConnectCooldownRemaining;
        if (left != null) {
          final secs = left.inSeconds.clamp(1, 3600);
          throw XtreamException(
            'Live connect cooling down (${secs}s). '
            'Wait before trying again — repeated failures can flag or ban accounts. '
            'Use Demo playlist meanwhile.',
          );
        }
      }

      final XtreamClient client;
      final bool mock;
      if (forceMock) {
        client = await loadMockXtreamClient(credentials: credentials);
        mock = true;
      } else {
        client = HttpXtreamClient(credentials: credentials);
        mock = false;
      }
      await _finishConnect(
        client,
        useDemo: false,
        mockCatalog: mock,
        save: save,
        credentials: credentials,
      );
      // Success — reset fail budget.
      _liveFailCount = 0;
      _liveCooldownUntil = null;
    } on XtreamException catch (e) {
      errorMessage = _noteLiveConnectFailure(e);
      phase = SessionPhase.login;
      notifyListeners();
    } catch (e) {
      errorMessage = _noteLiveConnectFailure(
        XtreamException(e.toString()),
      );
      phase = SessionPhase.login;
      notifyListeners();
    }
  }

  /// Record failure, set cooldown, return user-facing message.
  String _noteLiveConnectFailure(XtreamException e) {
    if (e.message.contains('cooling down')) {
      return e.message;
    }
    // Only throttle real-panel attempts (not mock).
    if (_envFlag('SDTV_FORCE_MOCK') || _envIsFalse('SDTV_ALLOW_LIVE')) {
      return e.message;
    }
    _liveFailCount++;
    // 15s → 45s → 2m → 5m — avoid hammering panels / CF.
    final seconds = switch (_liveFailCount) {
      1 => 15,
      2 => 45,
      3 => 120,
      _ => 300,
    };
    _liveCooldownUntil = DateTime.now().add(Duration(seconds: seconds));
    final hint = e.statusCode == 403
        ? ' HTTP 403 can mean IP/Cloudflare block — stop retrying; check TiviMate and provider support.'
        : '';
    return '${e.message}$hint Wait ${seconds}s before Connect again (or use Demo).';
  }

  Future<void> _finishConnect(
    XtreamClient client, {
    required bool useDemo,
    required bool mockCatalog,
    required bool save,
    XtreamCredentials? credentials,
  }) async {
    final info = await client.authenticate();
    final cats = await client.getLiveCategories();
    final streams = await client.getLiveStreams();

    if (cats.isEmpty && streams.isEmpty) {
      throw XtreamException('Login OK but no live categories or channels.');
    }

    // Close previous HTTP client if any.
    try {
      if (_client is HttpXtreamClient) {
        (_client as HttpXtreamClient).close();
      }
    } catch (_) {}

    _client = client;
    userInfo = info;
    categories = cats;
    allChannels = streams;
    selectedCategoryId = cats.isNotEmpty ? cats.first.categoryId : null;
    this.useDemo = useDemo;
    this.mockCatalog = mockCatalog;

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
    notifyListeners();

    // Demo / forced mock: public test HLS.
    if (useDemo || mockCatalog) {
      final url = Uri.parse(kDemoPlaybackUri);
      if (previous != null &&
          player.currentUrl == url.toString() &&
          (player.state == SdtvPlayerState.playing ||
              player.state == SdtvPlayerState.paused ||
              player.state == SdtvPlayerState.buffering)) {
        return;
      }
      await player.open(url);
      notifyListeners();
      return;
    }

    // Live provider: real per-channel URL. Prefer .ts then fall back to .m3u8.
    final ts = client.livePlayUrl(channel.streamId, extension: 'ts');
    final m3u8 = client.livePlayUrl(channel.streamId, extension: 'm3u8');

    await player.open(ts);
    // Brief window for async open/error from libmpv.
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (player.state == SdtvPlayerState.error) {
      debugPrint('sdtv: .ts open failed, trying .m3u8');
      await player.open(m3u8);
    }
    notifyListeners();
  }

  Future<void> playAdjacent(int delta) async {
    final list = channelsInCategory;
    if (list.isEmpty || nowPlaying == null) return;
    if (list.length == 1) {
      notifyListeners();
      return;
    }
    final idx = list.indexWhere((c) => c.streamId == nowPlaying!.streamId);
    if (idx < 0) {
      await playChannel(list[0]);
      return;
    }
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
    useDemo = true;
    mockCatalog = true;
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

  /// True when env is explicitly 0/false/no (used for legacy SDTV_ALLOW_LIVE=0).
  bool _envIsFalse(String name) {
    if (kIsWeb) return false;
    final compile = String.fromEnvironment(name, defaultValue: '');
    if (compile == '0' || compile.toLowerCase() == 'false') return true;
    final v = Platform.environment[name]?.toLowerCase();
    return v == '0' || v == 'false' || v == 'no';
  }

  @override
  void dispose() {
    if (_client is HttpXtreamClient) {
      (_client as HttpXtreamClient).close();
    }
    player.dispose();
    super.dispose();
  }
}
