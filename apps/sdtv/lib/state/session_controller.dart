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

/// Virtual category id for starred channels (not from provider).
const kFavoritesCategoryId = '__sdtv_favorites__';

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

  /// M3U playlist session (direct stream URLs per channel).
  bool useM3u = false;
  String? m3uPlaylistUrl;

  List<MediaCategory> categories = const [];
  List<LiveChannel> allChannels = const [];
  String? selectedCategoryId;
  LiveChannel? nowPlaying;

  /// Ordered favorite keys for the current [favoritesScope].
  List<String> _favoriteKeys = const [];

  /// Hidden provider category ids for the current scope.
  Set<String> _hiddenCategoryIds = {};

  /// Real HTTP Xtream provider (not demo, not forced mock, not M3U).
  bool get isLiveProvider => !useDemo && !mockCatalog && !useM3u;

  /// Prefs namespace so M3U vs Xtream vs demo don't share stars / hidden cats.
  String get favoritesScope {
    if (useDemo || mockCatalog) return 'demo';
    if (useM3u) {
      final u = m3uPlaylistUrl?.trim() ?? '';
      return u.isEmpty ? 'm3u' : 'm3u:$u';
    }
    final creds = _settings.credentials;
    if (creds == null) return 'xtream';
    return 'xtream:${creds.baseUrl}|${creds.username}';
  }

  /// Same scope string as [favoritesScope] (hidden cats share the namespace).
  String get prefsScope => favoritesScope;

  /// Provider categories that are not hidden (guide list without ★).
  List<MediaCategory> get visibleCategories => categories
      .where((c) => !_hiddenCategoryIds.contains(c.categoryId))
      .toList();

  /// Provider categories with ★ Favorites pinned first (hidden cats omitted).
  List<MediaCategory> get browseCategories => [
        const MediaCategory(
          categoryId: kFavoritesCategoryId,
          categoryName: '★ Favorites',
        ),
        ...visibleCategories,
      ];

  bool get isFavoritesCategory =>
      selectedCategoryId == kFavoritesCategoryId;

  bool isFavorite(LiveChannel channel) =>
      _favoriteKeys.contains(channel.favoriteKey);

  int get favoriteCount => _favoriteKeys.length;

  int get hiddenCategoryCount => _hiddenCategoryIds.length;

  bool isCategoryHidden(String categoryId) =>
      _hiddenCategoryIds.contains(categoryId);

  void _reloadFavorites() {
    _favoriteKeys = _settings.favoriteKeys(prefsScope);
  }

  void _reloadHiddenCategories() {
    _hiddenCategoryIds =
        _settings.hiddenCategoryIds(prefsScope).toSet();
  }

  void _reloadGuidePrefs() {
    _reloadFavorites();
    _reloadHiddenCategories();
  }

  /// Star / unstar [channel]. Returns true if now favorited.
  Future<bool> toggleFavorite(LiveChannel channel) async {
    final key = channel.favoriteKey;
    final nowFav = await _settings.toggleFavoriteKey(prefsScope, key);
    _reloadFavorites();
    notifyListeners();
    return nowFav;
  }

  /// Hide a provider category from the guide. Cannot hide ★ Favorites.
  /// Returns true if now hidden.
  Future<bool> hideCategory(String categoryId) async {
    if (categoryId.isEmpty || categoryId == kFavoritesCategoryId) {
      return false;
    }
    if (_hiddenCategoryIds.contains(categoryId)) return true;
    final list = _settings.hiddenCategoryIds(prefsScope)..add(categoryId);
    await _settings.setHiddenCategoryIds(prefsScope, list);
    _reloadHiddenCategories();
    _ensureSelectedCategoryVisible();
    notifyListeners();
    return true;
  }

  /// Show a previously hidden category again.
  Future<void> unhideCategory(String categoryId) async {
    if (!_hiddenCategoryIds.contains(categoryId)) return;
    final list = _settings.hiddenCategoryIds(prefsScope)
      ..remove(categoryId);
    await _settings.setHiddenCategoryIds(prefsScope, list);
    _reloadHiddenCategories();
    notifyListeners();
  }

  /// Toggle hidden. Returns true if now hidden.
  Future<bool> toggleCategoryHidden(String categoryId) async {
    if (categoryId.isEmpty || categoryId == kFavoritesCategoryId) {
      return false;
    }
    final nowHidden =
        await _settings.toggleHiddenCategoryId(prefsScope, categoryId);
    _reloadHiddenCategories();
    if (nowHidden) {
      _ensureSelectedCategoryVisible();
    }
    notifyListeners();
    return nowHidden;
  }

  /// If current selection was hidden, jump to first visible / favorites.
  void _ensureSelectedCategoryVisible() {
    final id = selectedCategoryId;
    if (id == null || id == kFavoritesCategoryId) return;
    if (!_hiddenCategoryIds.contains(id)) return;
    selectedCategoryId = _defaultCategoryId(categories);
  }

  /// Phase A: fullscreen external mpv for watch sessions.
  final ExternalMpvLauncher externalMpv = ExternalMpvLauncher();

  /// True while [watchChannel] is in flight (before/during external mpv).
  bool _watchInFlight = false;

  /// Channels available for zap during the current external session
  /// (same list as when play started: category or favorites).
  List<LiveChannel> _watchList = const [];
  int _watchIndex = 0;
  DateTime? _lastZapAt;
  DateTime? _lastVolAt;

  /// In-player menu (pause chrome). When open, D-pad navigates the menu
  /// instead of volume/channel — like focusing a video player's control bar.
  bool watchMenuOpen = false;
  int watchMenuIndex = 0;

  /// Order of rows in the watch menu OSD.
  static const watchMenuItems = <String>[
    'resume',
    'subtitles',
    'audio',
    'mute',
    'guide',
  ];

  /// External watch session active (mpv running or handoff in progress).
  ///
  /// Use for **player** pad routing (pause/quit/zap/vol). Do **not** freeze
  /// the whole browse UI with this — menu / Cancel must always work.
  bool get isWatchingExternal => _watchInFlight || externalMpv.isRunning;

  /// True when pad should drive the watch menu, not zap/volume.
  bool get isWatchMenuActive => isWatchingExternal && watchMenuOpen;

  String get _nowPlayingLabel {
    final ch = nowPlaying;
    if (ch == null) return 'Live';
    return ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;
  }

  /// A while watching: open menu (and pause), or confirm menu row.
  Future<void> watchActivate() async {
    if (!isWatchingExternal) return;
    if (watchMenuOpen) {
      await watchMenuConfirm();
    } else {
      await watchOpenMenu();
    }
  }

  /// Legacy name — same as [watchActivate].
  Future<void> watchCyclePause() => watchActivate();

  /// Open navigable pause menu (pauses playback).
  Future<void> watchOpenMenu() async {
    if (!isWatchingExternal) return;
    watchMenuOpen = true;
    watchMenuIndex = 0;
    await externalMpv.setPaused(true);
    await externalMpv.setOscVisible(true);
    await _paintWatchMenu();
    notifyListeners();
  }

  /// Close menu. [resume] unpauses; otherwise stay paused with OSC auto-hide.
  Future<void> watchCloseMenu({bool resume = false}) async {
    if (!isWatchingExternal) return;
    watchMenuOpen = false;
    watchMenuIndex = 0;
    if (resume) {
      await externalMpv.setPaused(false);
      await externalMpv.setOscVisible(false);
    } else {
      await externalMpv.setOscVisible(false);
      await externalMpv.showText(
        'Paused · A menu · B guide · LB/RB ch · ↑↓ vol',
        durationMs: 2500,
      );
    }
    notifyListeners();
  }

  Future<void> watchMenuMove(int delta) async {
    if (!isWatchMenuActive) return;
    final n = watchMenuItems.length;
    watchMenuIndex = (watchMenuIndex + delta) % n;
    if (watchMenuIndex < 0) watchMenuIndex += n;
    await _paintWatchMenu();
    notifyListeners();
  }

  /// ←/→ on a row: cycle value (subs / audio) or no-op.
  Future<void> watchMenuAdjust(int delta) async {
    if (!isWatchMenuActive) return;
    final id = watchMenuItems[watchMenuIndex];
    switch (id) {
      case 'subtitles':
        if (delta != 0) await externalMpv.cycleSubtitleTrack();
      case 'audio':
        if (delta != 0) await externalMpv.cycleAudioTrack();
      case 'mute':
        await externalMpv.cycleMute();
      default:
        break;
    }
    await _paintWatchMenu();
  }

  Future<void> watchMenuConfirm() async {
    if (!isWatchMenuActive) return;
    final id = watchMenuItems[watchMenuIndex];
    switch (id) {
      case 'resume':
        await watchCloseMenu(resume: true);
      case 'subtitles':
        await externalMpv.cycleSubtitleTrack();
        await _paintWatchMenu();
      case 'audio':
        await externalMpv.cycleAudioTrack();
        await _paintWatchMenu();
      case 'mute':
        await externalMpv.cycleMute();
        await _paintWatchMenu();
      case 'guide':
        await watchQuit();
      default:
        break;
    }
  }

  Future<void> _paintWatchMenu() async {
    final sub = await externalMpv.subtitleLabel();
    final aud = await externalMpv.audioLabel();
    final muted = await externalMpv.getProperty('mute');
    final muteLabel =
        (muted == true || muted == 'yes') ? 'On' : 'Off';

    final rows = <String>[
      'Resume',
      'Subtitles: $sub',
      'Audio: $aud',
      'Mute: $muteLabel',
      'Back to guide',
    ];

    final buf = StringBuffer('❚❚  $_nowPlayingLabel\n');
    for (var i = 0; i < rows.length; i++) {
      final mark = i == watchMenuIndex ? '▶ ' : '   ';
      buf.writeln('$mark${rows[i]}');
    }
    buf.write('↑↓ move · ←→ change · A select · B close menu');
    // Long duration; each move refreshes.
    await externalMpv.showText(buf.toString(), durationMs: 12000);
  }

  /// B while watching: close menu first, else quit to guide.
  Future<void> watchBack() async {
    if (!isWatchingExternal) return;
    if (watchMenuOpen) {
      await watchCloseMenu(resume: false);
      return;
    }
    await watchQuit();
  }

  /// Quit external mpv and return to guide (B while watching, menu closed).
  Future<void> watchQuit() async {
    if (!isWatchingExternal) return;
    debugPrint('sdtv: watchQuit');
    watchMenuOpen = false;
    watchMenuIndex = 0;
    await externalMpv.quit();
    // exitCode path clears _watchInFlight; if kill raced, force-clear.
    if (_watchInFlight && !externalMpv.isRunning) {
      _watchInFlight = false;
      nowPlaying = null;
      _watchList = const [];
      notifyListeners();
    }
  }

  /// Channel ± within the current watch list (LB/RB, ←/→, PgUp/PgDn).
  Future<void> watchChannelAdjacent(int delta) async {
    if (!isWatchingExternal || _watchList.isEmpty) return;
    if (watchMenuOpen) return; // menu owns the pad
    final now = DateTime.now();
    if (_lastZapAt != null &&
        now.difference(_lastZapAt!) < const Duration(milliseconds: 280)) {
      return;
    }
    _lastZapAt = now;

    if (_watchList.length == 1) {
      await externalMpv.showText(nowPlaying?.name ?? _watchList[0].name);
      return;
    }

    var i = (_watchIndex + delta) % _watchList.length;
    if (i < 0) i += _watchList.length;
    if (i == _watchIndex) return;

    final ch = _watchList[i];
    final uri = resolvePlayUri(ch);
    if (uri == null) {
      debugPrint('sdtv: zap skip — no URL for ${ch.name}');
      return;
    }

    _watchIndex = i;
    nowPlaying = ch;
    notifyListeners();

    // Live IPTV: always loadfile. playlist-pos often updates OSD index only and
    // does not re-open the stream (especially HLS/ts).
    final label = ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;
    await externalMpv.showText('→ $label', durationMs: 2200);
    final ok = await externalMpv.loadFile(uri, title: label);
    if (!ok) {
      debugPrint('sdtv: loadfile failed, trying playlist-play-index $i');
      await externalMpv.playlistPlayIndex(i);
      await externalMpv.setMediaTitle(label);
    }
  }

  /// Volume ± (D-pad / arrows). Steps of 5 on mpv's 0–100 scale + OSD.
  Future<void> watchVolumeDelta(int delta) async {
    if (!isWatchingExternal) return;
    if (watchMenuOpen) return;
    final now = DateTime.now();
    if (_lastVolAt != null &&
        now.difference(_lastVolAt!) < const Duration(milliseconds: 80)) {
      return;
    }
    _lastVolAt = now;
    await externalMpv.addVolume(delta);
  }

  Future<void> watchCycleMute() async {
    if (!isWatchingExternal) return;
    if (watchMenuOpen) {
      await externalMpv.cycleMute();
      await _paintWatchMenu();
      return;
    }
    await externalMpv.cycleMute();
  }

  List<LiveChannel> get channelsInCategory {
    final id = selectedCategoryId;
    if (id == kFavoritesCategoryId) {
      // Preserve star order from prefs.
      final byKey = <String, LiveChannel>{
        for (final c in allChannels) c.favoriteKey: c,
      };
      final out = <LiveChannel>[];
      for (final k in _favoriteKeys) {
        final ch = byKey[k];
        if (ch != null) out.add(ch);
      }
      return out;
    }
    if (id == null) return allChannels;
    return allChannels.where((c) => c.categoryId == id).toList();
  }

  /// Boot: restore saved session or land on login.
  Future<void> bootstrap() async {
    phase = SessionPhase.boot;
    errorMessage = null;
    notifyListeners();

    useDemo = _settings.useDemo;
    useM3u = _settings.useM3u;
    if (_settings.hasSavedSession) {
      try {
        if (useDemo) {
          await connectDemo(save: false);
        } else if (useM3u && _settings.m3uUrl != null) {
          await connectM3u(_settings.m3uUrl!, save: false);
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
      useM3u = false;
      m3uPlaylistUrl = null;
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

  /// Load a remote M3U / M3U8 **playlist** URL (user-supplied, legal lists only).
  Future<void> connectM3u(String playlistUrl, {bool save = true}) async {
    phase = SessionPhase.loading;
    errorMessage = null;
    notifyListeners();

    final loader = M3uLoader();
    try {
      final pl = await loader.load(playlistUrl);
      try {
        if (_client is HttpXtreamClient) {
          (_client as HttpXtreamClient).close();
        }
      } catch (_) {}
      _client = null;
      useDemo = false;
      mockCatalog = false;
      useM3u = true;
      m3uPlaylistUrl = playlistUrl.trim();
      userInfo = UserInfo(
        username: 'm3u',
        status: 'Active',
      );
      categories = pl.categories;
      allChannels = pl.channels;
      _reloadGuidePrefs();
      selectedCategoryId = _defaultCategoryId(pl.categories);

      if (save) {
        await _settings.saveSession(
          useDemo: false,
          useM3u: true,
          m3uUrl: m3uPlaylistUrl,
        );
      }
      phase = SessionPhase.browse;
      notifyListeners();
    } on XtreamException catch (e) {
      errorMessage = e.message;
      phase = SessionPhase.login;
      notifyListeners();
    } catch (e) {
      errorMessage = e.toString();
      phase = SessionPhase.login;
      notifyListeners();
    } finally {
      loader.close();
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
      useM3u = false;
      m3uPlaylistUrl = null;
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
    this.useDemo = useDemo;
    this.mockCatalog = mockCatalog;
    _reloadGuidePrefs();
    selectedCategoryId = _defaultCategoryId(cats);

    if (save) {
      await _settings.saveSession(
        useDemo: useDemo,
        useM3u: false,
        credentials: credentials,
      );
    }

    phase = SessionPhase.browse;
    notifyListeners();
  }

  /// Prefer ★ Favorites when starred; else first *visible* provider category.
  String? _defaultCategoryId(List<MediaCategory> cats) {
    if (_favoriteKeys.isNotEmpty) return kFavoritesCategoryId;
    for (final c in cats) {
      if (!_hiddenCategoryIds.contains(c.categoryId)) {
        return c.categoryId;
      }
    }
    return kFavoritesCategoryId;
  }

  void selectCategory(String categoryId) {
    selectedCategoryId = categoryId;
    notifyListeners();
  }

  /// Resolve the URL that should be handed to the player engine.
  Uri? resolvePlayUri(LiveChannel channel) {
    if (channel.hasDirectUrl) {
      return Uri.tryParse(channel.streamUrl!.trim());
    }
    if (useDemo || mockCatalog) {
      return Uri.parse(kDemoPlaybackUri);
    }
    final client = _client;
    if (client == null) return null;
    // Live: prefer .ts (mpv will error visibly if bad; m3u8 retry in Phase B).
    return client.livePlayUrl(channel.streamId, extension: 'ts');
  }

  /// Phase A/B: mark channel now-playing and run **external mpv** until quit.
  ///
  /// Builds a session playlist from the current category (or favorites) so
  /// channel zap works via IPC and keyboard PGUP/PGDWN inside mpv.
  ///
  /// Returns an error string if mpv could not start; null on normal exit
  /// or when a session is already watching (re-entry ignored).
  Future<String?> watchChannel(LiveChannel channel) async {
    // Synchronous re-entry guard: A still fires while Flutter is under mpv.
    if (_watchInFlight || externalMpv.isRunning) {
      debugPrint(
        'sdtv: watchChannel ignored (inFlight=$_watchInFlight '
        'mpv=${externalMpv.isRunning})',
      );
      return null;
    }

    _watchInFlight = true;
    nowPlaying = channel;
    notifyListeners();

    try {
      final uri = resolvePlayUri(channel);
      if (uri == null) {
        return 'No playable URL for this channel.';
      }

      // Zap list = current guide column (favorites or category).
      final list = channelsInCategory;
      final entries = <({String title, Uri uri})>[];
      final playable = <LiveChannel>[];
      for (final c in list) {
        final u = resolvePlayUri(c);
        if (u == null) continue;
        playable.add(c);
        entries.add((title: c.name, uri: u));
      }
      if (entries.isEmpty) {
        entries.add((title: channel.name, uri: uri));
        playable.add(channel);
      }

      var start = playable.indexWhere(
        (c) => c.favoriteKey == channel.favoriteKey,
      );
      if (start < 0) {
        // Selected channel not in filtered list — prepend.
        playable.insert(0, channel);
        entries.insert(0, (title: channel.name, uri: uri));
        start = 0;
      }

      _watchList = playable;
      _watchIndex = start;

      final result = await externalMpv.playFullscreen(
        uri,
        playlist: entries,
        startIndex: start,
      );
      if (result.busy) {
        return null;
      }
      if (!result.started) {
        return result.error ?? 'mpv failed to start';
      }
      return null;
    } finally {
      _watchInFlight = false;
      nowPlaying = null;
      _watchList = const [];
      _watchIndex = 0;
      watchMenuOpen = false;
      watchMenuIndex = 0;
      notifyListeners();
    }
  }

  /// Legacy embedded media_kit open (fallback / debug). Prefer [watchChannel].
  Future<void> playChannel(LiveChannel channel) async {
    final previous = nowPlaying;
    nowPlaying = channel;
    notifyListeners();

    if (channel.hasDirectUrl) {
      final url = Uri.parse(channel.streamUrl!.trim());
      if (previous?.streamId == channel.streamId &&
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

    final client = _client;
    if (client == null) return;

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

    final ts = client.livePlayUrl(channel.streamId, extension: 'ts');
    final m3u8 = client.livePlayUrl(channel.streamId, extension: 'm3u8');

    await player.open(ts);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (player.state == SdtvPlayerState.error) {
      debugPrint('sdtv: .ts open failed, trying .m3u8');
      await player.open(m3u8);
    }
    notifyListeners();
  }

  Future<void> playAdjacent(int delta) async {
    if (isWatchingExternal) {
      await watchChannelAdjacent(delta);
      return;
    }
    final list = channelsInCategory;
    if (list.isEmpty || nowPlaying == null) return;
    if (list.length == 1) {
      notifyListeners();
      return;
    }
    final idx = list.indexWhere((c) => c.streamId == nowPlaying!.streamId);
    if (idx < 0) {
      await watchChannel(list[0]);
      return;
    }
    final next = (idx + delta) % list.length;
    final i = next < 0 ? next + list.length : next;
    if (i == idx) return;
    await watchChannel(list[i]);
  }

  Future<void> stopPlayback({bool notify = true}) async {
    try {
      await externalMpv.stop();
    } catch (_) {}
    try {
      await player.stop();
    } catch (e, st) {
      debugPrint('sdtv: stopPlayback error: $e\n$st');
    }
    _watchInFlight = false;
    nowPlaying = null;
    _watchList = const [];
    _watchIndex = 0;
    watchMenuOpen = false;
    watchMenuIndex = 0;
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
    _favoriteKeys = const [];
    _hiddenCategoryIds = {};
    useDemo = true;
    mockCatalog = true;
    useM3u = false;
    m3uPlaylistUrl = null;
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
