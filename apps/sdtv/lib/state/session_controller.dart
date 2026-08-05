import 'dart:async';
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
  /// Trailing slashes on server URLs are stripped so save/load scopes match.
  String get favoritesScope {
    if (useDemo || mockCatalog) return 'demo';
    if (useM3u) {
      final u = m3uPlaylistUrl?.trim() ?? '';
      return u.isEmpty ? 'm3u' : 'm3u:$u';
    }
    final creds = _settings.credentials;
    if (creds == null) return 'xtream';
    final base = creds.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return 'xtream:$base|${creds.username.trim()}';
  }

  /// Same scope string as [favoritesScope] (hidden cats share the namespace).
  String get prefsScope => favoritesScope;

  /// Provider categories that are not hidden (guide list without ★).
  List<MediaCategory> get visibleCategories => categories
      .where((c) => !_hiddenCategoryIds.contains(c.categoryId))
      .toList();

  /// Provider categories with ★ Favorites pinned first (hidden cats omitted).
  ///
  /// If last-played sits in a **hidden** category, that category is still
  /// injected once so resume can land on it.
  List<MediaCategory> get browseCategories {
    final fav = const MediaCategory(
      categoryId: kFavoritesCategoryId,
      categoryName: '★ Favorites',
    );
    final visible = visibleCategories;
    final last = lastPlayedCategoryId;
    if (last == null ||
        last.isEmpty ||
        last == kFavoritesCategoryId ||
        !_hiddenCategoryIds.contains(last)) {
      return [fav, ...visible];
    }
    MediaCategory? resumeCat;
    for (final c in categories) {
      if (c.categoryId == last) {
        resumeCat = c;
        break;
      }
    }
    if (resumeCat == null) return [fav, ...visible];
    // Avoid dup if somehow visible.
    if (visible.any((c) => c.categoryId == last)) {
      return [fav, ...visible];
    }
    return [fav, resumeCat, ...visible];
  }

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

  /// Last played (restored on connect for this [prefsScope]).
  String? lastPlayedCategoryId;
  String? lastPlayedFavoriteKey;
  String? lastPlayedName;

  void _reloadGuidePrefs() {
    _reloadFavorites();
    _reloadHiddenCategories();
    _reloadLastPlayed();
  }

  int? lastPlayedStreamId;

  void _reloadLastPlayed() {
    final m = _settings.lastPlayed(prefsScope);
    lastPlayedCategoryId = m['categoryId'];
    lastPlayedFavoriteKey = m['favoriteKey'];
    lastPlayedName = m['name'];
    lastPlayedStreamId = int.tryParse(m['streamId'] ?? '');
    debugPrint(
      'sdtv: lastPlayed reload scope=$prefsScope → $m',
    );
  }

  /// Persist last played for relaunch (category + channel key).
  ///
  /// Always prefers the channel's **provider** category (not ★ Favorites) so
  /// resume lands in US MOVIES etc. rather than the favorites list.
  Future<void> rememberLastPlayed(LiveChannel channel) async {
    var catId = channel.categoryId.trim();
    if (catId.isEmpty) {
      catId = (selectedCategoryId == kFavoritesCategoryId)
          ? ''
          : (selectedCategoryId ?? '');
    }
    if (catId.isEmpty || catId == kFavoritesCategoryId) {
      // Still allow favorites-only resume if that is all we know.
      if (selectedCategoryId == kFavoritesCategoryId) {
        catId = kFavoritesCategoryId;
      }
    }
    lastPlayedCategoryId = catId;
    lastPlayedFavoriteKey = channel.favoriteKey;
    lastPlayedName = channel.name;
    lastPlayedStreamId = channel.streamId;
    debugPrint(
      'sdtv: lastPlayed save scope=$prefsScope cat=$catId '
      'key=${channel.favoriteKey} id=${channel.streamId} name=${channel.name}',
    );
    await _settings.setLastPlayed(
      prefsScope,
      categoryId: catId,
      favoriteKey: channel.favoriteKey,
      name: channel.name,
      streamId: channel.streamId,
    );
  }

  /// Channel for last-played key / name / stream id, if still in the catalog.
  LiveChannel? get lastPlayedChannel {
    final key = lastPlayedFavoriteKey;
    if (key != null && key.isNotEmpty) {
      final byKey = channelForFavoriteKey(key);
      if (byKey != null) return byKey;
    }
    final sid = lastPlayedStreamId;
    if (sid != null && sid != 0) {
      for (final c in allChannels) {
        if (c.streamId == sid) return c;
      }
    }
    final name = lastPlayedName?.trim().toLowerCase();
    if (name == null || name.isEmpty) return null;
    // Prefer match in last category if set.
    final cat = lastPlayedCategoryId;
    for (final c in allChannels) {
      if (c.name.trim().toLowerCase() != name) continue;
      if (cat == null ||
          cat.isEmpty ||
          cat == kFavoritesCategoryId ||
          c.categoryId == cat) {
        return c;
      }
    }
    for (final c in allChannels) {
      if (c.name.trim().toLowerCase() == name) return c;
    }
    return null;
  }

  /// Index of last-played channel in [channelsInCategory], or -1.
  int get lastPlayedChannelIndex {
    final ch = lastPlayedChannel;
    if (ch == null) return -1;
    final list = channelsInCategory;
    final byKey = list.indexWhere((c) => c.favoriteKey == ch.favoriteKey);
    if (byKey >= 0) return byKey;
    return list.indexWhere((c) => c.streamId == ch.streamId && c.name == ch.name);
  }

  /// Align [selectedCategoryId] so last-played channel is in the current list.
  /// Returns true if a resume target was applied.
  bool applyLastPlayedSelection() {
    _reloadLastPlayed();
    final ch = lastPlayedChannel;
    debugPrint(
      'sdtv: lastPlayed apply scope=$prefsScope cat=$lastPlayedCategoryId '
      'key=$lastPlayedFavoriteKey id=$lastPlayedStreamId name=$lastPlayedName '
      'resolved=${ch?.name} catId=${ch?.categoryId}',
    );
    if (ch == null) {
      final lastCat = lastPlayedCategoryId;
      if (lastCat != null &&
          lastCat.isNotEmpty &&
          (lastCat == kFavoritesCategoryId ||
              categories.any((c) => c.categoryId == lastCat))) {
        selectedCategoryId = lastCat;
        return true;
      }
      return false;
    }

    // Prefer the channel's real provider category (US MOVIES, etc.).
    if (ch.categoryId.isNotEmpty &&
        categories.any((c) => c.categoryId == ch.categoryId)) {
      selectedCategoryId = ch.categoryId;
      return true;
    }
    final lastCat = lastPlayedCategoryId;
    if (lastCat != null &&
        lastCat.isNotEmpty &&
        (lastCat == kFavoritesCategoryId ||
            categories.any((c) => c.categoryId == lastCat))) {
      selectedCategoryId = lastCat;
      return true;
    }
    selectedCategoryId = ch.categoryId;
    return true;
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
  bool _zapInFlight = false;

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
    // Recover audio if a previous menu pass left aid=no (silent channel).
    await externalMpv.ensureAudioOn();
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
        if (delta != 0) {
          await externalMpv.cycleAudioTrack(direction: delta > 0 ? 1 : -1);
        }
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
        await externalMpv.ensureAudioOn();
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
  ///
  /// Dead streams: try `.ts` then `.m3u8`, then auto-advance in [delta]
  /// direction (skip stubs) up to a cap so free/M3U lists stay usable.
  Future<void> watchChannelAdjacent(int delta) async {
    if (!isWatchingExternal || _watchList.isEmpty) return;
    if (watchMenuOpen) return; // menu owns the pad
    if (_zapInFlight) return;
    final now = DateTime.now();
    if (_lastZapAt != null &&
        now.difference(_lastZapAt!) < const Duration(milliseconds: 280)) {
      return;
    }
    _lastZapAt = now;

    if (_watchList.length == 1) {
      // Still retry formats on the only channel.
      await _zapLoadChannel(_watchList[0], announce: '→');
      return;
    }

    _zapInFlight = true;
    try {
      final n = _watchList.length;
      final maxAttempts = n < 15 ? n : 15;
      var i = _watchIndex;
      var skipped = 0;

      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        i = (i + delta) % n;
        if (i < 0) i += n;

        final ch = _watchList[i];
        _watchIndex = i;
        nowPlaying = ch;
        notifyListeners();

        final announce = skipped == 0 ? '→' : 'Skipping…';
        final healthy = await _zapLoadChannel(ch, announce: announce);
        if (healthy) {
          unawaited(rememberLastPlayed(ch));
          if (skipped > 0) {
            final label = ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;
            await externalMpv.showText(
              'OK · $label',
              durationMs: 1600,
            );
          }
          return;
        }

        skipped++;
        debugPrint(
          'sdtv: zap dead (${ch.name}) — skip $skipped/$maxAttempts',
        );
      }

      await externalMpv.showText(
        'No playable channel nearby',
        durationMs: 2500,
      );
    } finally {
      _zapInFlight = false;
    }
  }

  /// Load one channel during zap: primary URL, then HLS fallback; health check.
  /// Returns true if playback looks healthy.
  Future<bool> _zapLoadChannel(
    LiveChannel ch, {
    required String announce,
  }) async {
    final uri = resolvePlayUri(ch);
    final label = ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;
    if (uri == null) {
      await externalMpv.showText('$announce $label (no URL)', durationMs: 1200);
      return false;
    }

    final fallback = resolvePlayUriFallback(ch);
    await externalMpv.showText('$announce $label', durationMs: 1800);
    final ok = await externalMpv.loadFile(uri, title: label);
    if (!ok) {
      debugPrint('sdtv: zap loadfile failed for ${ch.name}');
      if (fallback != null) {
        await externalMpv.loadFile(fallback, title: label);
      } else {
        return false;
      }
    }

    return externalMpv.waitUntilHealthyOrFallback(
      fallback,
      title: label,
      grace: const Duration(milliseconds: 1800),
    );
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

  /// Guide search (categories + channels). EPG can append later via same hits.
  List<GuideSearchHit> searchGuide(String query, {int maxResults = 120}) {
    return GuideSearch.search(
      query: query,
      categories: [
        for (final c in categories) (id: c.categoryId, name: c.categoryName),
      ],
      channels: allChannels,
      hiddenCategoryIds: _hiddenCategoryIds,
      favoriteKeys: _favoriteKeys.toSet(),
      maxResults: maxResults,
    );
  }

  /// Resolve a stored favorite key to a live catalog channel (best-effort).
  LiveChannel? channelForFavoriteKey(String key) {
    for (final c in allChannels) {
      if (c.favoriteKey == key) return c;
    }
    // Legacy keys / collisions: try stream id or name prefix.
    if (key.startsWith('i:')) {
      final id = int.tryParse(key.substring(2));
      if (id != null && id != 0) {
        for (final c in allChannels) {
          if (c.streamId == id) return c;
        }
      }
    }
    if (key.startsWith('n:')) {
      final rest = key.substring(2);
      final pipe = rest.lastIndexOf('|');
      final name = pipe >= 0 ? rest.substring(0, pipe) : rest;
      final cat = pipe >= 0 ? rest.substring(pipe + 1) : null;
      for (final c in allChannels) {
        if (c.name.trim().toLowerCase() != name) continue;
        if (cat == null || cat.isEmpty || c.categoryId == cat) return c;
      }
    }
    return null;
  }

  /// Jump guide selection to a category (and optional channel).
  void focusGuideTarget({
    required String categoryId,
    LiveChannel? channel,
  }) {
    if (categoryId == kFavoritesCategoryId ||
        categories.any((c) => c.categoryId == categoryId)) {
      selectedCategoryId = categoryId;
    }
    notifyListeners();
  }

  List<LiveChannel> get channelsInCategory {
    final id = selectedCategoryId;
    if (id == kFavoritesCategoryId) {
      // Preserve star order from prefs; resolve keys robustly (not map-by-key
      // only — duplicate favoriteKey used to drop channels silently).
      final out = <LiveChannel>[];
      final seen = <String>{};
      for (final k in _favoriteKeys) {
        final ch = channelForFavoriteKey(k);
        if (ch == null) continue;
        if (!seen.add(ch.favoriteKey)) continue;
        out.add(ch);
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
      // Scope depends on m3uPlaylistUrl — already set above.
      if (save) {
        await _settings.saveSession(
          useDemo: false,
          useM3u: true,
          m3uUrl: m3uPlaylistUrl,
        );
      }
      _reloadGuidePrefs();
      if (!applyLastPlayedSelection()) {
        selectedCategoryId = _defaultCategoryId(pl.categories);
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
    // Save credentials first so [prefsScope] matches while loading last-played.
    if (save) {
      await _settings.saveSession(
        useDemo: useDemo,
        useM3u: false,
        credentials: credentials,
      );
    }
    _reloadGuidePrefs();
    if (!applyLastPlayedSelection()) {
      selectedCategoryId = _defaultCategoryId(cats);
    }

    phase = SessionPhase.browse;
    notifyListeners();
  }

  /// Fallback when no last-played: ★ Favorites if starred, else first visible.
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
  ///
  /// [extension] is for Xtream live only (`ts` or `m3u8`). Direct M3U URLs
  /// and demo ignore it.
  Uri? resolvePlayUri(LiveChannel channel, {String extension = 'ts'}) {
    if (channel.hasDirectUrl) {
      return Uri.tryParse(channel.streamUrl!.trim());
    }
    if (useDemo || mockCatalog) {
      return Uri.parse(kDemoPlaybackUri);
    }
    final client = _client;
    if (client == null) return null;
    return client.livePlayUrl(channel.streamId, extension: extension);
  }

  /// HLS fallback when primary is Xtream `.ts` (null for M3U/demo).
  Uri? resolvePlayUriFallback(LiveChannel channel) {
    if (channel.hasDirectUrl || useDemo || mockCatalog) return null;
    if (_client == null) return null;
    return resolvePlayUri(channel, extension: 'm3u8');
  }

  /// Phase A/B: mark channel now-playing and run **external mpv** until quit.
  ///
  /// Builds a session playlist from the current category (or favorites) so
  /// channel zap works via IPC and keyboard PGUP/PGDWN inside mpv.
  ///
  /// Xtream: starts with `.ts`, auto-retries `.m3u8` if demux fails.
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
    // Await so a quick exit after play still has prefs flushed.
    try {
      await rememberLastPlayed(channel);
    } catch (e) {
      debugPrint('sdtv: rememberLastPlayed failed: $e');
    }

    try {
      final uri = resolvePlayUri(channel);
      if (uri == null) {
        return 'No playable URL for this channel.';
      }
      final fallback = resolvePlayUriFallback(channel);

      // Zap list = current guide column (favorites or category). Primary = .ts.
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

      var result = await externalMpv.playFullscreen(
        uri,
        playlist: entries,
        startIndex: start,
        fallbackUrl: fallback,
        fallbackTitle: channel.name,
      );

      // Process died immediately (mpv rejected .ts) — full restart on .m3u8.
      if (result.failedFast && fallback != null) {
        debugPrint('sdtv: mpv exited fast on .ts — restarting with .m3u8');
        final hlsEntries = <({String title, Uri uri})>[];
        for (final c in playable) {
          final u = resolvePlayUriFallback(c) ?? resolvePlayUri(c);
          if (u == null) continue;
          hlsEntries.add((title: c.name, uri: u));
        }
        if (hlsEntries.isEmpty) {
          hlsEntries.add((title: channel.name, uri: fallback));
        }
        var hlsStart = playable.indexWhere(
          (c) => c.favoriteKey == channel.favoriteKey,
        );
        if (hlsStart < 0) hlsStart = 0;
        if (hlsStart >= hlsEntries.length) hlsStart = 0;
        result = await externalMpv.playFullscreen(
          fallback,
          playlist: hlsEntries,
          startIndex: hlsStart,
        );
      }

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
    lastPlayedCategoryId = null;
    lastPlayedFavoriteKey = null;
    lastPlayedName = null;
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
