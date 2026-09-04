import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_player/sdtv_player.dart';

import '../services/mock_client_factory.dart';
import '../services/artwork_cache.dart';
import '../services/open_external_url.dart';
import '../services/saved_source.dart';
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

enum GuideSection { live, movies, series }

/// App-wide session: Xtream client, live catalog, player.
class SessionController extends ChangeNotifier {
  SessionController({
    required SettingsStore settings,
    SdtvPlayerController? player,
    ArtworkCache? artwork,
  })  : _settings = settings,
        player = player ?? StubSdtvPlayerController(),
        artwork = artwork ?? ArtworkCache();

  final SettingsStore _settings;
  final SdtvPlayerController player;
  final ArtworkCache artwork;

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

  GuideSection guideSection = GuideSection.live;
  List<MediaCategory> vodCategories = const [];
  List<VodItem> allVod = const [];
  String? selectedVodCategoryId;
  VodItem? nowPlayingVod;
  bool watchingVod = false;
  bool vodCatalogReady = false;
  String? vodError;

  VodItem? vodDetailItem;
  VodInfo? vodDetail;
  bool vodDetailLoading = false;
  final Map<int, VodInfo> _vodInfoCache = {};

  List<MediaCategory> seriesCategories = const [];
  List<SeriesItem> allSeries = const [];
  String? selectedSeriesCategoryId;
  bool seriesCatalogReady = false;
  String? seriesError;
  SeriesItem? seriesDetailItem;
  SeriesCatalog? seriesCatalog;
  SeriesEpisode? nowPlayingEpisode;
  SeriesItem? nowPlayingSeries;
  final Map<int, SeriesCatalog> _seriesInfoCache = {};

  /// Ordered favorite keys for the current [favoritesScope].
  List<String> _favoriteKeys = const [];

  /// Hidden provider category ids for the current scope.
  Set<String> _hiddenCategoryIds = {};

  /// Real HTTP Xtream provider (not demo, not forced mock, not M3U).
  bool get isLiveProvider => !useDemo && !mockCatalog && !useM3u;

  /// Saved playlists / panels (local; survives sign-out).
  List<SavedSource> get savedSources => _settings.savedSources();

  String? get activeSourceId => _settings.activeSourceId;

  Future<void> removeSavedSource(String id) async {
    await _settings.removeSavedSource(id);
    notifyListeners();
  }

  /// Connect a previously saved source without retyping credentials.
  Future<void> openSavedSource(SavedSource source) async {
    try {
      await stopPlayback(notify: false);
    } catch (_) {}
    switch (source.kind) {
      case SavedSourceKind.demo:
        await connectDemo(save: true);
      case SavedSourceKind.m3u:
        final url = source.m3uUrl?.trim() ?? '';
        if (url.isEmpty) {
          errorMessage = 'Saved M3U has no URL.';
          phase = SessionPhase.login;
          notifyListeners();
          return;
        }
        await connectM3u(url, save: true);
      case SavedSourceKind.xtream:
        final creds = source.credentials;
        if (creds == null) {
          errorMessage = 'Saved Xtream entry is incomplete.';
          phase = SessionPhase.login;
          notifyListeners();
          return;
        }
        await connectRemote(creds, save: true);
    }
  }

  Future<void> _rememberSavedSource(SavedSource source) async {
    try {
      await _settings.upsertSavedSource(source);
    } catch (e) {
      debugPrint('sdtv: upsertSavedSource failed: $e');
    }
  }

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

  /// Persist last played for relaunch (guide category + channel key).
  ///
  /// Saves the **guide column you were in** — so ★ Favorites stays Favorites
  /// on reopen, not a jump into the provider category (e.g. US MOVIES).
  Future<void> rememberLastPlayed(LiveChannel channel) async {
    // Prefer current guide selection (including virtual ★ Favorites).
    // During a watch/zap session this is still the list you started from.
    String catId;
    final sel = selectedCategoryId;
    if (sel == kFavoritesCategoryId) {
      catId = kFavoritesCategoryId;
    } else if (sel != null &&
        sel.isNotEmpty &&
        (sel == kFavoritesCategoryId ||
            categories.any((c) => c.categoryId == sel))) {
      catId = sel;
    } else {
      catId = channel.categoryId.trim();
    }
    if (catId.isEmpty) {
      catId = channel.categoryId.trim();
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
    final lastCat = lastPlayedCategoryId;
    debugPrint(
      'sdtv: lastPlayed apply scope=$prefsScope cat=$lastCat '
      'key=$lastPlayedFavoriteKey id=$lastPlayedStreamId name=$lastPlayedName '
      'resolved=${ch?.name} catId=${ch?.categoryId}',
    );
    if (ch == null) {
      if (lastCat != null &&
          lastCat.isNotEmpty &&
          (lastCat == kFavoritesCategoryId ||
              categories.any((c) => c.categoryId == lastCat))) {
        selectedCategoryId = lastCat;
        return true;
      }
      return false;
    }

    // Honor saved guide position first (★ Favorites vs provider category).
    if (lastCat == kFavoritesCategoryId) {
      // Still favorited → resume in ★ Favorites with that channel focused.
      if (isFavorite(ch)) {
        selectedCategoryId = kFavoritesCategoryId;
        return true;
      }
      // Unstarred since last play → fall through to provider category.
    } else if (lastCat != null &&
        lastCat.isNotEmpty &&
        categories.any((c) => c.categoryId == lastCat) &&
        !_hiddenCategoryIds.contains(lastCat)) {
      selectedCategoryId = lastCat;
      return true;
    }

    // Fallbacks: provider category, then any known cat, then favorites if starred.
    if (ch.categoryId.isNotEmpty &&
        categories.any((c) => c.categoryId == ch.categoryId) &&
        !_hiddenCategoryIds.contains(ch.categoryId)) {
      selectedCategoryId = ch.categoryId;
      return true;
    }
    if (isFavorite(ch)) {
      selectedCategoryId = kFavoritesCategoryId;
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

  /// True when the menu is the stall/error sheet (Retry / Back), not pause.
  bool watchStallOpen = false;

  Timer? _stallWatch;
  DateTime? _stallSince;
  double? _lastStallPos;
  bool _sawPlaybackClock = false;
  String? _stallKind;
  static const _stallAfter = Duration(seconds: 15);

  /// Short EPG cache (streamId → listing). Cleared on source switch / sign-out.
  final Map<int, ShortEpg> _shortEpgCache = {};
  static const _shortEpgTtl = Duration(minutes: 12);
  final Map<int, ShortEpg> _fullEpgCache = {};
  static const _fullEpgTtl = Duration(minutes: 45);
  int _miniGuideGen = 0;

  /// Order of rows in the watch menu OSD.
  static const watchMenuItems = <String>[
    'resume',
    'subtitles',
    'audio',
    'mute',
    'guide',
  ];

  static const _stallMenuItems = <String>[
    'retry',
    'guide',
  ];

  static const _vodMenuItems = <String>[
    'resume',
    'seekBack',
    'seekFwd',
    'subtitles',
    'audio',
    'mute',
    'guide',
  ];

  Timer? _vodProgressWatch;

  /// External watch session active (mpv running or handoff in progress).
  ///
  /// Use for **player** pad routing (pause/quit/zap/vol). Do **not** freeze
  /// the whole browse UI with this — menu / Cancel must always work.
  bool get isWatchingExternal => _watchInFlight || externalMpv.isRunning;

  /// Docked mid-session with Gamescope still at handheld nest size.
  /// Full sdtv relaunch from Steam is required for Native TV resolution.
  bool get needsAppRestartForFullDisplay =>
      externalMpv.needsAppRestartForFullDisplay;

  void clearDisplayRestartHint() {
    externalMpv.needsAppRestartForFullDisplay = false;
  }

  /// True when pad should drive the watch menu, not zap/volume.
  bool get isWatchMenuActive => isWatchingExternal && watchMenuOpen;

  bool get moviesAvailable =>
      !useM3u || mockCatalog || useDemo || vodCategories.isNotEmpty;

  bool get seriesAvailable =>
      !useM3u || mockCatalog || useDemo || seriesCategories.isNotEmpty;

  List<MediaCategory> get browseVodCategories {
    final hidden = _hiddenCategoryIds;
    return vodCategories.where((c) => !hidden.contains(c.categoryId)).toList();
  }

  int vodResumeSeconds(VodItem item) =>
      _settings.vodProgressSeconds(prefsScope, item.favoriteKey);

  List<MediaCategory> get browseSeriesCategories {
    final hidden = _hiddenCategoryIds;
    return seriesCategories
        .where((c) => !hidden.contains(c.categoryId))
        .toList();
  }

  List<SeriesItem> get seriesInCategory {
    final id = selectedSeriesCategoryId;
    if (id == null || id.isEmpty) return allSeries;
    return allSeries.where((s) => s.categoryId == id).toList();
  }

  List<VodItem> get vodInCategory {
    final id = selectedVodCategoryId;
    if (id == null || id.isEmpty) return allVod;
    return allVod.where((v) => v.categoryId == id).toList();
  }

  String get _nowPlayingLabel {
    final ep = nowPlayingEpisode;
    final show = nowPlayingSeries;
    if (ep != null && show != null) {
      return '${show.name}  S${ep.season}E${ep.episodeNum}';
    }
    final vod = nowPlayingVod;
    if (vod != null) return vod.name;
    final ch = nowPlaying;
    if (ch == null) return watchingVod ? 'Movie' : 'Live';
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
    // Cancel in-flight mini-guide so "No EPG…" cannot overwrite the menu.
    _miniGuideGen++;
    watchMenuOpen = true;
    watchMenuIndex = 0;
    // Live IPTV: do **not** enable mpv OSC — its seek bar rewinds the live
    // cache (old segment / wrong audio). Text menu only.
    await externalMpv.setOscVisible(false);
    await externalMpv.setPaused(true);
    // Recover audio if a previous menu pass left aid=no (silent channel).
    await externalMpv.ensureAudioOn();
    await _paintWatchMenu();
    notifyListeners();
  }

  /// Close menu. [resume] unpauses at the **live edge** (reload), not old buffer.
  Future<void> watchCloseMenu({bool resume = false}) async {
    if (!isWatchingExternal) return;
    watchMenuOpen = false;
    watchStallOpen = false;
    watchMenuIndex = 0;
    await externalMpv.setOscVisible(false);
    if (resume) {
      if (watchingVod) {
        await externalMpv.setPaused(false);
      } else {
        // Pausing live HLS/TS keeps a sliding window; unpause alone often
        // continues mid-buffer (loops older segment, weird audio). Jump to edge.
        await externalMpv.resumeLiveEdge(title: _nowPlayingLabel);
        unawaited(
          showMiniGuide(
            channel: nowPlaying,
            channelLineFirst: false,
            durationMs: 3500,
          ),
        );
      }
    } else {
      await externalMpv.hideChromeOverlay();
      await externalMpv.showLiveBanner(
        title: watchingVod ? _nowPlayingLabel : _nowPlayingLabel,
        nowLine: 'Paused',
        hint: watchingVod
            ? 'A menu  ·  B movies  ·  ←→ seek'
            : 'A menu  ·  B guide  ·  LB/RB ch  ·  ↑↓ vol',
        durationMs: 2500,
      );
    }
    notifyListeners();
  }

  Future<void> watchMenuMove(int delta) async {
    if (!isWatchMenuActive) return;
    final items = watchStallOpen
        ? _stallMenuItems
        : (watchingVod ? _vodMenuItems : watchMenuItems);
    final n = items.length;
    watchMenuIndex = (watchMenuIndex + delta) % n;
    if (watchMenuIndex < 0) watchMenuIndex += n;
    await _paintWatchMenu();
    notifyListeners();
  }

  /// ←/→ on a row: cycle value (subs / audio) or no-op.
  Future<void> watchMenuAdjust(int delta) async {
    if (!isWatchMenuActive || watchStallOpen) return;
    if (watchingVod) {
      await externalMpv.seekBy(Duration(seconds: delta > 0 ? 10 : -10));
      await _paintWatchMenu();
      return;
    }
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
    if (watchStallOpen) {
      final id = _stallMenuItems[watchMenuIndex.clamp(0, _stallMenuItems.length - 1)];
      if (id == 'retry') {
        await watchRetryStream();
      } else {
        await watchQuit();
      }
      return;
    }
    final items = watchingVod ? _vodMenuItems : watchMenuItems;
    final id = items[watchMenuIndex.clamp(0, items.length - 1)];
    switch (id) {
      case 'resume':
        await externalMpv.ensureAudioOn();
        await watchCloseMenu(resume: true);
      case 'seekBack':
        await externalMpv.seekBy(const Duration(seconds: -10));
        await _paintWatchMenu();
      case 'seekFwd':
        await externalMpv.seekBy(const Duration(seconds: 10));
        await _paintWatchMenu();
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
    if (watchStallOpen) {
      await _paintStallMenu();
      return;
    }
    if (watchingVod) {
      await _paintVodMenu();
      return;
    }
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
    await externalMpv.showChromeOverlay(
      watchMenuAss(
        title: _nowPlayingLabel,
        rows: rows,
        selected: watchMenuIndex,
      ),
      fallbackText: buf.toString(),
    );
  }

  Future<void> _paintStallMenu() async {
    const rows = ['Retry', 'Back to guide'];
    final idx = watchMenuIndex.clamp(0, rows.length - 1);
    final reason = externalMpv.playError(stallKind: _stallKind).line;
    final buf = StringBuffer('$reason\n$_nowPlayingLabel\n\n');
    for (var i = 0; i < rows.length; i++) {
      final mark = i == idx ? '▶ ' : '   ';
      buf.writeln('$mark${rows[i]}');
    }
    buf.write('A select · B guide');
    await externalMpv.showChromeOverlay(
      watchMenuAss(
        title: '$reason · $_nowPlayingLabel',
        rows: rows,
        selected: idx,
        hint: 'A select  ·  B guide',
      ),
      fallbackText: buf.toString(),
    );
  }

  static String _fmtDur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  Future<void> _paintVodMenu() async {
    final pos = await externalMpv.timePos();
    final dur = await externalMpv.duration();
    final sub = await externalMpv.subtitleLabel();
    final aud = await externalMpv.audioLabel();
    final muted = await externalMpv.getProperty('mute');
    final muteLabel =
        (muted == true || muted == 'yes') ? 'On' : 'Off';
    final timeLine = dur.inSeconds > 0
        ? '${_fmtDur(pos)} / ${_fmtDur(dur)}'
        : _fmtDur(pos);
    final rows = <String>[
      'Resume',
      '−10 seconds',
      '+10 seconds',
      'Subtitles: $sub',
      'Audio: $aud',
      'Mute: $muteLabel',
      'Back to movies',
    ];
    final buf = StringBuffer('❚❚  $_nowPlayingLabel\n$timeLine\n');
    for (var i = 0; i < rows.length; i++) {
      final mark = i == watchMenuIndex ? '▶ ' : '   ';
      buf.writeln('$mark${rows[i]}');
    }
    buf.write('↑↓ move · A select · ←→ seek 10s · B movies');
    await externalMpv.showChromeOverlay(
      watchMenuAss(
        title: '$_nowPlayingLabel  $timeLine',
        rows: rows,
        selected: watchMenuIndex,
        hint: '↑↓ move  ·  A select  ·  ←→ seek  ·  B movies',
      ),
      fallbackText: buf.toString(),
    );
  }

  void _startVodProgressWatch() {
    _stopVodProgressWatch();
    _vodProgressWatch = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_saveVodProgress());
    });
  }

  void _stopVodProgressWatch() {
    _vodProgressWatch?.cancel();
    _vodProgressWatch = null;
  }

  Future<void> _saveVodProgress() async {
    if (!watchingVod) return;
    try {
      final pos = await externalMpv.timePos();
      final ep = nowPlayingEpisode;
      final show = nowPlayingSeries;
      if (ep != null) {
        await _settings.setVodProgressSeconds(
          prefsScope,
          ep.progressKey,
          pos.inSeconds,
        );
        if (show != null) {
          await _settings.setSeriesResume(
            prefsScope,
            seriesId: '${show.seriesId}',
            episodeId: ep.id,
            season: ep.season,
            episodeNum: ep.episodeNum,
          );
        }
        return;
      }
      final item = nowPlayingVod;
      if (item == null) return;
      await _settings.setVodProgressSeconds(
        prefsScope,
        item.favoriteKey,
        pos.inSeconds,
      );
    } catch (e) {
      debugPrint('sdtv: vod progress save: $e');
    }
  }

  Future<void> seekVodBy(Duration delta) async {
    if (!watchingVod || !isWatchingExternal) return;
    await externalMpv.seekBy(delta);
  }

  void _startStallWatch() {
    _stopStallWatch();
    _stallSince = null;
    _lastStallPos = null;
    _sawPlaybackClock = false;
    _stallKind = null;
    _stallWatch = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollStall());
    });
  }

  void _stopStallWatch() {
    _stallWatch?.cancel();
    _stallWatch = null;
    _stallSince = null;
    _lastStallPos = null;
    _sawPlaybackClock = false;
  }

  Future<void> _pollStall() async {
    if (!isWatchingExternal || !externalMpv.isRunning) return;
    if (watchStallOpen) {
      // Keep the error OSD from timing out.
      if (_stallSince != null &&
          DateTime.now().difference(_stallSince!) >
              const Duration(seconds: 8)) {
        _stallSince = DateTime.now();
        await _paintStallMenu();
      }
      return;
    }
    if (watchMenuOpen || _zapInFlight) {
      _stallSince = null;
      return;
    }

    final stalled = await _looksStalled();
    if (!stalled) {
      _stallSince = null;
      return;
    }
    _stallSince ??= DateTime.now();
    if (DateTime.now().difference(_stallSince!) < _stallAfter) return;
    await _openStallMenu();
  }

  Future<bool> _looksStalled() async {
    if (await externalMpv.isPaused()) return false;

    final cache = await externalMpv.getProperty('paused-for-cache');
    if (cache == true || cache == 'yes') {
      _stallKind = 'cache';
      return true;
    }

    final eof = await externalMpv.getProperty('eof-reached');
    if (eof == true || eof == 'yes') {
      _stallKind = 'eof';
      return true;
    }

    final idle = await externalMpv.getProperty('idle-active');
    if (idle == true || idle == 'yes') {
      _stallKind = 'idle';
      return true;
    }

    final coreIdle = await externalMpv.getProperty('core-idle');
    if (coreIdle == true || coreIdle == 'yes') {
      _stallKind = 'core-idle';
      return true;
    }

    final raw = await externalMpv.getProperty('time-pos');
    final pos = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (pos != null) {
      final last = _lastStallPos;
      _lastStallPos = pos;
      if (last == null) return false;
      if ((pos - last).abs() >= 0.35) {
        _sawPlaybackClock = true;
        return false;
      }
      // Many live feeds report a frozen clock while video is fine.
      // Only treat a stuck clock as death after we have seen it move.
      if (_sawPlaybackClock) {
        _stallKind = 'clock';
        return true;
      }
      return false;
    }
    return false;
  }

  Future<void> _openStallMenu() async {
    if (!isWatchingExternal || watchMenuOpen) return;
    debugPrint('sdtv: stream stall ≥${_stallAfter.inSeconds}s — error menu');
    _miniGuideGen++;
    watchMenuOpen = true;
    watchStallOpen = true;
    watchMenuIndex = 0;
    await externalMpv.setOscVisible(false);
    await _paintStallMenu();
    notifyListeners();
  }

  /// Reload the current live URL (or HLS fallback) after a stall.
  Future<void> watchRetryStream() async {
    if (!isWatchingExternal) return;
    watchStallOpen = false;
    watchMenuOpen = false;
    watchMenuIndex = 0;
    _stallSince = null;
    _lastStallPos = null;
    _sawPlaybackClock = false;
    notifyListeners();

    final ch = nowPlaying;
    await externalMpv.showText('Retrying…', durationMs: 1500);
    await externalMpv.resumeLiveEdge(title: _nowPlayingLabel);
    final fallback = ch == null ? null : resolvePlayUriFallback(ch);
    final ok = await externalMpv.ensureHealthyOrShowError(
      fallback,
      title: _nowPlayingLabel,
      grace: const Duration(milliseconds: 1800),
    );
    if (ok) {
      unawaited(
        showMiniGuide(channel: ch, channelLineFirst: false, durationMs: 3000),
      );
    } else if (isWatchingExternal) {
      await _openStallMenu();
    }
  }

  /// B while watching: close menu first, else quit to guide.
  Future<void> watchBack() async {
    if (!isWatchingExternal) return;
    if (watchStallOpen) {
      await watchQuit();
      return;
    }
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
    _stopStallWatch();
    watchMenuOpen = false;
    watchStallOpen = false;
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
  /// TiviMate-style: try `.ts` then `.m3u8` on **this** channel only.
  /// On failure, **stay** and show an error (HTTP 403, etc.) — no auto-skip.
  Future<void> watchChannelAdjacent(int delta) async {
    if (watchingVod) {
      await seekVodBy(Duration(seconds: delta > 0 ? 10 : -10));
      return;
    }
    if (!isWatchingExternal || _watchList.isEmpty) return;
    if (watchMenuOpen) return; // menu / stall owns the pad
    if (_zapInFlight) return;
    _stallSince = null;
    _lastStallPos = null;
    _sawPlaybackClock = false;
    final now = DateTime.now();
    if (_lastZapAt != null &&
        now.difference(_lastZapAt!) < const Duration(milliseconds: 280)) {
      return;
    }
    _lastZapAt = now;

    if (_watchList.length == 1) {
      final only = _watchList[0];
      final healthy = await _zapLoadChannel(only, announce: '→');
      if (healthy) {
        unawaited(
          showMiniGuide(
            channel: only,
            prefix: '→',
            channelLineFirst: false,
          ),
        );
      }
      return;
    }

    var i = (_watchIndex + delta) % _watchList.length;
    if (i < 0) i += _watchList.length;
    if (i == _watchIndex) return;

    final ch = _watchList[i];
    _watchIndex = i;
    nowPlaying = ch;
    notifyListeners();

    _zapInFlight = true;
    try {
      final healthy = await _zapLoadChannel(ch, announce: '→');
      if (healthy) {
        unawaited(rememberLastPlayed(ch));
        // Mini guide (now/next) — channel name already shown during load.
        unawaited(
          showMiniGuide(
            channel: ch,
            prefix: '→',
            channelLineFirst: false,
          ),
        );
      }
      // If not healthy, we already showed an error OSD and stay on this channel.
    } finally {
      _zapInFlight = false;
    }
  }

  /// Load one channel during zap: primary URL, then HLS; fail-and-stay on error.
  Future<bool> _zapLoadChannel(
    LiveChannel ch, {
    required String announce,
  }) async {
    final uri = resolvePlayUri(ch);
    final label = ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;
    if (uri == null) {
      await externalMpv.showText(
        'No URL\n$label\nB guide · LB/RB other channel',
        durationMs: 4000,
      );
      return false;
    }

    final fallback = resolvePlayUriFallback(ch);
    externalMpv.clearRecentLog();
    // Brief channel name while stream loads; full mini guide paints after healthy.
    await externalMpv.showText('$announce $label', durationMs: 1600);
    final ok = await externalMpv.loadFile(uri, title: label);
    if (!ok) {
      debugPrint('sdtv: zap loadfile failed for ${ch.name}');
      if (fallback != null) {
        await externalMpv.loadFile(fallback, title: label);
      } else {
        await externalMpv.showPlaybackError(channelName: label);
        return false;
      }
    }

    return externalMpv.ensureHealthyOrShowError(
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

  // —— Short EPG (now / next mini guide) ——

  void _clearShortEpgCache() {
    _shortEpgCache.clear();
    _fullEpgCache.clear();
    _miniGuideGen++;
  }

  bool _epgFresh(ShortEpg hit, Duration ttl) {
    final fetched = hit.fetchedAt;
    if (fetched == null) return true;
    return DateTime.now().difference(fetched) <= ttl;
  }

  /// Cached short EPG if still fresh (no network).
  ShortEpg? cachedShortEpg(LiveChannel channel) {
    if (channel.streamId == 0 && !mockCatalog && !useDemo) return null;
    final full = _fullEpgCache[channel.streamId];
    if (full != null && _epgFresh(full, _fullEpgTtl)) return full;
    final hit = _shortEpgCache[channel.streamId];
    if (hit == null) return null;
    if (!_epgFresh(hit, _shortEpgTtl)) return null;
    return hit;
  }

  /// Cached full TV Guide listings (simple data table), if fresh.
  ShortEpg? cachedFullEpg(LiveChannel channel) {
    if (channel.streamId == 0 && !mockCatalog && !useDemo) return null;
    final hit = _fullEpgCache[channel.streamId];
    if (hit == null) return null;
    if (!_epgFresh(hit, _fullEpgTtl)) return null;
    return hit;
  }

  /// One-line "now" under a channel name (null if unknown / M3U without EPG).
  String? shortEpgSubtitle(LiveChannel channel) {
    final epg = cachedShortEpg(channel);
    return epg?.guideSubtitle();
  }

  /// Fetch short EPG for [channel] (Xtream / demo). M3U returns empty.
  ///
  /// Uses a short in-memory TTL cache. Safe to call often (focus changes).
  Future<ShortEpg?> fetchShortEpg(
    LiveChannel channel, {
    bool force = false,
  }) async {
    if (useM3u) return null;
    final id = channel.streamId;
    // Demo/mock always has synthetic EPG even for odd ids.
    if (id == 0 && !mockCatalog && !useDemo) return null;

    if (!force) {
      final cached = cachedShortEpg(channel);
      if (cached != null) return cached;
    }

    final client = _client;
    if (client == null) return null;

    try {
      final epg = await client.getShortEpg(id == 0 ? 1 : id, limit: 4);
      // Key by real stream id when non-zero so cache maps to the channel.
      final stored = ShortEpg(
        streamId: id == 0 ? epg.streamId : id,
        listings: epg.listings,
        fetchedAt: epg.fetchedAt ?? DateTime.now(),
      );
      if (id != 0) {
        _shortEpgCache[id] = stored;
      } else if (mockCatalog || useDemo) {
        _shortEpgCache[stored.streamId] = stored;
      }
      notifyListeners();
      return stored;
    } catch (e) {
      debugPrint('sdtv: short EPG failed for ${channel.name}: $e');
      return null;
    }
  }

  /// Prefetch now/next for a few channels (guide focus neighborhood).
  void prefetchShortEpgAround(List<LiveChannel> channels, int focusIndex) {
    if (useM3u || _client == null) return;
    if (channels.isEmpty) return;
    final start = (focusIndex - 2).clamp(0, channels.length - 1);
    final end = (focusIndex + 4).clamp(0, channels.length - 1);
    for (var i = start; i <= end; i++) {
      final ch = channels[i];
      if (cachedShortEpg(ch) != null) continue;
      unawaited(fetchShortEpg(ch));
    }
  }

  /// Fetch a longer EPG table for the TV Guide grid.
  ///
  /// Tries Xtream `get_simple_data_table`, then `get_short_epg`. M3U is empty.
  Future<ShortEpg?> fetchFullEpg(
    LiveChannel channel, {
    bool force = false,
  }) async {
    if (useM3u) return null;
    final id = channel.streamId;
    if (id == 0 && !mockCatalog && !useDemo) return null;

    if (!force) {
      final cached = cachedFullEpg(channel);
      if (cached != null) return cached;
    }

    final client = _client;
    if (client == null) return null;

    final sid = id == 0 ? 1 : id;
    ShortEpg? stored;
    try {
      var epg = await client.getSimpleEpg(sid);
      if (epg.isEmpty) {
        epg = await client.getShortEpg(sid, limit: 12);
      }
      stored = ShortEpg(
        streamId: id == 0 ? epg.streamId : id,
        listings: epg.listings,
        fetchedAt: epg.fetchedAt ?? DateTime.now(),
      );
    } catch (e) {
      debugPrint('sdtv: simple EPG failed for ${channel.name}: $e');
      try {
        final epg = await client.getShortEpg(sid, limit: 12);
        stored = ShortEpg(
          streamId: id == 0 ? epg.streamId : id,
          listings: epg.listings,
          fetchedAt: epg.fetchedAt ?? DateTime.now(),
        );
      } catch (e2) {
        debugPrint('sdtv: short EPG fallback failed for ${channel.name}: $e2');
        return null;
      }
    }

    if (id != 0) {
      _fullEpgCache[id] = stored;
      _shortEpgCache[id] = stored;
    } else if (mockCatalog || useDemo) {
      _fullEpgCache[stored.streamId] = stored;
      _shortEpgCache[stored.streamId] = stored;
    }
    notifyListeners();
    return stored;
  }

  /// Prefetch full EPG for the TV Guide neighborhood (heavier than now/next).
  void prefetchFullEpgAround(List<LiveChannel> channels, int focusIndex) {
    if (useM3u || _client == null) return;
    if (channels.isEmpty) return;
    final start = (focusIndex - 3).clamp(0, channels.length - 1);
    final end = (focusIndex + 8).clamp(0, channels.length - 1);
    for (var i = start; i <= end; i++) {
      final ch = channels[i];
      if (cachedFullEpg(ch) != null) continue;
      unawaited(fetchFullEpg(ch));
    }
  }

  /// TiviMate-style mini guide OSD on mpv (channel + now + next).
  ///
  /// [channelLineFirst] flashes the channel name while the EPG request is in
  /// flight (skip when the zap path already showed the name).
  Future<void> showMiniGuide({
    LiveChannel? channel,
    String? prefix,
    int durationMs = 5000,
    bool channelLineFirst = true,
  }) async {
    final ch = channel ?? nowPlaying;
    if (ch == null || !isWatchingExternal) return;
    if (watchMenuOpen) return;

    final gen = ++_miniGuideGen;
    final label = ch.num > 0 ? '${ch.num}. ${ch.name}' : ch.name;

    final heading = prefix != null ? '$prefix $label' : label;
    if (channelLineFirst) {
      await externalMpv.showLiveBanner(
        title: heading,
        durationMs: 1400,
      );
    }

    final epg = await fetchShortEpg(ch);
    if (gen != _miniGuideGen) return; // newer zap won
    if (!isWatchingExternal || watchMenuOpen) return;
    if (nowPlaying?.favoriteKey != ch.favoriteKey) return;

    if (epg == null || epg.isEmpty) {
      // M3U has no Xtream short EPG — keep the simple channel banner only.
      // Never flash "No EPG" as a scary error (looked like pause/menu broke).
      if (!channelLineFirst) {
        await externalMpv.showLiveBanner(
          title: heading,
          durationMs: 2200,
        );
      }
      return;
    }

    final when = DateTime.now();
    final now = epg.nowAt(when);
    final next = epg.nextAt(when);
    String? nowLine;
    String? nextLine;
    String clip(String s) {
      final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      return t.length <= 48 ? t : '${t.substring(0, 47)}…';
    }

    if (now != null) {
      nowLine = 'NOW  ${now.timeRangeLabel()}  ${clip(now.title)}';
    }
    if (next != null) {
      nextLine = 'NEXT ${next.startTimeLabel()}  ${clip(next.title)}';
    }
    await externalMpv.showLiveBanner(
      title: heading,
      nowLine: nowLine,
      nextLine: nextLine,
      durationMs: durationMs,
    );
  }

  /// After stream is up: wait for IPC + first health pass, then mini guide.
  Future<void> _showMiniGuideWhenReady(LiveChannel channel) async {
    for (var i = 0; i < 25; i++) {
      if (!isWatchingExternal) return;
      if (externalMpv.isRunning) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // After hint + health grace. Don't pile EPG HTTP on the panel at the
    // same moment as the 2s stream health check (one-line accounts blip).
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    if (!isWatchingExternal || watchMenuOpen) return;
    if (nowPlaying?.favoriteKey != channel.favoriteKey) return;
    await showMiniGuide(channel: channel, channelLineFirst: true);
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
      if (save) {
        await _rememberSavedSource(SavedSource.demo());
      }
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
      _clearShortEpgCache();
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
      applyGuideLanding();
      if (save) {
        await _rememberSavedSource(SavedSource.m3u(url: m3uPlaylistUrl!));
      }
      phase = SessionPhase.browse;
      vodCatalogReady = true;
      vodError = 'Movies need an Xtream panel (not M3U).';
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
    _clearShortEpgCache();
    // Save credentials first so [prefsScope] matches while loading last-played.
    if (save) {
      await _settings.saveSession(
        useDemo: useDemo,
        useM3u: false,
        credentials: credentials,
      );
    }
    _reloadGuidePrefs();
    applyGuideLanding();

    if (save && credentials != null && !useDemo && !mockCatalog) {
      await _rememberSavedSource(
        SavedSource.xtream(credentials: credentials),
      );
    }

    phase = SessionPhase.browse;
    notifyListeners();
    unawaited(loadVodCatalog());
    unawaited(loadSeriesCatalog());
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

  /// Cold start: last LIVE/MOVIES tab, not last-played / last-search category.
  /// Live always opens on ★ Favorites (or first visible). Movies restores
  /// the last VOD category you were actually browsing.
  void applyGuideLanding() {
    final m = _settings.guideLanding(prefsScope);
    final section = m['section'];
    if (section == 'movies' && !useM3u) {
      guideSection = GuideSection.movies;
    } else if (section == 'series' && !useM3u) {
      guideSection = GuideSection.series;
    } else {
      guideSection = GuideSection.live;
    }
    selectedCategoryId = _defaultCategoryId(categories);
    _applySavedVodCategory(m['vodCategoryId']);
    _applySavedSeriesCategory(m['seriesCategoryId']);
    debugPrint(
      'sdtv: guide landing section=${guideSection.name} '
      'liveCat=$selectedCategoryId vodCat=$selectedVodCategoryId '
      'seriesCat=$selectedSeriesCategoryId',
    );
  }

  void _applySavedVodCategory(String? vodId) {
    if (vodId == null || vodId.isEmpty || vodCategories.isEmpty) {
      if (selectedVodCategoryId == null && vodCategories.isNotEmpty) {
        selectedVodCategoryId = vodCategories.first.categoryId;
      }
      return;
    }
    final ok = vodCategories.any(
      (c) =>
          c.categoryId == vodId && !_hiddenCategoryIds.contains(vodId),
    );
    selectedVodCategoryId =
        ok ? vodId : vodCategories.first.categoryId;
  }

  void _applySavedSeriesCategory(String? seriesId) {
    if (seriesId == null || seriesId.isEmpty || seriesCategories.isEmpty) {
      if (selectedSeriesCategoryId == null && seriesCategories.isNotEmpty) {
        selectedSeriesCategoryId = seriesCategories.first.categoryId;
      }
      return;
    }
    final ok = seriesCategories.any(
      (c) =>
          c.categoryId == seriesId && !_hiddenCategoryIds.contains(seriesId),
    );
    selectedSeriesCategoryId =
        ok ? seriesId : seriesCategories.first.categoryId;
  }

  Future<void> rememberGuideLanding() async {
    try {
      final section = switch (guideSection) {
        GuideSection.movies => 'movies',
        GuideSection.series => 'series',
        GuideSection.live => 'live',
      };
      await _settings.setGuideLanding(
        prefsScope,
        section: section,
        vodCategoryId: selectedVodCategoryId,
        seriesCategoryId: selectedSeriesCategoryId,
      );
    } catch (e) {
      debugPrint('sdtv: rememberGuideLanding failed: $e');
    }
  }

  void selectCategory(String categoryId) {
    selectedCategoryId = categoryId;
    notifyListeners();
  }

  void selectVodCategory(String categoryId) {
    selectedVodCategoryId = categoryId;
    notifyListeners();
    unawaited(rememberGuideLanding());
  }

  void selectSeriesCategory(String categoryId) {
    selectedSeriesCategoryId = categoryId;
    notifyListeners();
    unawaited(rememberGuideLanding());
  }

  Future<void> setGuideSection(GuideSection section) async {
    if (guideSection == section) return;
    guideSection = section;
    notifyListeners();
    unawaited(rememberGuideLanding());
    if (section == GuideSection.movies && !vodCatalogReady) {
      await loadVodCatalog();
    }
    if (section == GuideSection.series && !seriesCatalogReady) {
      await loadSeriesCatalog();
    }
  }

  Future<void> loadVodCatalog() async {
    if (useM3u && !useDemo && !mockCatalog) {
      vodCategories = const [];
      allVod = const [];
      vodCatalogReady = true;
      vodError = 'Movies need an Xtream panel (not M3U).';
      notifyListeners();
      return;
    }
    final client = _client;
    if (client == null) {
      vodError = 'No catalog client.';
      notifyListeners();
      return;
    }
    vodError = null;
    notifyListeners();
    try {
      final cats = await client.getVodCategories();
      final items = await client.getVodStreams();
      vodCategories = cats;
      allVod = items;
      vodCatalogReady = true;
      final savedVod = _settings.guideLanding(prefsScope)['vodCategoryId'];
      _applySavedVodCategory(savedVod);
      debugPrint('sdtv: VOD catalog cats=${cats.length} items=${items.length}');
    } catch (e) {
      vodError = e.toString();
      vodCatalogReady = true;
      debugPrint('sdtv: VOD catalog failed: $e');
    }
    notifyListeners();
  }

  Future<void> loadSeriesCatalog() async {
    if (useM3u && !useDemo && !mockCatalog) {
      seriesCategories = const [];
      allSeries = const [];
      seriesCatalogReady = true;
      seriesError = 'TV Shows need an Xtream panel (not M3U).';
      notifyListeners();
      return;
    }
    final client = _client;
    if (client == null) {
      seriesError = 'No catalog client.';
      notifyListeners();
      return;
    }
    seriesError = null;
    notifyListeners();
    try {
      final cats = await client.getSeriesCategories();
      final items = await client.getSeries();
      seriesCategories = cats;
      allSeries = items;
      seriesCatalogReady = true;
      final saved = _settings.guideLanding(prefsScope)['seriesCategoryId'];
      _applySavedSeriesCategory(saved);
      debugPrint(
        'sdtv: series catalog cats=${cats.length} items=${items.length}',
      );
    } catch (e) {
      seriesError = e.toString();
      seriesCatalogReady = true;
      debugPrint('sdtv: series catalog failed: $e');
    }
    notifyListeners();
  }

  Future<void> openSeriesDetail(SeriesItem item) async {
    seriesDetailItem = item;
    vodDetailItem = item.asVodItem;
    final cached = _seriesInfoCache[item.seriesId];
    seriesCatalog = cached;
    vodDetail = cached?.info ?? VodInfo.fromVodItem(item.asVodItem);
    vodDetailLoading = cached == null;
    notifyListeners();
    final client = _client;
    if (client == null) {
      vodDetailLoading = false;
      notifyListeners();
      return;
    }
    try {
      final cat = await client.getSeriesInfo(item.seriesId);
      _seriesInfoCache[item.seriesId] = cat;
      if (seriesDetailItem?.seriesId != item.seriesId) return;
      seriesCatalog = cat;
      vodDetail = cat.info;
    } catch (e) {
      debugPrint('sdtv: getSeriesInfo failed: $e');
    }
    if (seriesDetailItem?.seriesId != item.seriesId) return;
    vodDetailLoading = false;
    notifyListeners();
  }

  Map<String, String> seriesResume(SeriesItem item) =>
      _settings.seriesResume(prefsScope, '${item.seriesId}');

  int episodeProgressSeconds(SeriesEpisode ep) =>
      _settings.vodProgressSeconds(prefsScope, ep.progressKey);

  int episodeProgressById(String episodeId) {
    if (episodeId.isEmpty) return 0;
    return _settings.vodProgressSeconds(prefsScope, 'se:$episodeId');
  }

  Future<String?> watchSeriesEpisode(
    SeriesItem show,
    SeriesEpisode episode, {
    bool fromBeginning = false,
  }) async {
    if (_watchInFlight || externalMpv.isRunning) {
      debugPrint('sdtv: watchSeriesEpisode ignored (already watching)');
      return null;
    }
    watchingVod = true;
    nowPlayingVod = null;
    nowPlaying = null;
    nowPlayingSeries = show;
    nowPlayingEpisode = episode;
    _watchInFlight = true;
    notifyListeners();

    final uri = (useDemo || mockCatalog)
        ? Uri.parse(kDemoPlaybackUri)
        : _client?.seriesPlayUrl(episode);
    if (uri == null) {
      _watchInFlight = false;
      watchingVod = false;
      nowPlayingEpisode = null;
      nowPlayingSeries = null;
      return 'No playable URL for this episode.';
    }

    final saved = episodeProgressSeconds(episode);
    final startAt =
        (!fromBeginning && saved > 15) ? Duration(seconds: saved) : null;
    _startStallWatch();
    _startVodProgressWatch();
    try {
      final result = await externalMpv.playFullscreen(
        uri,
        fallbackTitle: '${show.name} S${episode.season}E${episode.episodeNum}',
        vod: true,
        startAt: startAt,
      );
      await _saveVodProgress();
      if (result.busy) return null;
      if (!result.started) return result.error ?? 'mpv failed to start';
      return null;
    } finally {
      _stopVodProgressWatch();
      _stopStallWatch();
      _watchInFlight = false;
      watchingVod = false;
      nowPlayingEpisode = null;
      nowPlayingSeries = null;
      watchMenuOpen = false;
      watchStallOpen = false;
      notifyListeners();
    }
  }

  Uri? resolveVodPlayUri(VodItem item) {
    if (useDemo || mockCatalog) return Uri.parse(kDemoPlaybackUri);
    return _client?.vodPlayUrl(item);
  }

  Future<void> openVodDetail(VodItem item) async {
    seriesDetailItem = null;
    seriesCatalog = null;
    vodDetailItem = item;
    vodDetail = _vodInfoCache[item.streamId] ?? VodInfo.fromVodItem(item);
    vodDetailLoading = !_vodInfoCache.containsKey(item.streamId);
    notifyListeners();
    final client = _client;
    if (client == null) {
      vodDetailLoading = false;
      notifyListeners();
      return;
    }
    try {
      final info = await client.getVodInfo(item.streamId);
      _vodInfoCache[item.streamId] = info;
      if (vodDetailItem?.streamId != item.streamId) return;
      vodDetail = info;
    } catch (e) {
      debugPrint('sdtv: getVodInfo failed: $e');
    }
    if (vodDetailItem?.streamId != item.streamId) return;
    vodDetailLoading = false;
    notifyListeners();
  }

  void closeVodDetail() {
    vodDetailItem = null;
    vodDetail = null;
    vodDetailLoading = false;
    seriesDetailItem = null;
    seriesCatalog = null;
    notifyListeners();
  }

  Future<String?> watchVod(
    VodItem item, {
    bool fromBeginning = false,
  }) async {
    if (_watchInFlight || externalMpv.isRunning) {
      debugPrint('sdtv: watchVod ignored (already watching)');
      return null;
    }
    watchingVod = true;
    nowPlayingVod = item;
    nowPlaying = null;
    _watchInFlight = true;
    notifyListeners();

    final uri = resolveVodPlayUri(item);
    if (uri == null) {
      _watchInFlight = false;
      watchingVod = false;
      return 'No playable URL for this title.';
    }

    final saved = _settings.vodProgressSeconds(prefsScope, item.favoriteKey);
    final startAt =
        (!fromBeginning && saved > 15) ? Duration(seconds: saved) : null;
    _startStallWatch();
    _startVodProgressWatch();
    try {
      final result = await externalMpv.playFullscreen(
        uri,
        fallbackTitle: item.name,
        vod: true,
        startAt: startAt,
      );
      await _saveVodProgress();
      if (result.busy) return null;
      if (!result.started) return result.error ?? 'mpv failed to start';
      return null;
    } finally {
      _stopVodProgressWatch();
      _stopStallWatch();
      _watchInFlight = false;
      watchingVod = false;
      nowPlayingVod = null;
      watchMenuOpen = false;
      watchStallOpen = false;
      notifyListeners();
    }
  }

  /// YouTube trailers open in the system/YouTube client (TiviMate does this).
  /// Direct HLS/file URLs still go through mpv.
  Future<String?> watchTrailer(VodInfo info) async {
    final uri = info.trailerUri;
    if (uri == null) return 'No trailer for this title.';
    if (info.isYoutubeTrailer) {
      final ok = await openExternalUrl(uri);
      if (ok) return null;
      return 'Could not open YouTube. Try Desktop Mode, or install a browser.';
    }
    if (_watchInFlight || externalMpv.isRunning) {
      debugPrint('sdtv: watchTrailer ignored (already watching)');
      return null;
    }
    watchingVod = true;
    nowPlaying = null;
    nowPlayingVod = null;
    _watchInFlight = true;
    notifyListeners();
    _startStallWatch();
    try {
      final result = await externalMpv.playFullscreen(
        uri,
        fallbackTitle: '${info.title} trailer',
        vod: true,
      );
      if (result.busy) return null;
      if (!result.started) {
        return result.error ?? 'Trailer failed to start';
      }
      return null;
    } finally {
      _stopStallWatch();
      _watchInFlight = false;
      watchingVod = false;
      watchMenuOpen = false;
      watchStallOpen = false;
      notifyListeners();
    }
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
    watchingVod = false;
    nowPlayingVod = null;
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

      // Mini guide once mpv is up (playFullscreen blocks until quit).
      unawaited(_showMiniGuideWhenReady(channel));
      _startStallWatch();

      var result = await externalMpv.playFullscreen(
        uri,
        playlist: entries,
        startIndex: start,
        fallbackUrl: fallback,
        fallbackTitle: channel.name,
      );

      // Process died immediately (mpv rejected .ts) — one restart on .m3u8.
      if (result.failedFast && fallback != null && !result.userQuit) {
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
      // Only bounce a snack if mpv died fast *and* logs look like a real
      // stream error — not Steam "ld.so gameoverlay" noise.
      if (result.failedFast &&
          !result.userQuit &&
          externalMpv.hasMeaningfulStreamError) {
        final hint = externalMpv.playbackErrorHint(channelName: channel.name);
        return hint.split('\n').take(2).join(' · ');
      }
      return null;
    } finally {
      _stopStallWatch();
      _watchInFlight = false;
      nowPlaying = null;
      _watchList = const [];
      _watchIndex = 0;
      watchMenuOpen = false;
      watchStallOpen = false;
      watchMenuIndex = 0;
      notifyListeners();
    }
  }

  /// IPTV-friendly headers for embedded media_kit (matches panel clients).
  static const Map<String, String> _streamHttpHeaders = {
    'User-Agent':
        'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 '
            '(KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3',
  };

  /// Embedded media_kit open (experimental). Prefer [watchChannel]
  /// for daily live TV (external mpv).
  ///
  /// **One URL only** — do not probe .m3u8 then .ts; that double-hits the
  /// panel and can get the account flagged. Texture size is never put on
  /// the stream URL.
  Future<String?> playChannel(LiveChannel channel) async {
    nowPlaying = channel;
    notifyListeners();

    Uri? url;
    if (channel.hasDirectUrl) {
      url = Uri.tryParse(channel.streamUrl!.trim());
    } else if (useDemo || mockCatalog) {
      url = Uri.parse(kDemoPlaybackUri);
    } else {
      url = resolvePlayUri(channel);
    }

    if (url == null) {
      return 'No playable URL for this channel.';
    }

    try {
      await player.stop();
    } catch (_) {}

    debugPrint('sdtv: embed open $url');
    await player.open(url, httpHeaders: _streamHttpHeaders);
    for (var t = 0; t < 15; t++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (player.state == SdtvPlayerState.playing ||
          player.state == SdtvPlayerState.buffering ||
          player.state == SdtvPlayerState.paused) {
        notifyListeners();
        return null;
      }
      if (player.state == SdtvPlayerState.error) break;
    }

    notifyListeners();
    return player.lastError ?? 'Playback failed (embedded)';
  }

  Future<void> playAdjacent(int delta) async {
    // Zap always uses external mpv (smooth). Do not open a second embed
    // stream against the panel.
    if (isWatchingExternal) {
      await watchChannelAdjacent(delta);
      return;
    }
    final list = channelsInCategory;
    if (list.isEmpty) return;
    final idx = nowPlaying == null
        ? 0
        : list.indexWhere((c) => c.streamId == nowPlaying!.streamId);
    final start = idx < 0 ? 0 : idx;
    final next = (start + delta) % list.length;
    final i = next < 0 ? next + list.length : next;
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
    _stopStallWatch();
    _watchInFlight = false;
    nowPlaying = null;
    _watchList = const [];
    _watchIndex = 0;
    watchMenuOpen = false;
    watchStallOpen = false;
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
    vodDetailItem = null;
    vodDetail = null;
    vodDetailLoading = false;
    _vodInfoCache.clear();
    seriesCategories = const [];
    allSeries = const [];
    selectedSeriesCategoryId = null;
    seriesCatalogReady = false;
    seriesError = null;
    seriesDetailItem = null;
    seriesCatalog = null;
    nowPlayingEpisode = null;
    nowPlayingSeries = null;
    _seriesInfoCache.clear();
    _clearShortEpgCache();
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
