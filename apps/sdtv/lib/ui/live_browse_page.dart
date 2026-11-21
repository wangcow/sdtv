import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../build_info.dart';
import '../services/saved_source.dart';
import '../state/session_controller.dart';
import 'epg_grid.dart';
import 'vod_grid.dart';
import 'widgets/epg_guide_pane.dart';
import 'widgets/menu_panels.dart';
import 'widgets/mpv_flutter_hud.dart';
import 'widgets/search_page.dart';
import 'widgets/vod_poster_tile.dart';
import 'widgets/vod_title_pane.dart';

/// Two-column live browser with explicit index navigation (TV / Deck).
class LiveBrowsePage extends StatefulWidget {
  const LiveBrowsePage({super.key, required this.session});

  final SessionController session;

  @override
  State<LiveBrowsePage> createState() => _LiveBrowsePageState();
}

class _LiveBrowsePageState extends State<LiveBrowsePage> {
  final GlobalKey<MpvFlutterHudState> _mpvHudKey =
      GlobalKey<MpvFlutterHudState>();

  /// 0 = categories, 1 = channels / posters
  int _column = 0;

  /// Header LIVE | MOVIES has pad focus.
  bool _sectionFocus = false;
  int _catIndex = 0;
  int _chanIndex = 0;

  /// Last channel row per category id (so ← categories → channels keeps place).
  final Map<String, int> _chanIndexByCategory = {};

  /// Tracks which category [session.selectedCategoryId] the UI index maps to.
  /// Used so [session] notifies don't copy one list's row onto every category.
  String? _indexCategoryId;

  /// Only auto-land on last-played once per page instance.
  bool _didRestoreLanding = false;

  /// In-page menu (no showDialog — avoids stuck modal barriers on Deck).
  bool _menuOpen = false;

  /// Settings page (☰ → Settings). Sub-panels open on top of it.
  bool _settingsOpen = false;
  int _settingsIndex = 0;

  /// Sign out needs a second A within a few seconds.
  bool _signOutArmed = false;
  Timer? _signOutTimer;

  bool _aboutOpen = false;
  bool _manageCatsOpen = false;

  /// Manage categories: the focused category is picked up (↑↓ move it).
  bool _manageMoving = false;
  bool _searchOpen = false;

  /// False while the query field should own the pad (Deck OSK). A/D-pad
  /// must not play or unfocus until the user leaves the field (B / RB).
  bool _searchBrowseResults = false;
  bool _switchSourceOpen = false;
  bool _unfavOpen = false;
  bool _vodDetailOpen = false;
  int _vodDetailAction = 0;
  bool _seriesEpisodesOpen = false;
  DateTime _epgWindowStart = DateTime.now();
  DateTime _epgFocusTime = DateTime.now();
  double _epgProgramWidth = 720;
  Timer? _epgClock;
  int _seasonIndex = 0;
  int _episodeIndex = 0;
  int _menuIndex = 0;
  int _manageIndex = 0;
  /// Search page cursor: row (Live / Movies / TV Shows / Categories) and
  /// the column last used in each row.
  int _searchRow = 0;
  List<int> _searchCols = const [];
  List<SearchRow> _searchRows = const [];
  final _searchListFocus = FocusNode(debugLabel: 'search results');
  int _switchSourceIndex = 0;
  int _unfavIndex = 0;
  String _unfavName = '';
  Future<void> Function()? _unfavRemove;

  final _catScroll = ScrollController();
  final _chanScroll = ScrollController();
  final _manageScroll = ScrollController();
  final _switchScroll = ScrollController();
  final _episodeScroll = ScrollController();
  final _epgScroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  DateTime? _lastNavAt;
  DateTime? _lastFavoriteAt;
  DateTime? _lastPageAt;
  DateTime? _lastMenuAt;
  // Allow accelerated hold-scroll from the joystick reader (~40ms + bursts).
  static const _navCooldown = Duration(milliseconds: 28);

  /// Steam injects PageDown with Y; ignore the page jump that follows a star.
  static const _ignorePageAfterFavorite = Duration(milliseconds: 450);

  /// Deck often double-fires RB as pageDown + ☰/Start (menu first row is Search).
  static const _ignoreMenuAfterPage = Duration(milliseconds: 450);

  /// Fixed row height so scroll offset matches the selected tile (highlight stays on-screen).
  static const _rowExtent = 78.0;

  /// Category column row pitch (compact, TiviMate-style list).
  static const _catRowExtent = 52.0;
  static const _listHeaderExtent = 44.0;

  /// Movies poster grid (LayoutBuilder keeps these in sync with width).
  int _vodCols = 4;
  double _vodRowExtent = 240;

  /// ☰ menu: the essentials. Account / playlist / category tools live in
  /// Settings.
  List<MenuEntry> get _menuEntries {
    final hide = _hideableCategoryName;
    return [
      const MenuEntry('search', Icons.search_rounded, 'Search'),
      const MenuEntry('settings', Icons.settings_outlined, 'Settings'),
      if (hide != null)
        MenuEntry('hide_cat', Icons.visibility_off_outlined, 'Hide “$hide”'),
      const MenuEntry('exit', Icons.power_settings_new_rounded, 'Exit sdtv'),
    ];
  }

  /// Name of the Live category ☰ → Hide would hide, or null when it can't.
  String? get _hideableCategoryName {
    if (!_isLive || session.isWatchingExternal) return null;
    final cats = session.browseCategories;
    if (cats.isEmpty) return null;
    final cat = cats[_catIndex.clamp(0, cats.length - 1)];
    if (cat.categoryId == kFavoritesCategoryId) return null;
    return cat.categoryName;
  }

  List<MenuEntry> get _settingsEntries {
    final sources = session.savedSources;
    String? active;
    for (final src in sources) {
      if (src.id == session.activeSourceId) active = src.label;
    }
    final hidden = session.hiddenCategoryCount;
    final user = session.userInfo?.username ?? 'user';
    return [
      MenuEntry(
        'switch_source',
        Icons.playlist_play_rounded,
        'Switch playlist',
        section: 'Playlist',
        subtitle: session.useDemo
            ? 'Demo playlist'
            : active ??
                  (sources.isEmpty
                      ? 'No saved playlists'
                      : '${sources.length} saved'),
      ),
      MenuEntry(
        'manage_cats',
        Icons.category_outlined,
        'Manage categories',
        section: 'Guide',
        subtitle: hidden == 0
            ? 'Reorder or hide Live categories'
            : 'Reorder or hide · $hidden hidden',
      ),
      MenuEntry(
        'about',
        Icons.info_outline_rounded,
        'About sdtv',
        section: 'About',
        subtitle: SdtvBuildInfo.label,
      ),
      MenuEntry(
        'signout',
        Icons.logout_rounded,
        _signOutArmed ? 'Press A again to sign out' : 'Sign out',
        section: 'Account',
        subtitle: session.useDemo ? 'Demo' : 'Signed in as $user',
        danger: true,
      ),
    ];
  }

  SessionController get session => widget.session;

  bool get _isLive => session.guideSection == GuideSection.live;
  bool get _isMovies => session.guideSection == GuideSection.movies;
  bool get _isSeries => session.guideSection == GuideSection.series;
  bool get _isPosterGuide => _isMovies || _isSeries;

  bool get _overlayOpen =>
      _menuOpen ||
      _settingsOpen ||
      _aboutOpen ||
      _manageCatsOpen ||
      _searchOpen ||
      _switchSourceOpen ||
      _unfavOpen;

  bool _acceptNav() {
    final now = DateTime.now();
    if (_lastNavAt != null && now.difference(_lastNavAt!) < _navCooldown) {
      return false;
    }
    _lastNavAt = now;
    return true;
  }

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    _mpvKeys = session.externalMpv.keyPresses.listen(_onMpvKey);
    _searchCtrl.addListener(_onSearchQueryChanged);
    SdtvTextFocusRegistry.register(_searchFocus);
    _searchFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final k = event.logicalKey;
      // OSK / IME send Tab, Enter, and gamepad A together with the glyph.
      // Never traverse away from the query field on those.
      if (k == LogicalKeyboardKey.tab ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter ||
          k == LogicalKeyboardKey.gameButtonA ||
          k == LogicalKeyboardKey.select) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreGuideLanding();
      _syncEpgClock();
    });
  }

  void _syncEpgClock() {
    if (_isLive) {
      _epgClock ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted && _isLive) setState(() {});
      });
    } else {
      _epgClock?.cancel();
      _epgClock = null;
    }
  }

  /// Land on last LIVE/MOVIES tab. Live opens on ★ Favorites (or first
  /// visible cat), not last-played / last-search. Stay on the category column.
  void _restoreGuideLanding() {
    if (_didRestoreLanding) return;
    final movies = _isMovies;
    final series = _isSeries;
    if (movies) {
      if (!session.vodCatalogReady) return;
    } else if (series) {
      if (!session.seriesCatalogReady) return;
    } else if (session.browseCategories.isEmpty) {
      return;
    }
    _didRestoreLanding = true;

    if (!movies &&
        !series &&
        session.selectedCategoryId == null &&
        session.browseCategories.isNotEmpty) {
      session.selectCategory(session.browseCategories.first.categoryId);
    }

    final cats = movies
        ? session.browseVodCategories
        : series
        ? session.browseSeriesCategories
        : session.browseCategories;
    final sel = movies
        ? session.selectedVodCategoryId
        : series
        ? session.selectedSeriesCategoryId
        : session.selectedCategoryId;
    var catIdx = 0;
    if (sel != null) {
      final i = cats.indexWhere((c) => c.categoryId == sel);
      if (i >= 0) catIdx = i;
    }
    _indexCategoryId = sel;

    debugPrint(
      'sdtv: restore landing section=${session.guideSection.name} '
      'catIdx=$catIdx sel=$sel build=${SdtvBuildInfo.label}',
    );

    setState(() {
      _catIndex = catIdx;
      _chanIndex = 0;
      _column = 0;
      _sectionFocus = false;
      if (!movies && !series) {
        final now = DateTime.now();
        _epgWindowStart = epgSnapDown(now);
        _epgFocusTime = now;
      }
    });
    _syncEpgClock();
    if (!movies && !series) {
      session.prefetchFullEpgAround(session.channelsInCategory, 0);
    }

    if (catIdx > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollTo(
          _catScroll,
          catIdx,
          itemExtent: _catRowExtent,
          headerExtent: _listHeaderExtent,
        );
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _signOutTimer?.cancel();
    unawaited(_mpvKeys?.cancel());
    session.removeListener(_onSession);
    _searchCtrl.removeListener(_onSearchQueryChanged);
    SdtvTextFocusRegistry.unregister(_searchFocus);
    _searchCtrl.dispose();
    _searchFocus.onKeyEvent = null;
    _searchFocus.dispose();
    _catScroll.dispose();
    _chanScroll.dispose();
    _manageScroll.dispose();
    _searchListFocus.dispose();
    _switchScroll.dispose();
    _episodeScroll.dispose();
    _epgScroll.dispose();
    _epgClock?.cancel();
    super.dispose();
  }

  Timer? _searchDebounce;

  void _onSearchQueryChanged() {
    if (!_searchOpen) return;
    // New glyphs = still typing. Re-lock at once so OSK A cannot play a hit.
    if (_searchBrowseResults) setState(() => _searchBrowseResults = false);
    // Search once typing pauses, not on every glyph.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || !_searchOpen) return;
      final hits = session.searchGuide(_searchCtrl.text, maxResults: 300);
      setState(() => _setSearchHits(hits, reset: true));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchOpen || _searchBrowseResults) return;
      if (!_searchFocus.hasFocus) _searchFocus.requestFocus();
    });
  }

  void _onSession() {
    if (!mounted) return;
    // Connect / VOD catalog finished after first frame.
    if (!_didRestoreLanding) {
      if (_isMovies && session.vodCatalogReady) {
        _restoreGuideLanding();
        return;
      }
      if (_isSeries && session.seriesCatalogReady) {
        _restoreGuideLanding();
        return;
      }
      if (!_isPosterGuide && session.browseCategories.isNotEmpty) {
        _restoreGuideLanding();
        return;
      }
    }
    final movies = _isMovies;
    final series = _isSeries;
    final catList = movies
        ? session.browseVodCategories
        : series
        ? session.browseSeriesCategories
        : session.browseCategories;
    final catCount = catList.length;
    final chanCount = movies
        ? session.vodInCategory.length
        : series
        ? session.seriesInCategory.length
        : session.channelsInCategory.length;
    final sel = movies
        ? session.selectedVodCategoryId
        : series
        ? session.selectedSeriesCategoryId
        : session.selectedCategoryId;

    if (catCount > 0) {
      _catIndex = _catIndex.clamp(0, catCount - 1);
      if (sel != null) {
        final i = catList.indexWhere((c) => c.categoryId == sel);
        if (i >= 0) _catIndex = i;
      }
    } else {
      _catIndex = 0;
    }

    // Category changed via session: restore *that* category's saved row.
    // Do NOT write the previous list's _chanIndex into the new category
    // (that made every category share Favorites' row 0/1/2/…).
    if (sel != null && sel != _indexCategoryId) {
      _indexCategoryId = sel;
      _chanIndex = chanCount > 0
          ? (movies
                ? _vodIndexFor(sel, chanCount)
                : series
                ? _seriesIndexFor(sel, chanCount)
                : _chanIndexFor(sel, chanCount))
          : 0;
    } else if (chanCount > 0) {
      _chanIndex = _chanIndex.clamp(0, chanCount - 1);
    } else {
      _chanIndex = 0;
    }

    if (_isLive) {
      session.prefetchFullEpgAround(session.channelsInCategory, _chanIndex);
    }

    if (_seriesEpisodesOpen) {
      final seasons = session.seriesCatalog?.seasons ?? const [];
      if (seasons.isEmpty) {
        _seasonIndex = 0;
        _episodeIndex = 0;
      } else {
        _seasonIndex = _seasonIndex.clamp(0, seasons.length - 1);
        final eps = seasons[_seasonIndex].episodes;
        _episodeIndex = eps.isEmpty
            ? 0
            : _episodeIndex.clamp(0, eps.length - 1);
      }
    }
    if (_searchOpen) {
      _setSearchHits(session.searchGuide(_searchCtrl.text, maxResults: 300));
    }
    setState(() {});
  }

  /// Scroll so [index] is near the top of [c].
  ///
  /// [index] is the **data** index (0 = first channel/result), not the ListView
  /// child index. Pass [headerExtent] when the list has a title row above items.
  void _scrollTo(
    ScrollController c,
    int index, {
    double itemExtent = _rowExtent,
    double headerExtent = 0,
  }) {
    if (!c.hasClients) return;
    final offset = (headerExtent + index * itemExtent).clamp(
      0.0,
      c.position.maxScrollExtent,
    );
    c.animateTo(
      offset,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  /// Keep [index] inside the viewport (only scrolls when the row would leave).
  ///
  /// Prefer this for overlay lists (manage cats / search) so the highlight
  /// stays visible while D-pad scrolling.
  void _ensureIndexVisible(
    ScrollController c,
    int index, {
    double itemExtent = _rowExtent,
    double headerExtent = 0,
  }) {
    if (!c.hasClients) return;
    final max = c.position.maxScrollExtent;
    final viewH = c.position.viewportDimension;
    final itemTop = headerExtent + index * itemExtent;
    final itemBottom = itemTop + itemExtent;
    final viewTop = c.offset;
    final viewBottom = c.offset + viewH;
    double? target;
    if (itemTop < viewTop) {
      target = itemTop;
    } else if (itemBottom > viewBottom) {
      target = itemBottom - viewH;
    }
    if (target == null) return;
    c.animateTo(
      target.clamp(0.0, max),
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  }

  void _scrollToManageIndex(int index) {
    // Defer until after setState so maxScrollExtent is correct.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_manageCatsOpen) return;
      _ensureIndexVisible(
        _manageScroll,
        index,
        itemExtent: ManageCategoriesPage.rowExtent,
        headerExtent: ManageCategoriesPage.listTop,
      );
    });
  }

  void _rememberChanIndex() {
    final id = session.selectedCategoryId ?? _indexCategoryId;
    if (id == null) return;
    _chanIndexByCategory[id] = _chanIndex;
  }

  void _rememberVodIndex() {
    final id = session.selectedVodCategoryId;
    if (id == null) return;
    _chanIndexByCategory['vod:$id'] = _chanIndex;
  }

  int _vodIndexFor(String? categoryId, int listLength) {
    if (categoryId == null || listLength <= 0) return 0;
    final saved = _chanIndexByCategory['vod:$categoryId'];
    if (saved == null) return 0;
    return saved.clamp(0, listLength - 1);
  }

  void _rememberSeriesIndex() {
    final id = session.selectedSeriesCategoryId;
    if (id == null) return;
    _chanIndexByCategory['series:$id'] = _chanIndex;
  }

  int _seriesIndexFor(String? categoryId, int listLength) {
    if (categoryId == null || listLength <= 0) return 0;
    final saved = _chanIndexByCategory['series:$categoryId'];
    if (saved == null) return 0;
    return saved.clamp(0, listLength - 1);
  }

  void _scrollToVodIndex(int index) {
    final cols = _vodCols.clamp(1, kVodGridMaxCols);
    _ensureIndexVisible(
      _chanScroll,
      index ~/ cols,
      itemExtent: _vodRowExtent,
      headerExtent: 0,
    );
  }

  void _syncVodGridMetrics(BoxConstraints constraints) {
    final cols = vodGridCrossAxisCount(constraints.maxWidth);
    final stride = vodGridRowStride(
      gridWidth: constraints.maxWidth,
      cols: cols,
    );
    if (cols == _vodCols && (stride - _vodRowExtent).abs() < 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (cols == _vodCols && (stride - _vodRowExtent).abs() < 0.5) return;
      setState(() {
        _vodCols = cols;
        _vodRowExtent = stride;
      });
    });
  }

  void _enterVodGrid() {
    if (_isSeries) {
      final cats = session.browseSeriesCategories;
      if (cats.isEmpty) return;
      final id =
          session.selectedSeriesCategoryId ??
          cats[_catIndex.clamp(0, cats.length - 1)].categoryId;
      session.selectSeriesCategory(id);
      final n = session.seriesInCategory.length;
      final idx = _seriesIndexFor(id, n);
      setState(() {
        _column = 1;
        _chanIndex = idx;
        _sectionFocus = false;
        _indexCategoryId = id;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToVodIndex(idx);
      });
      return;
    }
    final cats = session.browseVodCategories;
    if (cats.isEmpty) return;
    final id =
        session.selectedVodCategoryId ??
        cats[_catIndex.clamp(0, cats.length - 1)].categoryId;
    session.selectVodCategory(id);
    final n = session.vodInCategory.length;
    final idx = _vodIndexFor(id, n);
    setState(() {
      _column = 1;
      _chanIndex = idx;
      _sectionFocus = false;
      _indexCategoryId = id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToVodIndex(idx);
    });
  }

  void _applyVodGridMove({int dx = 0, int dy = 0}) {
    final n = _isSeries
        ? session.seriesInCategory.length
        : session.vodInCategory.length;
    if (n == 0) return;
    final step = moveVodGrid(
      index: _chanIndex,
      count: n,
      cols: _vodCols,
      dx: dx,
      dy: dy,
    );
    if (step.leaveToCategories) {
      if (_isSeries) {
        _rememberSeriesIndex();
      } else {
        _rememberVodIndex();
      }
      setState(() => _column = 0);
      _scrollTo(
        _catScroll,
        _catIndex,
        itemExtent: _catRowExtent,
        headerExtent: _listHeaderExtent,
      );
      return;
    }
    if (step.index == _chanIndex) return;
    setState(() => _chanIndex = step.index);
    if (_isSeries) {
      _rememberSeriesIndex();
    } else {
      _rememberVodIndex();
    }
    _scrollToVodIndex(step.index);
  }

  /// Restore last channel row for [categoryId] (clamped to list length).
  /// Default is **0** only if this category was never opened — not "same as last cat".
  int _chanIndexFor(String categoryId, int listLength) {
    if (listLength <= 0) return 0;
    final saved = _chanIndexByCategory[categoryId];
    if (saved == null) return 0;
    return saved.clamp(0, listLength - 1);
  }

  /// Switch provider category, keeping each list's remembered position.
  void _selectCategoryKeepingChanPos(String categoryId) {
    // Save row under the category we are *leaving*.
    _rememberChanIndex();
    final prevId = session.selectedCategoryId;
    session.selectCategory(categoryId);
    // selectCategory notifies → _onSession; it restores from map using
    // _indexCategoryId transition. Set explicitly too for clarity.
    final n = session.channelsInCategory.length;
    final idx = _chanIndexFor(categoryId, n);
    _indexCategoryId = categoryId;
    _chanIndex = idx;
    debugPrint(
      'sdtv: cat switch $prevId → $categoryId chanIdx=$idx '
      '(saved=${_chanIndexByCategory[categoryId]})',
    );
    session.prefetchFullEpgAround(session.channelsInCategory, idx);
  }

  void _enterChannelColumn() {
    final id = session.selectedCategoryId;
    final n = session.channelsInCategory.length;
    final idx = id == null ? 0 : _chanIndexFor(id, n);
    _indexCategoryId = id;
    setState(() {
      _column = 1;
      _chanIndex = idx;
    });
    session.prefetchFullEpgAround(session.channelsInCategory, idx);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToEpgIndex(idx);
    });
  }

  void _scrollToEpgIndex(int index) {
    _ensureIndexVisible(_epgScroll, index, itemExtent: kEpgRowExtent);
  }

  void _moveVertical(int delta) {
    // Watching + menu open: D-pad navigates the pause menu (not volume).
    if (session.isWatchMenuActive && !_overlayOpen) {
      unawaited(session.watchMenuMove(delta));
      return;
    }
    // Watching, menu closed: the Flutter HUD owns the d-pad. While it is
    // hidden, ↑↓ is still volume (the bitmap is off, so the text OSD shows).
    if (session.isWatchingExternal && !_overlayOpen) {
      final hud = _mpvHudKey.currentState;
      if (hud != null) {
        hud.vertical(delta);
      } else {
        unawaited(session.watchVolumeDelta(delta < 0 ? 5 : -5));
      }
      return;
    }

    // Overlays own ↑↓. Must run before LIVE/MOVIES header focus, or ↑ from
    // Manage categories (with the first guide category selected) leaks out.
    if (_aboutOpen) return;
    if (_switchSourceOpen) {
      if (!_acceptNav()) return;
      final n = session.savedSources.length;
      if (n == 0) return;
      setState(() {
        _switchSourceIndex = (_switchSourceIndex + delta).clamp(0, n - 1);
      });
      _scrollTo(_switchScroll, _switchSourceIndex, itemExtent: _rowExtent);
      return;
    }
    if (_searchOpen) {
      if (!_searchBrowseResults) {
        // ↓ from the query (keyboard or pad) goes to the results.
        if (delta > 0) _enterSearchResults();
        return;
      }
      if (!_acceptNav()) return;
      if (_searchRows.isEmpty || (delta < 0 && _searchRow <= 0)) {
        _returnToSearchField();
        return;
      }
      setState(() {
        _searchRow = (_searchRow + delta).clamp(0, _searchRows.length - 1);
      });
      return;
    }
    if (_manageCatsOpen) {
      if (!_acceptNav()) return;
      final cats = session.orderedCategories;
      final n = cats.length;
      if (n == 0) return;
      if (_manageMoving) {
        final id = cats[_manageIndex.clamp(0, n - 1)].categoryId;
        final to = session.moveCategory(id, delta);
        if (to < 0) return;
        setState(() => _manageIndex = to);
        _scrollToManageIndex(to);
        return;
      }
      final next = (_manageIndex + delta).clamp(0, n - 1);
      setState(() => _manageIndex = next);
      _scrollToManageIndex(next);
      return;
    }
    if (_unfavOpen) {
      if (!_acceptNav()) return;
      setState(() => _unfavIndex = (_unfavIndex + delta).clamp(0, 1));
      return;
    }
    if (_menuOpen) {
      if (!_acceptNav()) return;
      setState(() {
        // Wraps: ↑ on Search reaches Exit sdtv at the bottom, and back.
        final n = _menuEntries.length;
        _menuIndex = ((_menuIndex + delta) % n + n) % n;
      });
      return;
    }
    if (_settingsOpen) {
      if (!_acceptNav()) return;
      final n = _settingsEntries.length;
      setState(() {
        _settingsIndex = ((_settingsIndex + delta) % n + n) % n;
        _disarmSignOut();
      });
      return;
    }
    if (_seriesEpisodesOpen) {
      if (!_acceptNav()) return;
      _moveSeriesEpisode(delta);
      return;
    }
    if (_vodDetailOpen) {
      if (!_acceptNav()) return;
      final n = _vodDetailActions.length;
      if (n == 0) return;
      setState(() {
        _vodDetailAction = (_vodDetailAction + delta).clamp(0, n - 1);
      });
      return;
    }

    if (_sectionFocus) {
      if (delta > 0) {
        setState(() => _sectionFocus = false);
      }
      return;
    }

    if (!_acceptNav()) return;

    if (delta < 0 && _column == 0 && _catIndex == 0) {
      setState(() => _sectionFocus = true);
      return;
    }

    final movies = _isMovies;
    final series = _isSeries;
    final cats = movies
        ? session.browseVodCategories
        : series
        ? session.browseSeriesCategories
        : session.browseCategories;

    if (_column == 0) {
      if (cats.isEmpty) return;
      setState(() {
        _catIndex = (_catIndex + delta).clamp(0, cats.length - 1);
      });
      if (movies) {
        final prev = session.selectedVodCategoryId;
        if (prev != null) _chanIndexByCategory['vod:$prev'] = _chanIndex;
        final id = cats[_catIndex].categoryId;
        session.selectVodCategory(id);
        _chanIndex = _vodIndexFor(id, session.vodInCategory.length);
        _indexCategoryId = id;
      } else if (series) {
        final prev = session.selectedSeriesCategoryId;
        if (prev != null) _chanIndexByCategory['series:$prev'] = _chanIndex;
        final id = cats[_catIndex].categoryId;
        session.selectSeriesCategory(id);
        _chanIndex = _seriesIndexFor(id, session.seriesInCategory.length);
        _indexCategoryId = id;
      } else {
        _selectCategoryKeepingChanPos(cats[_catIndex].categoryId);
      }
      _scrollTo(
        _catScroll,
        _catIndex,
        itemExtent: _catRowExtent,
        headerExtent: _listHeaderExtent,
      );
    } else if (_isPosterGuide) {
      _applyVodGridMove(dy: delta);
    } else {
      final n = session.channelsInCategory.length;
      if (n == 0) return;
      setState(() {
        _chanIndex = (_chanIndex + delta).clamp(0, n - 1);
      });
      _rememberChanIndex();
      _scrollToEpgIndex(_chanIndex);
      session.prefetchFullEpgAround(session.channelsInCategory, _chanIndex);
    }
  }

  List<GuideSection> get _sectionOrder {
    final out = <GuideSection>[GuideSection.live];
    if (session.moviesAvailable) out.add(GuideSection.movies);
    if (session.seriesAvailable) out.add(GuideSection.series);
    return out;
  }

  Future<void> _cycleSection(int delta) async {
    final order = _sectionOrder;
    if (order.length < 2) return;
    var i = order.indexOf(session.guideSection);
    if (i < 0) i = 0;
    i = (i + delta) % order.length;
    if (i < 0) i += order.length;
    await _switchSection(order[i]);
  }

  Future<void> _switchSection(GuideSection section) async {
    if (session.guideSection == section) return;
    if (_vodDetailOpen || _seriesEpisodesOpen) session.closeVodDetail();
    await session.setGuideSection(section);
    if (!mounted) return;
    if (section == GuideSection.movies) {
      final cats = session.browseVodCategories;
      if (cats.isNotEmpty) session.selectVodCategory(cats.first.categoryId);
    } else if (section == GuideSection.series) {
      final cats = session.browseSeriesCategories;
      if (cats.isNotEmpty) session.selectSeriesCategory(cats.first.categoryId);
    }
    if (!mounted) return;
    setState(() {
      _catIndex = 0;
      _chanIndex = 0;
      _column = 0;
      _sectionFocus = true;
      _vodDetailOpen = false;
      _seriesEpisodesOpen = false;
      _indexCategoryId = section == GuideSection.movies
          ? session.selectedVodCategoryId
          : section == GuideSection.series
          ? session.selectedSeriesCategoryId
          : session.selectedCategoryId;
    });
    _syncEpgClock();
    if (section == GuideSection.live) {
      session.prefetchFullEpgAround(session.channelsInCategory, _chanIndex);
    }
  }

  void _moveHorizontal(int delta) {
    // Search page: ←/→ along the focused row.
    if (_searchOpen) {
      if (!_searchBrowseResults || _searchRows.isEmpty) return;
      if (!_acceptNav()) return;
      final n = _searchRows[_searchRow].hits.length;
      setState(() {
        _searchCols = [..._searchCols];
        _searchCols[_searchRow] = (_searchCols[_searchRow] + delta).clamp(
          0,
          n - 1,
        );
      });
      return;
    }
    // Watching + menu: ←/→ adjust current row (subs / audio / mute).
    if (session.isWatchMenuActive && !_overlayOpen) {
      unawaited(session.watchMenuAdjust(delta));
      return;
    }
    if (_sectionFocus && !session.isWatchingExternal && !_overlayOpen) {
      unawaited(_cycleSection(delta > 0 ? 1 : -1));
      return;
    }

    // Watching, menu closed: ←/→ moves the Flutter HUD (or reveals it).
    if (session.isWatchingExternal && !_overlayOpen) {
      final hud = _mpvHudKey.currentState;
      if (hud != null) {
        hud.horizontal(delta);
      } else {
        unawaited(session.watchChannelAdjacent(delta));
      }
      return;
    }

    if (_overlayOpen) {
      return;
    }
    if (_seriesEpisodesOpen) {
      if (delta < 0) {
        if (!_acceptNav()) return;
        _closeSeriesEpisodes();
      }
      return;
    }
    if (_vodDetailOpen) {
      if (delta < 0) {
        if (!_acceptNav()) return;
        _closeVodDetail();
      }
      return;
    }
    if (!_acceptNav()) return;
    // Guide grid: ← back to the categories, → does nothing. Time moves
    // with LB/RB only, so ← never has to undo a → through the timeline.
    if (_isLive && _column == 1) {
      if (delta < 0) _leaveEpgToCategories();
      return;
    }
    if (_isPosterGuide && _column == 1) {
      _applyVodGridMove(dx: delta);
      return;
    }
    if (delta > 0 && _column == 0) {
      if (_isPosterGuide) {
        _enterVodGrid();
      } else {
        _enterChannelColumn();
      }
    } else if (delta < 0 && _column == 1) {
      _rememberChanIndex();
      setState(() => _column = 0);
      _scrollTo(
        _catScroll,
        _catIndex,
        itemExtent: _catRowExtent,
        headerExtent: _listHeaderExtent,
      );
    }
  }

  void _onPage(int delta) {
    if (_lastFavoriteAt != null &&
        DateTime.now().difference(_lastFavoriteAt!) <
            _ignorePageAfterFavorite) {
      return;
    }
    if (_lastMenuAt != null &&
        DateTime.now().difference(_lastMenuAt!) < _ignoreMenuAfterPage) {
      return;
    }
    // Error menu on a live channel: LB/RB zaps away instead of moving rows.
    if (session.watchStallOpen && !session.watchingVod) {
      unawaited(session.watchZapFromError(delta));
      return;
    }
    if (session.isWatchMenuActive) {
      unawaited(session.watchMenuMove(delta));
      return;
    }
    if (session.isWatchingExternal) {
      final hud = _mpvHudKey.currentState;
      if (hud != null) {
        hud.shoulder(delta);
      } else {
        unawaited(session.watchChannelAdjacent(delta));
      }
      return;
    }
    _lastPageAt = DateTime.now();
    // Overlays own LB/RB. Checking this before seasons/title prevents a
    // dual-fired ☰ menu from also changing season, and stops RB-in-search
    // from mutating the page underneath.
    if (_overlayOpen) {
      _moveVertical(delta < 0 ? -1 : 1);
      return;
    }
    if (_seriesEpisodesOpen) {
      if (!_acceptNav()) return;
      _changeSeriesSeason(delta);
      return;
    }
    if (_vodDetailOpen) {
      // Title landing is ↑↓ only — LB/RB are season (episodes) / EPG time.
      return;
    }
    // Guide (categories, channels or posters): Live ⇄ Movies ⇄ TV Shows.
    if (!_acceptNav()) return;
    unawaited(_cycleSection(delta < 0 ? -1 : 1));
  }

  DateTime? _lastActivateAt;

  StreamSubscription<String>? _mpvKeys;

  /// A key pressed while the mpv window has focus (PC keyboard). Routed to
  /// the same handlers as the gamepad, so HUD, menus and zapping match.
  void _onMpvKey(String key) {
    if (!mounted || !session.isWatchingExternal) return;
    // Deck: Steam also injects a key (Esc for B, Enter for A) for a pad
    // press the pad reader already handled. Skip keys right after pad input.
    final pad = SdtvJoystickHub.instance.lastEdgeAt;
    if (pad != null &&
        DateTime.now().difference(pad) < const Duration(milliseconds: 300)) {
      return;
    }
    switch (key) {
      case 'left':
        _moveHorizontal(-1);
      case 'right':
        _moveHorizontal(1);
      case 'up':
        _moveVertical(-1);
      case 'down':
        _moveVertical(1);
      case 'confirm':
        unawaited(_activate());
      case 'back':
        _onBack();
      case 'page-up':
        _onPage(-1);
      case 'page-down':
        _onPage(1);
      case 'menu':
        _openMenu();
      case 'mute':
        unawaited(session.watchCycleMute());
      case 'favorite':
        unawaited(_toggleFavorite());
      case 'playpause':
        _mpvHudKey.currentState?.togglePause();
      case 'quit':
        unawaited(session.watchQuit());
    }
  }

  Future<void> _activate() async {
    // Belt-and-suspenders vs dual js+Enter on Deck.
    final now = DateTime.now();
    if (_lastActivateAt != null &&
        now.difference(_lastActivateAt!) < const Duration(milliseconds: 280)) {
      return;
    }
    _lastActivateAt = now;

    // While mpv is up: A drives the Flutter HUD. ☰ opens the subs/audio menu.
    if (session.isWatchingExternal) {
      if (_overlayOpen) {
        await session.watchQuit();
      } else if (session.isWatchMenuActive) {
        await session.watchActivate();
      } else {
        _mpvHudKey.currentState?.confirm();
      }
      return;
    }

    if (_unfavOpen) {
      await _resolveUnfav();
      return;
    }

    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }

    if (_switchSourceOpen) {
      await _activateSwitchSource();
      return;
    }

    if (_searchOpen) {
      // OSK A selects a letter. Ignore until the user has left the field.
      if (!_searchBrowseResults) return;
      await _activateSearchHit();
      return;
    }

    if (_manageCatsOpen) {
      // A picks the category up (↑↓ then move it) and drops it again.
      if (session.orderedCategories.isNotEmpty) {
        setState(() => _manageMoving = !_manageMoving);
      }
      return;
    }

    if (_menuOpen) {
      final entries = _menuEntries;
      await _runMenuAction(entries[_menuIndex.clamp(0, entries.length - 1)].id);
      return;
    }

    if (_settingsOpen) {
      final entries = _settingsEntries;
      await _runSettingsAction(
        entries[_settingsIndex.clamp(0, entries.length - 1)].id,
      );
      return;
    }

    if (_seriesEpisodesOpen) {
      await _playSelectedEpisode();
      return;
    }

    if (_vodDetailOpen) {
      await _runVodDetailAction();
      return;
    }

    if (_sectionFocus) {
      setState(() => _sectionFocus = false);
      return;
    }

    // Categories: enter channel / poster column only (restore last row).
    if (_column == 0) {
      if (_isPosterGuide) {
        _enterVodGrid();
        return;
      }
      final cats = session.browseCategories;
      if (cats.isEmpty) return;
      _selectCategoryKeepingChanPos(cats[_catIndex].categoryId);
      _enterChannelColumn();
      return;
    }

    if (_isMovies) {
      final list = session.vodInCategory;
      if (list.isEmpty) return;
      final item = list[_chanIndex.clamp(0, list.length - 1)];
      _openVodDetail(item);
      return;
    }

    if (_isSeries) {
      final list = session.seriesInCategory;
      if (list.isEmpty) return;
      final item = list[_chanIndex.clamp(0, list.length - 1)];
      _openSeriesDetail(item);
      return;
    }

    // Channels: hand off to external fullscreen mpv (Phase A).
    await _playFocusedLive();
  }

  void _snack(String text, {Duration duration = const Duration(seconds: 6)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text), duration: duration));
  }

  /// Plays on external mpv. Shows the error, or the dock-resolution hint.
  Future<void> _playMpv(Future<String?> Function() play) async {
    final err = await play();
    if (!mounted) return;
    if (err != null) {
      _snack(err);
      return;
    }
    if (session.needsAppRestartForFullDisplay) {
      session.clearDisplayRestartHint();
      _snack(
        'Docked at handheld resolution — STEAM → Exit sdtv → open again '
        'for full TV (Native applies on launch only)',
        duration: const Duration(seconds: 8),
      );
    }
  }

  Future<void> _playFocusedLive() async {
    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    _rememberChanIndex();
    await _playMpv(() => session.watchChannel(ch));
  }

  Future<void> _offerTrailer(VodInfo info) async {
    if (info.isYoutubeTrailer) {
      final err = await session.watchTrailer(info);
      if (!mounted) return;
      if (err != null) _snack(err);
      return;
    }
    if (info.trailerUri == null) {
      _snack('No trailer for this title.');
      return;
    }
    await _playMpv(() => session.watchTrailer(info));
  }

  /// Hierarchical back: about → manage → menu → categories ← channels.
  /// While watching: B closes the watch menu, or moves HUD focus to Back,
  /// or quits when the HUD is hidden or Back is already focused.
  void _onBack() {
    if (session.isWatchingExternal) {
      if (session.watchStallOpen || session.isWatchMenuActive) {
        unawaited(session.watchBack());
        return;
      }
      final hud = _mpvHudKey.currentState;
      if (hud != null && hud.handleBack()) return;
      unawaited(session.watchBack());
      return;
    }
    if (_unfavOpen) {
      _closeUnfav();
      return;
    }
    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }
    if (_searchOpen) {
      if (!_searchBrowseResults && _searchCtrl.text.trim().isNotEmpty) {
        _enterSearchResults();
        return;
      }
      _closeSearch();
      return;
    }
    if (_switchSourceOpen) {
      setState(() => _switchSourceOpen = false);
      return;
    }
    if (_manageCatsOpen) {
      setState(() {
        if (_manageMoving) {
          _manageMoving = false; // B drops a picked-up category
        } else {
          _manageCatsOpen = false;
        }
      });
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    if (_settingsOpen) {
      _closeSettings();
      return;
    }
    if (_seriesEpisodesOpen) {
      _closeSeriesEpisodes();
      return;
    }
    if (_vodDetailOpen) {
      _closeVodDetail();
      return;
    }
    // In channel / poster grid: step back to categories (don't open system menu).
    // Live guide: first B snaps to now if the timeline is ahead; B again
    // (already at now) returns to categories.
    if (_column == 1) {
      if (!_acceptNav()) return;
      if (_isSeries) {
        _rememberSeriesIndex();
      } else if (_isMovies) {
        _rememberVodIndex();
      } else {
        _rememberChanIndex();
        if (_epgAwayFromNow) {
          unawaited(_jumpEpgToNow());
          return;
        }
      }
      setState(() => _column = 0);
      _scrollTo(
        _catScroll,
        _catIndex,
        itemExtent: _catRowExtent,
        headerExtent: _listHeaderExtent,
      );
      return;
    }
    // Category column (Live / Movies / future TV): first B jumps to the
    // top of the list; B at the top opens the in-page menu.
    if (_sectionFocus || _catIndex > 0) {
      if (!_acceptNav()) return;
      _jumpToCategoryListTop();
      return;
    }
    setState(() {
      _menuOpen = true;
      _menuIndex = 0;
    });
  }

  void _jumpToCategoryListTop() {
    final movies = _isMovies;
    final series = _isSeries;
    final cats = movies
        ? session.browseVodCategories
        : series
        ? session.browseSeriesCategories
        : session.browseCategories;
    setState(() {
      _sectionFocus = false;
      _column = 0;
      _catIndex = 0;
    });
    if (cats.isNotEmpty) {
      if (movies) {
        final prev = session.selectedVodCategoryId;
        if (prev != null) _chanIndexByCategory['vod:$prev'] = _chanIndex;
        final id = cats.first.categoryId;
        session.selectVodCategory(id);
        _chanIndex = _vodIndexFor(id, session.vodInCategory.length);
        _indexCategoryId = id;
      } else if (series) {
        final prev = session.selectedSeriesCategoryId;
        if (prev != null) _chanIndexByCategory['series:$prev'] = _chanIndex;
        final id = cats.first.categoryId;
        session.selectSeriesCategory(id);
        _chanIndex = _seriesIndexFor(id, session.seriesInCategory.length);
        _indexCategoryId = id;
      } else {
        _selectCategoryKeepingChanPos(cats.first.categoryId);
      }
    }
    _scrollTo(
      _catScroll,
      0,
      itemExtent: _catRowExtent,
      headerExtent: _listHeaderExtent,
    );
  }

  void _openMenu() {
    // ☰ / Start always opens menu (or closes overlay if one is up).
    // Ignore a Start/menu edge that arrived with LB/RB (Deck dual-fire).
    if (_lastPageAt != null &&
        DateTime.now().difference(_lastPageAt!) < _ignoreMenuAfterPage) {
      return;
    }
    _lastMenuAt = DateTime.now();
    if (_unfavOpen) {
      _closeUnfav();
      return;
    }
    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    if (_switchSourceOpen) {
      setState(() => _switchSourceOpen = false);
      return;
    }
    if (_manageCatsOpen) {
      setState(() {
        _manageCatsOpen = false;
        _manageMoving = false;
      });
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    if (_settingsOpen) {
      _closeSettings();
      return;
    }
    if (session.isWatchingExternal) {
      if (session.isWatchMenuActive) {
        unawaited(session.watchCloseMenu(resume: true));
      } else {
        unawaited(session.watchOpenMenu());
      }
      return;
    }
    setState(() {
      _menuOpen = true;
      _menuIndex = 0;
    });
  }

  Future<void> _activateSwitchSource() async {
    final list = session.savedSources;
    if (list.isEmpty) return;
    final i = _switchSourceIndex.clamp(0, list.length - 1);
    final source = list[i];
    setState(() => _switchSourceOpen = false);
    // Switching reloads catalog; reset guide landing for the new source.
    _didRestoreLanding = false;
    await session.openSavedSource(source);
    if (!mounted) return;
    _restoreGuideLanding();
  }

  void _openSearch() {
    if (session.isWatchingExternal) return;
    setState(() {
      _menuOpen = false;
      _aboutOpen = false;
      _manageCatsOpen = false;
      _manageMoving = false;
      _unfavOpen = false;
      _unfavName = '';
      _unfavRemove = null;
      _searchOpen = true;
      _searchBrowseResults = false;
      _searchRow = 0;
      _searchCols = const [];
      _setSearchHits(
        session.searchGuide(_searchCtrl.text, maxResults: 300),
        reset: true,
      );
    });
    // Build the index after the search box paints, before the first glyph.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) session.warmSearchIndex();
    });
    unawaited(_ensureSearchCatalogs());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocus.requestFocus();
      // Opening via `/` can insert a slash into the field — strip it.
      final t = _searchCtrl.text;
      if (t.startsWith('/')) {
        _searchCtrl.text = t.substring(1);
        _searchCtrl.selection = TextSelection.collapsed(
          offset: _searchCtrl.text.length,
        );
      }
    });
  }

  Future<void> _ensureSearchCatalogs() async {
    if (session.moviesAvailable && !session.vodCatalogReady) {
      await session.loadVodCatalog();
    }
    if (session.seriesAvailable && !session.seriesCatalogReady) {
      await session.loadSeriesCatalog();
    }
    if (!mounted || !_searchOpen) return;
    // Movies / TV Shows just arrived: rebuild the index now, not on a key.
    session.warmSearchIndex();
    setState(() {
      _setSearchHits(session.searchGuide(_searchCtrl.text, maxResults: 300));
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchOpen = false;
      _searchBrowseResults = false;
      _searchRow = 0;
    });
  }

  bool get _epgAwayFromNow {
    final now = DateTime.now();
    final chans = session.channelsInCategory;
    int? focusedIndex;
    int? liveIndex;
    if (chans.isNotEmpty) {
      final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
      final epg = session.cachedFullEpg(ch);
      final listings = epg?.listings ?? const <EpgProgram>[];
      if (listings.isNotEmpty) {
        focusedIndex = epg!.indexForTime(_epgFocusTime);
        liveIndex = epg.indexForTime(now);
      }
    }
    return epgNeedsReturnToNow(
      windowStart: _epgWindowStart,
      focusTime: _epgFocusTime,
      now: now,
      focusedIndex: focusedIndex,
      liveIndex: liveIndex,
    );
  }

  Future<void> _jumpEpgToNow() async {
    if (session.isWatchingExternal) return;
    if (!_isLive) {
      await _switchSection(GuideSection.live);
      if (!mounted) return;
    }
    final now = DateTime.now();
    setState(() {
      _menuOpen = false;
      _column = 1;
      _sectionFocus = false;
      _epgWindowStart = epgSnapDown(now);
      _epgFocusTime = now;
    });
    _syncEpgClock();
    session.prefetchFullEpgAround(session.channelsInCategory, _chanIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isLive) _scrollToEpgIndex(_chanIndex);
    });
  }

  void _leaveEpgToCategories() {
    _rememberChanIndex();
    setState(() => _column = 0);
    _scrollTo(
      _catScroll,
      _catIndex,
      itemExtent: _catRowExtent,
      headerExtent: _listHeaderExtent,
    );
  }

  /// Guide window / focus, never before now (the guide shows now and later).
  DateTime get _epgWindowNow => epgClampToNow(_epgWindowStart, DateTime.now());
  DateTime get _epgFocusNow {
    final now = DateTime.now();
    return _epgFocusTime.isBefore(now) ? now : _epgFocusTime;
  }

  /// New results: regroup into rows and keep the cursor in range. [reset]
  /// (a new query) puts it back on the first card.
  void _setSearchHits(List<GuideSearchHit> hits, {bool reset = false}) {
    _searchRows = SearchRow.group(hits);
    final old = reset ? const <int>[] : _searchCols;
    _searchCols = [
      for (var r = 0; r < _searchRows.length; r++)
        r < old.length ? old[r].clamp(0, _searchRows[r].hits.length - 1) : 0,
    ];
    _searchRow = reset || _searchRows.isEmpty
        ? 0
        : _searchRow.clamp(0, _searchRows.length - 1);
  }

  void _enterSearchResults() {
    if (!_searchOpen || _searchRows.isEmpty) return;
    // Focus a node inside the page, or arrow keys fall through to Flutter's
    // directional traversal, which moves focus back into the query field.
    _searchFocus.unfocus();
    // The same key press can also arrive through Shortcuts: do not let it
    // move a row as well.
    _lastNavAt = DateTime.now();
    setState(() => _searchBrowseResults = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen && _searchBrowseResults) {
        _searchListFocus.requestFocus();
      }
    });
  }

  void _returnToSearchField() {
    if (!_searchOpen) return;
    setState(() => _searchBrowseResults = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchOpen) return;
      _searchFocus.requestFocus();
      final t = _searchCtrl.text;
      _searchCtrl.selection = TextSelection.collapsed(offset: t.length);
    });
  }

  Future<void> _activateSearchHit() async {
    if (_searchRows.isEmpty) return;
    final row = _searchRows[_searchRow.clamp(0, _searchRows.length - 1)];
    final col = _searchCols[_searchRow.clamp(0, _searchCols.length - 1)];
    await _applySearchHit(row.hits[col.clamp(0, row.hits.length - 1)]);
  }

  Future<void> _applySearchHit(GuideSearchHit hit) async {
    // EPG hits: navigate when implemented; for now no-op with room to extend.
    if (hit.isEpg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('EPG search coming later'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (hit.section == GuideSearchSection.movies) {
      await _jumpSearchToMovies(hit);
      return;
    }
    if (hit.section == GuideSearchSection.series) {
      await _jumpSearchToSeries(hit);
      return;
    }

    final catId = hit.categoryId;
    if (catId == null || catId.isEmpty) return;

    await session.setGuideSection(GuideSection.live);
    if (!mounted) return;

    // Jump guide to this category / channel.
    final cats = session.browseCategories;
    var catIdx = cats.indexWhere((c) => c.categoryId == catId);
    // Hidden cat shouldn't appear in search; if only channel matched via
    // allChannels, still select raw id.
    if (catIdx < 0 && catId != kFavoritesCategoryId) {
      // Category hidden or missing — still try to select for channel play.
      session.selectCategory(catId);
    } else if (catIdx >= 0) {
      _selectCategoryKeepingChanPos(catId);
      catIdx = session.browseCategories.indexWhere(
        (c) => c.categoryId == catId,
      );
    } else if (catId == kFavoritesCategoryId) {
      _selectCategoryKeepingChanPos(kFavoritesCategoryId);
      catIdx = 0;
    }

    final browse = session.browseCategories;
    final resolvedCat = browse.indexWhere((c) => c.categoryId == catId);
    if (resolvedCat >= 0) {
      _catIndex = resolvedCat;
    }

    if (hit.isChannel && hit.channel != null) {
      final list = session.channelsInCategory;
      var chIdx = list.indexWhere(
        (c) => c.favoriteKey == hit.channel!.favoriteKey,
      );
      if (chIdx < 0) {
        // Channel may live in another group; use allChannels position in cat.
        chIdx = list.indexWhere((c) => c.streamId == hit.channel!.streamId);
      }
      if (chIdx < 0) chIdx = 0;
      _chanIndex = chIdx;
      _chanIndexByCategory[catId] = chIdx;
      _closeSearch();
      setState(() {
        _vodDetailOpen = false;
        _seriesEpisodesOpen = false;
        _sectionFocus = false;
        _column = 1;
        _chanIndex = chIdx;
      });
      session.prefetchFullEpgAround(session.channelsInCategory, chIdx);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToEpgIndex(chIdx);
      });
      return;
    }

    // Category hit: open that list at remembered/top position.
    _closeSearch();
    setState(() {
      _vodDetailOpen = false;
      _seriesEpisodesOpen = false;
      _sectionFocus = false;
    });
    _enterChannelColumn();
  }

  Future<void> _jumpSearchToMovies(GuideSearchHit hit) async {
    final catId = hit.categoryId;
    if (catId == null || catId.isEmpty) return;
    await session.setGuideSection(GuideSection.movies);
    if (!mounted) return;
    session.selectVodCategory(catId);
    final list = session.vodInCategory;
    var idx = 0;
    if (hit.vod != null && list.isNotEmpty) {
      final i = list.indexWhere((v) => v.streamId == hit.vod!.streamId);
      idx = i >= 0 ? i : 0;
    } else {
      idx = _vodIndexFor(catId, list.length);
    }
    final cats = session.browseVodCategories;
    var catIdx = cats.indexWhere((c) => c.categoryId == catId);
    if (catIdx < 0) catIdx = 0;
    _chanIndexByCategory['vod:$catId'] = idx;
    _closeSearch();
    setState(() {
      _vodDetailOpen = false;
      _seriesEpisodesOpen = false;
      _sectionFocus = false;
      _column = 1;
      _catIndex = catIdx;
      _chanIndex = idx;
      _indexCategoryId = catId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollTo(
        _catScroll,
        catIdx,
        itemExtent: _catRowExtent,
        headerExtent: _listHeaderExtent,
      );
      _scrollToVodIndex(idx);
    });
  }

  Future<void> _jumpSearchToSeries(GuideSearchHit hit) async {
    final catId = hit.categoryId;
    if (catId == null || catId.isEmpty) return;
    await session.setGuideSection(GuideSection.series);
    if (!mounted) return;
    session.selectSeriesCategory(catId);
    final list = session.seriesInCategory;
    var idx = 0;
    if (hit.series != null && list.isNotEmpty) {
      final i = list.indexWhere((s) => s.seriesId == hit.series!.seriesId);
      idx = i >= 0 ? i : 0;
    } else {
      idx = _seriesIndexFor(catId, list.length);
    }
    final cats = session.browseSeriesCategories;
    var catIdx = cats.indexWhere((c) => c.categoryId == catId);
    if (catIdx < 0) catIdx = 0;
    _chanIndexByCategory['series:$catId'] = idx;
    _closeSearch();
    setState(() {
      _vodDetailOpen = false;
      _seriesEpisodesOpen = false;
      _sectionFocus = false;
      _column = 1;
      _catIndex = catIdx;
      _chanIndex = idx;
      _indexCategoryId = catId;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollTo(
        _catScroll,
        catIdx,
        itemExtent: _catRowExtent,
        headerExtent: _listHeaderExtent,
      );
      _scrollToVodIndex(idx);
    });
  }

  Future<void> _runMenuAction(String id) async {
    setState(() => _menuOpen = false);
    switch (id) {
      case 'search':
        _openSearch();
      case 'settings':
        setState(() {
          _settingsOpen = true;
          _settingsIndex = 0;
          _disarmSignOut();
        });
      case 'hide_cat':
        await _hideFocusedCategory();
      case 'exit':
        await _exitApp();
    }
  }

  void _closeSettings() {
    setState(() {
      _settingsOpen = false;
      _disarmSignOut();
    });
  }

  void _disarmSignOut() {
    _signOutTimer?.cancel();
    _signOutArmed = false;
  }

  Future<void> _runSettingsAction(String id) async {
    if (id != 'signout') {
      setState(_disarmSignOut);
    }
    switch (id) {
      case 'switch_source':
        _openSwitchSource();
      case 'manage_cats':
        setState(() {
          _manageCatsOpen = true;
          _manageMoving = false;
          _manageIndex = 0;
        });
      case 'about':
        setState(() => _aboutOpen = true);
      case 'signout':
        if (!_signOutArmed) {
          // First A arms it; a second A within a few seconds signs out.
          setState(() => _signOutArmed = true);
          _signOutTimer?.cancel();
          _signOutTimer = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _signOutArmed = false);
          });
          return;
        }
        _closeSettings();
        await session.signOut();
    }
  }

  void _openSwitchSource() {
    final list = session.savedSources;
    if (list.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved playlists yet — connect M3U/Xtream first'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    var idx = 0;
    final active = session.activeSourceId;
    if (active != null) {
      final i = list.indexWhere((s) => s.id == active);
      if (i >= 0) idx = i;
    }
    setState(() {
      _switchSourceOpen = true;
      _switchSourceIndex = idx;
    });
  }

  /// Hide the category under the guide cursor (not ★ Favorites).
  /// Movies / TV Shows share the hidden-id set, but Manage categories is
  /// still live-only — don't hide poster-guide cats until that UI exists.
  Future<void> _hideFocusedCategory() async {
    if (session.isWatchingExternal) return;
    if (_isPosterGuide) return;
    final cats = session.browseCategories;
    if (cats.isEmpty) return;
    // Prefer category column selection; if on channels, hide that category.
    final idx = _catIndex.clamp(0, cats.length - 1);
    final cat = cats[idx];
    if (cat.categoryId == kFavoritesCategoryId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('★ Favorites cannot be hidden'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final name = cat.categoryName;
    await session.hideCategory(cat.categoryId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Hidden: $name · Settings → Manage categories to restore'),
        duration: const Duration(seconds: 3),
      ),
    );
    setState(() {
      _column = 0;
    });
  }

  Future<void> _toggleManageRow() async {
    final all = session.orderedCategories;
    if (all.isEmpty) return;
    final i = _manageIndex.clamp(0, all.length - 1);
    final cat = all[i];
    // No SnackBar here — bulk hide would queue dozens of toasts.
    // Tile label/icon + header counts already update in place.
    await session.toggleCategoryHidden(cat.categoryId);
    if (mounted) setState(() {});
  }

  /// Y / F: star live from the guide; movies / TV shows only on the title page.
  Future<void> _toggleFavorite() async {
    if (_overlayOpen) return;
    _lastFavoriteAt = DateTime.now();

    if (session.isWatchingExternal) {
      if (session.nowPlayingVod != null || session.nowPlayingSeries != null) {
        return;
      }
    } else if (_isMovies || _isSeries) {
      if (!_vodDetailOpen || _seriesEpisodesOpen) {
        _favoriteHint('Open the title, then Add to Favorites');
        return;
      }
      if (_isMovies) {
        final item = session.vodDetailItem;
        if (item == null) {
          _favoriteHint('Open the title, then Add to Favorites');
          return;
        }
        if (session.isVodFavorite(item)) {
          _openUnfav(item.name, () => _applyVodFavoriteToggle(item));
          return;
        }
        await _applyVodFavoriteToggle(item);
        return;
      }
      final show = session.seriesDetailItem;
      if (show == null) {
        _favoriteHint('Open the title, then Add to Favorites');
        return;
      }
      if (session.isSeriesFavorite(show)) {
        _openUnfav(show.name, () => _applySeriesFavoriteToggle(show));
        return;
      }
      await _applySeriesFavoriteToggle(show);
      return;
    }

    LiveChannel? ch;
    if (session.isWatchingExternal) {
      ch = session.nowPlaying;
    } else if (_column == 1) {
      final chans = session.channelsInCategory;
      if (chans.isNotEmpty) {
        ch = chans[_chanIndex.clamp(0, chans.length - 1)];
      }
    }

    if (ch == null) {
      _favoriteHint('Highlight a channel (or play one), then Y to favorite');
      return;
    }

    if (session.isFavorite(ch) && !session.isWatchingExternal) {
      final channel = ch;
      _openUnfav(channel.name, () => _applyFavoriteToggle(channel));
      return;
    }

    await _applyFavoriteToggle(ch);
  }

  void _favoriteHint(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  void _openUnfav(String name, Future<void> Function() remove) {
    setState(() {
      _unfavOpen = true;
      _unfavIndex = 0;
      _unfavName = name;
      _unfavRemove = remove;
    });
  }

  void _closeUnfav() {
    setState(() {
      _unfavOpen = false;
      _unfavIndex = 0;
      _unfavName = '';
      _unfavRemove = null;
    });
  }

  Future<void> _resolveUnfav() async {
    final remove = _unfavIndex == 1;
    final action = _unfavRemove;
    _closeUnfav();
    if (!remove || action == null) return;
    await action();
  }

  Future<void> _applyFavoriteToggle(LiveChannel ch) async {
    final nowFav = await session.toggleFavorite(ch);
    _starSnack(nowFav, ch.name);
  }

  Future<void> _applyVodFavoriteToggle(VodItem item) async {
    final nowFav = await session.toggleVodFavorite(item);
    _starSnack(nowFav, item.name);
  }

  Future<void> _applySeriesFavoriteToggle(SeriesItem show) async {
    final nowFav = await session.toggleSeriesFavorite(show);
    _starSnack(nowFav, show.name);
  }

  void _starSnack(bool nowFav, String name) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFav ? '★ $name' : '☆ Removed $name'),
        duration: const Duration(seconds: 2),
      ),
    );
    setState(() {});
  }

  List<({String id, String label, IconData icon})> get _vodDetailActions {
    final series = session.seriesDetailItem;
    if (series != null) return _seriesDetailActions(series);

    final item = session.vodDetailItem;
    final info =
        session.vodDetail ?? (item != null ? VodInfo.fromVodItem(item) : null);
    final saved = item == null ? 0 : session.vodResumeSeconds(item);
    final out = <({String id, String label, IconData icon})>[];
    if (saved > 15) {
      out.add((
        id: 'resume',
        label: 'Resume Playing',
        icon: Icons.play_arrow_rounded,
      ));
      out.add((
        id: 'start',
        label: 'Start from Beginning',
        icon: Icons.replay_rounded,
      ));
    } else {
      out.add((id: 'start', label: 'Play Now', icon: Icons.play_arrow_rounded));
    }
    out.add(
      _favoriteAction(favorited: item != null && session.isVodFavorite(item)),
    );
    if (info != null && info.hasTrailer) {
      out.add((
        id: 'trailer',
        label: 'Watch trailer',
        icon: Icons.theaters_outlined,
      ));
    }
    return out;
  }

  ({String id, String label, IconData icon}) _favoriteAction({
    required bool favorited,
  }) {
    return (
      id: 'favorite',
      label: favorited ? 'Remove from Favorites' : 'Add to Favorites',
      icon: favorited ? Icons.star_rounded : Icons.star_border_rounded,
    );
  }

  List<({String id, String label, IconData icon})> _seriesDetailActions(
    SeriesItem series,
  ) {
    final info = session.vodDetail ?? VodInfo.fromVodItem(series.asVodItem);
    final cat = session.seriesCatalog;
    final resume = session.seriesResume(series);
    final epId = resume['episodeId'] ?? '';
    final resumeEp = epId.isEmpty ? null : cat?.episodeById(epId);
    final saved = resumeEp == null
        ? 0
        : session.episodeProgressSeconds(resumeEp);
    final out = <({String id, String label, IconData icon})>[];
    if (resumeEp != null && saved > 15) {
      out.add((
        id: 'resume',
        label: 'Resume Playing · S${resumeEp.season}E${resumeEp.episodeNum}',
        icon: Icons.play_arrow_rounded,
      ));
      out.add((
        id: 'start',
        label: 'Start from Beginning',
        icon: Icons.replay_rounded,
      ));
    } else {
      out.add((id: 'start', label: 'Play Now', icon: Icons.play_arrow_rounded));
    }
    out.add(_favoriteAction(favorited: session.isSeriesFavorite(series)));
    out.add((
      id: 'seasons',
      label: 'Seasons & episodes',
      icon: Icons.view_list_rounded,
    ));
    if (info.hasTrailer) {
      out.add((
        id: 'trailer',
        label: 'Watch trailer',
        icon: Icons.theaters_outlined,
      ));
    }
    return out;
  }

  void _openVodDetail(VodItem item) {
    setState(() {
      _vodDetailOpen = true;
      _seriesEpisodesOpen = false;
      _vodDetailAction = 0;
      _column = 1;
      _sectionFocus = false;
    });
    unawaited(session.openVodDetail(item));
  }

  void _openSeriesDetail(SeriesItem item) {
    setState(() {
      _vodDetailOpen = true;
      _seriesEpisodesOpen = false;
      _vodDetailAction = 0;
      _column = 1;
      _sectionFocus = false;
    });
    unawaited(session.openSeriesDetail(item));
  }

  void _closeVodDetail() {
    session.closeVodDetail();
    setState(() {
      _vodDetailOpen = false;
      _seriesEpisodesOpen = false;
      _vodDetailAction = 0;
      _column = 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToVodIndex(_chanIndex);
    });
  }

  void _restoreSeriesEpisodeCursor() {
    final cat = session.seriesCatalog;
    final show = session.seriesDetailItem;
    if (cat == null || cat.seasons.isEmpty) {
      _seasonIndex = 0;
      _episodeIndex = 0;
      return;
    }
    if (show != null) {
      final epId = session.seriesResume(show)['episodeId'] ?? '';
      if (epId.isNotEmpty) {
        for (var si = 0; si < cat.seasons.length; si++) {
          final ei = cat.seasons[si].episodes.indexWhere((e) => e.id == epId);
          if (ei >= 0) {
            _seasonIndex = si;
            _episodeIndex = ei;
            return;
          }
        }
      }
    }
    _seasonIndex = _seasonIndex.clamp(0, cat.seasons.length - 1);
    final eps = cat.seasons[_seasonIndex].episodes;
    _episodeIndex = eps.isEmpty ? 0 : _episodeIndex.clamp(0, eps.length - 1);
  }

  void _openSeriesEpisodes() {
    _restoreSeriesEpisodeCursor();
    setState(() {
      _seriesEpisodesOpen = true;
      _vodDetailOpen = true;
      _column = 1;
      _sectionFocus = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_seriesEpisodesOpen) return;
      _scrollToEpisodeIndex(_episodeIndex);
    });
  }

  void _closeSeriesEpisodes() {
    final actions = _vodDetailActions;
    var action = 0;
    final i = actions.indexWhere((a) => a.id == 'seasons');
    if (i >= 0) action = i;
    setState(() {
      _seriesEpisodesOpen = false;
      _vodDetailOpen = true;
      _vodDetailAction = action;
    });
  }

  List<SeriesEpisode> get _currentEpisodes {
    final seasons = session.seriesCatalog?.seasons ?? const [];
    if (seasons.isEmpty) return const [];
    return seasons[_seasonIndex.clamp(0, seasons.length - 1)].episodes;
  }

  void _scrollToEpisodeIndex(int index) {
    _ensureIndexVisible(
      _episodeScroll,
      index,
      itemExtent: _rowExtent,
      headerExtent: 0,
    );
  }

  void _moveSeriesEpisode(int delta) {
    final eps = _currentEpisodes;
    if (eps.isEmpty) return;
    setState(() {
      _episodeIndex = (_episodeIndex + delta).clamp(0, eps.length - 1);
    });
    _scrollToEpisodeIndex(_episodeIndex);
  }

  void _changeSeriesSeason(int delta) {
    final seasons = session.seriesCatalog?.seasons ?? const [];
    if (seasons.length < 2) {
      _moveSeriesEpisode(delta * 5);
      return;
    }
    final next = (_seasonIndex + delta).clamp(0, seasons.length - 1);
    if (next == _seasonIndex) return;
    setState(() {
      _seasonIndex = next;
      _episodeIndex = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _seriesEpisodesOpen) _scrollToEpisodeIndex(0);
    });
  }

  Future<void> _playSelectedEpisode({bool fromBeginning = false}) async {
    final show = session.seriesDetailItem;
    final eps = _currentEpisodes;
    if (show == null || eps.isEmpty) return;
    final ep = eps[_episodeIndex.clamp(0, eps.length - 1)];
    await _playMpv(
      () => session.watchSeriesEpisode(show, ep, fromBeginning: fromBeginning),
    );
  }

  Future<void> _runVodDetailAction() async {
    final actions = _vodDetailActions;
    if (actions.isEmpty) return;
    final id = actions[_vodDetailAction.clamp(0, actions.length - 1)].id;
    await _runVodDetailActionId(id);
  }

  Future<void> _runVodDetailActionId(String id) async {
    if (session.seriesDetailItem != null) {
      await _runSeriesDetailActionId(id);
      return;
    }
    final item = session.vodDetailItem;
    if (item == null) return;
    if (id == 'favorite') {
      await _toggleFavorite();
      return;
    }
    if (id == 'trailer') {
      final info = session.vodDetail ?? VodInfo.fromVodItem(item);
      await _offerTrailer(info);
      return;
    }
    if (id != 'resume' && id != 'start') return;
    final fromBeginning = id == 'start';
    await _playMpv(() => session.watchVod(item, fromBeginning: fromBeginning));
  }

  Future<void> _runSeriesDetailActionId(String id) async {
    final show = session.seriesDetailItem;
    if (show == null) return;
    if (id == 'seasons') {
      _openSeriesEpisodes();
      return;
    }
    if (id == 'favorite') {
      await _toggleFavorite();
      return;
    }
    if (id == 'trailer') {
      final info = session.vodDetail ?? VodInfo.fromVodItem(show.asVodItem);
      await _offerTrailer(info);
      return;
    }
    if (id != 'resume' && id != 'start') return;
    final cat = session.seriesCatalog;
    final SeriesEpisode? ep;
    if (id == 'resume') {
      final epId = session.seriesResume(show)['episodeId'] ?? '';
      ep = cat?.episodeById(epId) ?? cat?.firstEpisode;
    } else {
      ep = cat?.firstEpisode;
    }
    if (ep == null) {
      _snack(
        session.vodDetailLoading
            ? 'Loading episodes…'
            : 'No episodes for this show.',
      );
      return;
    }
    final episode = ep;
    final fromBeginning = id == 'start';
    await _playMpv(
      () => session.watchSeriesEpisode(
        show,
        episode,
        fromBeginning: fromBeginning,
      ),
    );
  }

  Widget _moviesPane(ThemeData theme, String catTitle, List<VodItem> vods) {
    if (_vodDetailOpen) {
      final item =
          session.vodDetailItem ??
          (vods.isEmpty ? null : vods[_chanIndex.clamp(0, vods.length - 1)]);
      if (item == null) {
        return const SizedBox.shrink();
      }
      final info = session.vodDetail ?? VodInfo.fromVodItem(item);
      final actions = _vodDetailActions;
      final ai = actions.isEmpty
          ? 0
          : _vodDetailAction.clamp(0, actions.length - 1);
      return VodTitlePane(
        item: item,
        info: info,
        actions: actions,
        actionIndex: ai,
        loading: session.vodDetailLoading,
        watched: session.isVodWatched(item),
        favorited: session.isVodFavorite(item),
        artCache: session.artwork,
        artScope: session.prefsScope,
        onAction: (id) => unawaited(_runVodDetailActionId(id)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _listHeaderExtent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'TITLES · $catTitle',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: vods.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 24, 24),
                  child: Text(
                    session.vodError ??
                        (session.vodCatalogReady
                            ? (session.selectedVodCategoryId ==
                                      kFavoritesCategoryId
                                  ? 'No favorite movies yet.\n'
                                        'Open a title · Add to Favorites'
                                  : 'No movies in this category.')
                            : 'Loading movies…'),
                    style: theme.textTheme.bodyLarge,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    _syncVodGridMetrics(constraints);
                    final cols = _vodCols.clamp(1, kVodGridMaxCols);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      session.artwork.prefetchVod(
                        scope: session.prefsScope,
                        items: [
                          for (final v in vods)
                            (id: '${v.streamId}', url: v.streamIcon),
                        ],
                        focusIndex: _chanIndex,
                        cols: cols,
                      );
                    });
                    return GridView.builder(
                      controller: _chanScroll,
                      padding: const EdgeInsets.fromLTRB(
                        kVodGridPadding,
                        8,
                        kVodGridPadding,
                        16,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: kVodGridSpacing,
                        crossAxisSpacing: kVodGridSpacing,
                        childAspectRatio: kVodGridChildAspect,
                      ),
                      itemCount: vods.length,
                      itemBuilder: (context, i) {
                        final v = vods[i];
                        final selected = _chanIndex == i;
                        final focused = _column == 1 && selected;
                        final saved = session.vodResumeSeconds(v);
                        final dur = v.durationSecs;
                        final progress = (dur > 0 && saved > 15)
                            ? (saved / dur).clamp(0.0, 1.0)
                            : (saved > 15 ? 0.15 : 0.0);
                        return VodPosterTile(
                          title: v.name,
                          subtitle: saved > 15
                              ? 'Resume ${Duration(seconds: saved).inMinutes}m'
                              : null,
                          selected: selected,
                          focused: focused,
                          progress: progress,
                          watched: session.isVodWatched(v),
                          favorited: session.isVodFavorite(v),
                          posterUrl: v.streamIcon,
                          artId: '${v.streamId}',
                          artScope: session.prefsScope,
                          artCache: session.artwork,
                          onTap: () async {
                            setState(() {
                              _column = 1;
                              _chanIndex = i;
                            });
                            _rememberVodIndex();
                            await _activate();
                          },
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  String? _seriesTileSubtitle(SeriesItem show) {
    final resume = session.seriesResume(show);
    final epId = resume['episodeId'] ?? '';
    if (epId.isEmpty) return null;
    final season = int.tryParse(resume['season'] ?? '') ?? 0;
    final epNum = int.tryParse(resume['episodeNum'] ?? '') ?? 0;
    final loc = season > 0 ? 'S${season}E$epNum' : 'E$epNum';
    final saved = session.episodeProgressById(epId);
    if (saved > 15) {
      return 'Resume $loc · ${saved ~/ 60}m';
    }
    return 'Resume $loc';
  }

  Widget _seriesPane(ThemeData theme, String catTitle, List<SeriesItem> shows) {
    if (_seriesEpisodesOpen) {
      return _seriesEpisodesPane(theme);
    }
    if (_vodDetailOpen) {
      final item =
          session.seriesDetailItem?.asVodItem ??
          session.vodDetailItem ??
          (shows.isEmpty
              ? null
              : shows[_chanIndex.clamp(0, shows.length - 1)].asVodItem);
      if (item == null) {
        return const SizedBox.shrink();
      }
      final info = session.vodDetail ?? VodInfo.fromVodItem(item);
      final actions = _vodDetailActions;
      final ai = actions.isEmpty
          ? 0
          : _vodDetailAction.clamp(0, actions.length - 1);
      final show = session.seriesDetailItem;
      return VodTitlePane(
        item: item,
        info: info,
        actions: actions,
        actionIndex: ai,
        loading: session.vodDetailLoading,
        watched: show != null && session.isSeriesWatched(show),
        favorited: show != null && session.isSeriesFavorite(show),
        artCache: session.artwork,
        artScope: session.prefsScope,
        onAction: (id) => unawaited(_runVodDetailActionId(id)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _listHeaderExtent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'TITLES · $catTitle',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: shows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 24, 24),
                  child: Text(
                    session.seriesError ??
                        (session.seriesCatalogReady
                            ? (session.selectedSeriesCategoryId ==
                                      kFavoritesCategoryId
                                  ? 'No favorite TV shows yet.\n'
                                        'Open a title · Add to Favorites'
                                  : 'No shows in this category.')
                            : 'Loading TV shows…'),
                    style: theme.textTheme.bodyLarge,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    _syncVodGridMetrics(constraints);
                    final cols = _vodCols.clamp(1, kVodGridMaxCols);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      session.artwork.prefetchVod(
                        scope: session.prefsScope,
                        items: [
                          for (final s in shows)
                            (id: 's:${s.seriesId}', url: s.cover),
                        ],
                        focusIndex: _chanIndex,
                        cols: cols,
                      );
                    });
                    return GridView.builder(
                      controller: _chanScroll,
                      padding: const EdgeInsets.fromLTRB(
                        kVodGridPadding,
                        8,
                        kVodGridPadding,
                        16,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: kVodGridSpacing,
                        crossAxisSpacing: kVodGridSpacing,
                        childAspectRatio: kVodGridChildAspect,
                      ),
                      itemCount: shows.length,
                      itemBuilder: (context, i) {
                        final s = shows[i];
                        final selected = _chanIndex == i;
                        final focused = _column == 1 && selected;
                        final resume = session.seriesResume(s);
                        final epId = resume['episodeId'] ?? '';
                        final saved = session.episodeProgressById(epId);
                        final progress = saved > 15 ? 0.15 : 0.0;
                        return VodPosterTile(
                          title: s.name,
                          subtitle: _seriesTileSubtitle(s),
                          selected: selected,
                          focused: focused,
                          progress: progress,
                          watched: session.isSeriesWatched(s),
                          favorited: session.isSeriesFavorite(s),
                          posterUrl: s.cover,
                          artId: 's:${s.seriesId}',
                          artScope: session.prefsScope,
                          artCache: session.artwork,
                          onTap: () async {
                            setState(() {
                              _column = 1;
                              _chanIndex = i;
                            });
                            _rememberSeriesIndex();
                            await _activate();
                          },
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _seriesEpisodesPane(ThemeData theme) {
    final show = session.seriesDetailItem;
    final seasons = session.seriesCatalog?.seasons ?? const [];
    final loading = session.vodDetailLoading && seasons.isEmpty;
    final season = seasons.isEmpty
        ? null
        : seasons[_seasonIndex.clamp(0, seasons.length - 1)];
    final eps = season?.episodes ?? const [];
    final title = show?.name ?? session.vodDetail?.title ?? 'TV Show';
    final seasonLine = season == null
        ? (loading ? 'Loading seasons…' : 'No episodes from this panel.')
        : seasons.length > 1
        ? '${season.name}  ·  ${_seasonIndex + 1}/${seasons.length}'
        : season.name;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            seasonLine,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          if (seasons.length > 1) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: seasons.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final selected = i == _seasonIndex;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _seasonIndex = i;
                        _episodeIndex = 0;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _scrollToEpisodeIndex(0);
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline.withValues(
                                  alpha: 0.4,
                                ),
                        ),
                      ),
                      child: Text(
                        seasons[i].name,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: selected
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: loading
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      'Loading episodes…',
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : eps.isEmpty
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      'No episodes in this season.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : ListView.builder(
                    controller: _episodeScroll,
                    itemExtent: _rowExtent,
                    itemCount: eps.length,
                    itemBuilder: (context, i) {
                      final ep = eps[i];
                      final selected = _episodeIndex == i;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _BrowseTile(
                          label: ep.label,
                          subtitle: _episodeSubtitle(ep),
                          icon: session.isEpisodeWatched(ep)
                              ? null
                              : Icons.play_circle_outline,
                          watched: session.isEpisodeWatched(ep),
                          selected: selected,
                          onTap: () async {
                            setState(() => _episodeIndex = i);
                            await _playSelectedEpisode();
                          },
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            seasons.length > 1
                ? '↑↓ episodes · LB/RB season · A play · B back'
                : '↑↓ episodes · A play · B back',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  String? _episodeSubtitle(SeriesEpisode ep) {
    final bits = <String>[];
    final saved = session.episodeProgressSeconds(ep);
    final watched = session.isEpisodeWatched(ep);
    // Lead with Watched so a long plot cannot ellipsize it off the row.
    if (watched && saved <= 15) {
      bits.add('Watched');
    }
    if (ep.durationSecs > 0) {
      bits.add('${ep.durationSecs ~/ 60}m');
    }
    if (saved > 15) {
      bits.add('Resume ${saved ~/ 60}m');
    }
    if (ep.plot.isNotEmpty) bits.add(ep.plot);
    if (bits.isEmpty) return null;
    return bits.join(' · ');
  }

  String get _footerHint {
    if (_isPosterGuide) {
      if (_seriesEpisodesOpen) {
        final seasons = session.seriesCatalog?.seasons ?? const [];
        return seasons.length > 1
            ? '↑↓ episodes · LB/RB season · A play · B back'
            : '↑↓ episodes · A play · B back';
      }
      if (_vodDetailOpen) {
        return '↑↓ actions · A select · Y star · B back';
      }
      if (_column == 1) {
        return '↑↓←→ posters · A title · B cats · LB/RB section';
      }
      return '↑↓ cats · A open · LB/RB section · ☰ menu';
    }
    if (_column == 1) {
      if (_epgAwayFromNow) {
        return '↑↓ channels · A play · ← cats · B now · LB/RB section';
      }
      return '↑↓ channels · A play · ←/B cats · LB/RB section';
    }
    return '↑↓ cats · → guide · X hide · LB/RB section · ☰ menu';
  }

  /// Quit the process so Game Mode returns to Steam (no STEAM → Exit game).
  Future<void> _exitApp() async {
    try {
      await session
          .stopPlayback(notify: false)
          .timeout(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('sdtv: stop before exit: $e');
    }
    // Linux desktop / Deck: SystemNavigator.pop is unreliable; exit the process.
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final movies = _isMovies;
    final series = _isSeries;
    final cats = movies
        ? session.browseVodCategories
        : series
        ? session.browseSeriesCategories
        : session.browseCategories;
    final channels = session.channelsInCategory;
    final vods = session.vodInCategory;
    final shows = session.seriesInCategory;
    final user = session.userInfo?.username ?? 'user';
    final catTitle = cats.isEmpty
        ? 'All'
        : cats[_catIndex.clamp(0, cats.length - 1)].categoryName;

    return SdtvInputScope(
      onBack: _onBack,
      onMenu: _openMenu,
      onSearch: _openSearch,
      onFavorite: () {
        unawaited(_toggleFavorite());
      },
      onMute: () {
        if (session.isWatchingExternal) {
          unawaited(session.watchCycleMute());
        } else if (_searchOpen || _switchSourceOpen || _unfavOpen) {
          // Don't hide cats while searching / switching / confirming unfav.
        } else if (_manageCatsOpen) {
          unawaited(_toggleManageRow());
        } else if (!_menuOpen && !_aboutOpen) {
          // Guide: X hides the focused category (quick junk filter).
          unawaited(_hideFocusedCategory());
        }
      },
      onPageUp: () => _onPage(-1),
      onPageDown: () => _onPage(1),
      onConfirm: () {
        unawaited(_activate());
      },
      onDirection: (dir) {
        switch (dir) {
          case TraversalDirection.up:
            _moveVertical(-1);
          case TraversalDirection.down:
            _moveVertical(1);
          case TraversalDirection.left:
            _moveHorizontal(-1);
          case TraversalDirection.right:
            _moveHorizontal(1);
        }
      },
      extraActions: {
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            switch (intent.direction) {
              case TraversalDirection.up:
                _moveVertical(-1);
              case TraversalDirection.down:
                _moveVertical(1);
              case TraversalDirection.left:
                _moveHorizontal(-1);
              case TraversalDirection.right:
                _moveHorizontal(1);
            }
            return null;
          },
        ),
        _JumpEpgNowIntent: CallbackAction<_JumpEpgNowIntent>(
          onInvoke: (_) {
            unawaited(_jumpEpgToNow());
            return null;
          },
        ),
      },
      extraShortcuts: {
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const DirectionalFocusIntent(TraversalDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const DirectionalFocusIntent(TraversalDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const DirectionalFocusIntent(TraversalDirection.left),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const DirectionalFocusIntent(TraversalDirection.right),
        const SdtvTypingSafeActivator(LogicalKeyboardKey.keyG):
            const _JumpEpgNowIntent(),
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              // The guide sits under mpv while watching. Pause its animations
              // so it does not compete with mpv and the HUD for the GPU.
              TickerMode(
                enabled: !session.isWatchingExternal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                      child: Row(
                        children: [
                          Text(
                            'sdtv',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(width: 28),
                          _SectionChip(
                            label: 'LIVE TV',
                            selected: _isLive,
                            focused: _sectionFocus && _isLive,
                          ),
                          const SizedBox(width: 4),
                          _SectionChip(
                            label: 'MOVIES',
                            selected: movies,
                            focused: _sectionFocus && movies,
                          ),
                          if (session.seriesAvailable) ...[
                            const SizedBox(width: 4),
                            _SectionChip(
                              label: 'TV SHOWS',
                              selected: series,
                              focused: _sectionFocus && series,
                            ),
                          ],
                          const Spacer(),
                          // Deploy fingerprint — must change after each package-deck.
                          Text(
                            SdtvBuildInfo.label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.outline.withValues(
                                alpha: 0.6,
                              ),
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(width: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                            child: Text(
                              session.useDemo
                                  ? 'DEMO'
                                  : session.useM3u
                                  ? 'M3U'
                                  : session.mockCatalog
                                  ? 'MOCK'
                                  : 'XTREAM',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Icon(
                            Icons.account_circle_outlined,
                            size: 20,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            user,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.75,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 250,
                            child: ListView.builder(
                              controller: _catScroll,
                              padding: const EdgeInsets.fromLTRB(16, 8, 10, 24),
                              itemCount: cats.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  final hiddenN = session.hiddenCategoryCount;
                                  return SizedBox(
                                    height: _listHeaderExtent,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        movies
                                            ? (session.vodError ??
                                                  (hiddenN > 0
                                                      ? 'MOVIES · $hiddenN hidden'
                                                      : 'MOVIES'))
                                            : series
                                            ? (session.seriesError ??
                                                  (hiddenN > 0
                                                      ? 'TV SHOWS · $hiddenN hidden'
                                                      : 'TV SHOWS'))
                                            : (hiddenN > 0
                                                  ? 'CATEGORIES · $hiddenN hidden'
                                                  : 'CATEGORIES'),
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme.colorScheme.outline,
                                              letterSpacing: 1.1,
                                            ),
                                      ),
                                    ),
                                  );
                                }
                                final i = index - 1;
                                // Show cursor even when focus is on the other column.
                                final selected = _catIndex == i;
                                final focused =
                                    !_sectionFocus && _column == 0 && selected;
                                final isFavCat =
                                    cats[i].categoryId == kFavoritesCategoryId;
                                final favN = movies
                                    ? session.vodFavoriteCount
                                    : series
                                    ? session.seriesFavoriteCount
                                    : session.favoriteCount;
                                return SizedBox(
                                  height: _catRowExtent,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: _CategoryRow(
                                      // The row draws its own star icon.
                                      label: isFavCat
                                          ? cats[i].categoryName
                                                .replaceFirst('★', '')
                                                .trim()
                                          : cats[i].categoryName,
                                      count: isFavCat && favN > 0 ? favN : null,
                                      icon: isFavCat ? Icons.star_rounded : null,
                                      selected: focused,
                                      dimSelected: selected && !focused,
                                      onTap: () {
                                        setState(() {
                                          _catIndex = i;
                                          _column = 0;
                                          _sectionFocus = false;
                                        });
                                        if (movies) {
                                          session.selectVodCategory(
                                            cats[i].categoryId,
                                          );
                                        } else if (series) {
                                          session.selectSeriesCategory(
                                            cats[i].categoryId,
                                          );
                                        } else {
                                          _selectCategoryKeepingChanPos(
                                            cats[i].categoryId,
                                          );
                                        }
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          VerticalDivider(
                            width: 1,
                            color: theme.colorScheme.outline.withValues(
                              alpha: 0.3,
                            ),
                          ),
                          Expanded(
                            child: movies
                                ? _moviesPane(theme, catTitle, vods)
                                : series
                                ? _seriesPane(theme, catTitle, shows)
                                : EpgGuidePane(
                                    channels: channels,
                                    channelIndex: _chanIndex,
                                    categoryTitle: catTitle,
                                    windowStart: _epgWindowNow,
                                    focusTime: _epgFocusNow,
                                    now: DateTime.now(),
                                    epgFor: session.cachedFullEpg,
                                    isFavorite: session.isFavorite,
                                    artwork: session.artwork,
                                    artworkScope: session.prefsScope,
                                    scrollController: _epgScroll,
                                    gridFocused: !_sectionFocus && _column == 1,
                                    m3u:
                                        session.useM3u &&
                                        !session.mockCatalog &&
                                        !session.useDemo,
                                    emptyMessage: session.isFavoritesCategory
                                        ? 'No favorites yet.\n'
                                              'Open any category · highlight a channel · Y to star'
                                        : 'No channels in this category.',
                                    onProgramWidth: (w) {
                                      if ((w - _epgProgramWidth).abs() < 1) {
                                        return;
                                      }
                                      _epgProgramWidth = w;
                                    },
                                    onTapChannel: (i) {
                                      setState(() {
                                        _chanIndex = i;
                                        _column = 1;
                                        _sectionFocus = false;
                                      });
                                      _rememberChanIndex();
                                      session.prefetchFullEpgAround(
                                        channels,
                                        i,
                                      );
                                    },
                                    onLongPressChannel: (i) {
                                      setState(() {
                                        _chanIndex = i;
                                        _column = 1;
                                        _sectionFocus = false;
                                      });
                                      _rememberChanIndex();
                                      unawaited(_toggleFavorite());
                                    },
                                    onTapProgram: (i, p) {
                                      setState(() {
                                        _chanIndex = i;
                                        _column = 1;
                                        _sectionFocus = false;
                                        _epgFocusTime =
                                            p.isLiveAt(DateTime.now())
                                            ? DateTime.now()
                                            : p.start.add(
                                                const Duration(minutes: 1),
                                              );
                                      });
                                      unawaited(_playFocusedLive());
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                    _HintBar(hint: _footerHint),
                  ],
                ),
              ),

              // —— ☰ menu (left panel; no Navigator dialog) ——
              if (_menuOpen)
                Positioned.fill(
                  child: SideMenu(
                    entries: _menuEntries,
                    selected: _menuIndex.clamp(0, _menuEntries.length - 1),
                    accountLine:
                        '$user  ·  ${session.useDemo ? 'Demo' : session.useM3u ? 'M3U' : 'Xtream'}',
                    onTap: (i) => _runMenuAction(_menuEntries[i].id),
                    onDismiss: () => setState(() => _menuOpen = false),
                  ),
                ),

              if (session.isWatchingExternal)
                Positioned.fill(
                  child: IgnorePointer(
                    // The HUD is shown on mpv as a bitmap; here it only has
                    // to be painted so it can be captured. Shifted outside
                    // the window (the Stack clips it) it costs no blending
                    // or drawing, unlike a near-zero Opacity, which forced
                    // an offscreen full-screen layer on every Flutter frame.
                    child: FractionalTranslation(
                      translation: const Offset(-2, 0),
                      child: MpvFlutterHud(key: _mpvHudKey, session: session),
                    ),
                  ),
                ),

              // —— Settings (sub-panels below render on top of it) ——
              if (_settingsOpen)
                Positioned.fill(
                  child: SettingsPage(
                    entries: _settingsEntries,
                    selected: _settingsIndex.clamp(
                      0,
                      _settingsEntries.length - 1,
                    ),
                    onTap: (i) {
                      setState(() => _settingsIndex = i);
                      unawaited(_runSettingsAction(_settingsEntries[i].id));
                    },
                  ),
                ),

              // —— Switch saved playlist ——
              if (_switchSourceOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _switchSourceOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 480,
                      maxHeight: 480,
                    ),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Switch playlist',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Saved on this device · A opens · B closes',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: ListView.builder(
                                controller: _switchScroll,
                                itemCount: session.savedSources.length,
                                itemBuilder: (context, i) {
                                  final s = session.savedSources[i];
                                  final selected = _switchSourceIndex == i;
                                  final active = session.activeSourceId == s.id;
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _BrowseTile(
                                      label: active
                                          ? '${s.kindBadge} · ${s.label}  · current'
                                          : '${s.kindBadge} · ${s.label}',
                                      icon: s.kind == SavedSourceKind.m3u
                                          ? Icons.playlist_play
                                          : s.kind == SavedSourceKind.xtream
                                          ? Icons.cloud_outlined
                                          : Icons.play_circle_outline,
                                      selected: selected,
                                      onTap: () async {
                                        setState(() => _switchSourceIndex = i);
                                        await _activateSwitchSource();
                                      },
                                    ),
                                  );
                                },
                              ),
                            ),
                            Text(
                              '↑↓ move · A switch · B close · Sign out to add new',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              // —— Search page (Live TV / Movies / TV Shows rows) ——
              if (_searchOpen)
                Positioned.fill(
                  child: SearchPage(
                    controller: _searchCtrl,
                    fieldFocus: _searchFocus,
                    resultsFocus: _searchListFocus,
                    rows: _searchRows,
                    browsing: _searchBrowseResults,
                    row: _searchRow,
                    col: _searchCols.isEmpty
                        ? 0
                        : _searchCols[_searchRow.clamp(
                            0,
                            _searchCols.length - 1,
                          )],
                    loading:
                        (session.moviesAvailable && !session.vodCatalogReady) ||
                        (session.seriesAvailable &&
                            !session.seriesCatalogReady),
                    artwork: session.artwork,
                    artworkScope: session.prefsScope,
                    onTapHit: (r, c) async {
                      setState(() {
                        _searchRow = r;
                        _searchCols = [..._searchCols];
                        _searchCols[r] = c;
                      });
                      await _applySearchHit(_searchRows[r].hits[c]);
                    },
                  ),
                ),

              // —— Manage categories (Settings page: reorder / hide) ——
              if (_manageCatsOpen)
                Positioned.fill(
                  child: Builder(
                    builder: (context) {
                      final cats = session.orderedCategories;
                      return ManageCategoriesPage(
                        names: [for (final c in cats) c.categoryName],
                        hidden: [
                          for (final c in cats)
                            session.isCategoryHidden(c.categoryId),
                        ],
                        selected: cats.isEmpty
                            ? 0
                            : _manageIndex.clamp(0, cats.length - 1),
                        moving: _manageMoving,
                        scrollController: _manageScroll,
                        onTap: (i) => setState(() {
                          if (_manageIndex == i) {
                            _manageMoving = !_manageMoving;
                          } else {
                            _manageIndex = i;
                            _manageMoving = false;
                          }
                        }),
                      );
                    },
                  ),
                ),

              // —— In-page about ——
              if (_aboutOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _aboutOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'About sdtv',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'sdtv — Steam Deck IPTV player.\n'
                              'Build: ${SdtvBuildInfo.label}\n'
                              'Demo = offline mock. M3U = playlist URL. '
                              'Connect = Xtream panel.\n'
                              'You supply legal playlists/credentials only.\n\n'
                              'Signed in as $user'
                              '${session.useDemo
                                  ? ' (demo)'
                                  : session.useM3u
                                  ? ' (m3u)'
                                  : session.mockCatalog
                                  ? ' (mock)'
                                  : ' (live)'}\n'
                              'Channels: ${session.allChannels.length}\n'
                              'Last played: ${session.lastPlayedName ?? '—'}'
                              '${session.lastPlayedCategoryId != null ? ' · ${session.lastPlayedCategoryId}' : ''}\n\n'
                              'Product of the Wangcow Corporation\n'
                              'Apache License 2.0',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 20),
                            _BrowseTile(
                              label: 'Close',
                              icon: Icons.close,
                              selected: true,
                              onTap: () => setState(() => _aboutOpen = false),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'A or B to close',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              // —— Confirm remove from favorites ——
              if (_unfavOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _closeUnfav,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Remove from favorites?',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(_unfavName, style: theme.textTheme.bodyLarge),
                            const SizedBox(height: 20),
                            _BrowseTile(
                              label: 'Keep',
                              icon: Icons.star_rounded,
                              selected: _unfavIndex == 0,
                              onTap: () {
                                setState(() => _unfavIndex = 0);
                                unawaited(_resolveUnfav());
                              },
                            ),
                            const SizedBox(height: 8),
                            _BrowseTile(
                              label: 'Remove',
                              icon: Icons.star_border_rounded,
                              selected: _unfavIndex == 1,
                              danger: true,
                              onTap: () {
                                setState(() => _unfavIndex = 1);
                                unawaited(_resolveUnfav());
                              },
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '↑↓ choose · A confirm · B keep',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Top-bar section tab: text with an underline when selected, a pill when
/// the pad is on the tabs.
class _SectionChip extends StatelessWidget {
  const _SectionChip({
    required this.label,
    required this.selected,
    required this.focused,
  });

  final String label;
  final bool selected;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = focused
        ? scheme.onPrimary
        : selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      decoration: BoxDecoration(
        color: focused ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: fg,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            height: 3,
            width: 24,
            decoration: BoxDecoration(
              color: selected && !focused ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Footer controls as key caps (`A`) followed by what they do (`play`).
///
/// Reads the same `KEY action · KEY action` strings the page already builds,
/// so the wording stays in one place.
class _HintBar extends StatelessWidget {
  const _HintBar({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parts = [
      for (final seg in hint.split('·'))
        if (seg.trim().isNotEmpty) seg.trim(),
    ];
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          for (final part in parts) ...[
            _hint(theme, part),
            const SizedBox(width: 22),
          ],
        ],
      ),
    );
  }

  Widget _hint(ThemeData theme, String part) {
    final space = part.indexOf(' ');
    final key = space < 0 ? part : part.substring(0, space);
    final action = space < 0 ? '' : part.substring(space + 1);
    final scheme = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.2)),
          ),
          child: Text(
            key,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (action.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            action,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }
}

/// One row of the guide's category column: flat, single line, TiviMate-style.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.count,
    this.dimSelected = false,
  });

  final String label;
  final IconData? icon;
  final int? count;

  /// The pad is on this row.
  final bool selected;

  /// This is the open category while the pad is on the grid.
  final bool dimSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary
              : dimSelected
              ? scheme.primary.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: dimSelected && !selected
              ? Border(left: BorderSide(color: scheme.primary, width: 3))
              : null,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 20,
                color: selected ? fg : Colors.amber.shade400,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: fg.withValues(alpha: selected || dimSelected ? 1 : 0.8),
                  fontWeight: selected || dimSelected
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
            ),
            if (count != null)
              Text(
                '$count',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BrowseTile extends StatelessWidget {
  const _BrowseTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.danger = false,
    this.watched = false,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// Finished episode (or other played row). Green check, muted label
  /// unless this row is the cursor.
  final bool watched;

  /// Destructive action (e.g. Sign out) — red styling so it is harder to mis-hit.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = selected;
    final dangerColor = theme.colorScheme.error;
    final Color bg;
    final Color fg;
    if (danger && selected) {
      bg = dangerColor;
      fg = theme.colorScheme.onError;
    } else if (danger) {
      bg = dangerColor.withValues(alpha: 0.18);
      fg = dangerColor;
    } else if (selected) {
      bg = theme.colorScheme.primary;
      fg = theme.colorScheme.onPrimary;
    } else if (watched) {
      bg = theme.colorScheme.surfaceContainerHighest;
      fg = theme.colorScheme.onSurface.withValues(alpha: 0.5);
    } else {
      bg = theme.colorScheme.surfaceContainerHighest;
      fg = theme.colorScheme.onSurface;
    }

    final borderColor = danger
        ? (selected ? dangerColor : dangerColor.withValues(alpha: 0.7))
        : (active ? theme.colorScheme.primaryContainer : Colors.transparent);

    final subColor = selected
        ? fg.withValues(alpha: 0.88)
        : watched
        ? theme.colorScheme.onSurface.withValues(alpha: 0.42)
        : theme.colorScheme.onSurface.withValues(alpha: 0.65);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 3),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: (danger ? dangerColor : theme.colorScheme.primary)
                        .withValues(alpha: 0.45),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            if (watched) ...[
              const WatchedCheckMark(size: 28),
              const SizedBox(width: 10),
            ] else if (icon != null) ...[
              Icon(icon, color: fg, size: 26),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: fg,
                      fontWeight: active || danger
                          ? FontWeight.w700
                          : FontWeight.w500,
                      height: 1.15,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: subColor,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JumpEpgNowIntent extends Intent {
  const _JumpEpgNowIntent();
}
