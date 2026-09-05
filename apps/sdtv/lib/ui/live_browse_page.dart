import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../build_info.dart';
import '../services/saved_source.dart';
import '../state/session_controller.dart';
import 'epg_grid.dart';
import 'player_page.dart';
import 'vod_grid.dart';
import 'widgets/epg_guide_pane.dart';
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
  bool _aboutOpen = false;
  bool _manageCatsOpen = false;
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
  int _searchIndex = 0;
  int _switchSourceIndex = 0;
  int _unfavIndex = 0;
  LiveChannel? _unfavChannel;

  final _catScroll = ScrollController();
  final _chanScroll = ScrollController();
  final _manageScroll = ScrollController();
  final _searchScroll = ScrollController();
  final _switchScroll = ScrollController();
  final _episodeScroll = ScrollController();
  final _epgScroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<GuideSearchHit> _searchHits = const [];

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
  static const _listHeaderExtent = 44.0;

  /// Movies poster grid (LayoutBuilder keeps these in sync with width).
  int _vodCols = 4;
  double _vodRowExtent = 240;

  /// Sign out is red, between Cancel and Exit, so destructive actions sit at the bottom.
  static const _menuItems =
      <({String id, String label, IconData icon, bool danger})>[
    (id: 'search', label: 'Search', icon: Icons.search, danger: false),
    (
      id: 'switch_source',
      label: 'Switch playlist',
      icon: Icons.swap_horiz,
      danger: false
    ),
    (
      id: 'chrome_spike',
      label: 'Embedded player (slow)',
      icon: Icons.smart_display_outlined,
      danger: false
    ),
    (
      id: 'hide_cat',
      label: 'Hide category',
      icon: Icons.visibility_off_outlined,
      danger: false
    ),
    (
      id: 'manage_cats',
      label: 'Manage categories',
      icon: Icons.category_outlined,
      danger: false
    ),
    (id: 'about', label: 'About', icon: Icons.info_outline, danger: false),
    (id: 'cancel', label: 'Cancel', icon: Icons.close, danger: false),
    (id: 'signout', label: 'Sign out', icon: Icons.logout, danger: true),
    (
      id: 'exit',
      label: 'Exit sdtv',
      icon: Icons.power_settings_new,
      danger: false
    ),
  ];

  SessionController get session => widget.session;

  bool get _isLive => session.guideSection == GuideSection.live;
  bool get _isMovies => session.guideSection == GuideSection.movies;
  bool get _isSeries => session.guideSection == GuideSection.series;
  bool get _isPosterGuide => _isMovies || _isSeries;

  bool get _overlayOpen =>
      _menuOpen ||
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
          itemExtent: _rowExtent,
          headerExtent: _listHeaderExtent,
        );
      });
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _searchCtrl.removeListener(_onSearchQueryChanged);
    SdtvTextFocusRegistry.unregister(_searchFocus);
    _searchCtrl.dispose();
    _searchFocus.onKeyEvent = null;
    _searchFocus.dispose();
    _catScroll.dispose();
    _chanScroll.dispose();
    _manageScroll.dispose();
    _searchScroll.dispose();
    _switchScroll.dispose();
    _episodeScroll.dispose();
    _epgScroll.dispose();
    _epgClock?.cancel();
    super.dispose();
  }

  void _onSearchQueryChanged() {
    if (!_searchOpen) return;
    final hits = session.searchGuide(_searchCtrl.text);
    setState(() {
      // New glyphs = still typing. Re-lock so OSK A cannot play a hit.
      _searchBrowseResults = false;
      _searchHits = hits;
      _searchIndex = hits.isEmpty ? 0 : _searchIndex.clamp(0, hits.length - 1);
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
        _episodeIndex =
            eps.isEmpty ? 0 : _episodeIndex.clamp(0, eps.length - 1);
      }
    }
    if (_searchOpen) {
      _searchHits = session.searchGuide(_searchCtrl.text);
      _searchIndex = _searchHits.isEmpty
          ? 0
          : _searchIndex.clamp(0, _searchHits.length - 1);
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
    final offset =
        (headerExtent + index * itemExtent).clamp(0.0, c.position.maxScrollExtent);
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

  void _scrollToChannelIndex(int index) {
    _ensureIndexVisible(
      _chanScroll,
      index,
      itemExtent: _rowExtent,
      headerExtent: _listHeaderExtent,
    );
  }

  void _scrollToSearchIndex(int index) {
    _ensureIndexVisible(
      _searchScroll,
      index,
      itemExtent: _rowExtent,
      headerExtent: 0,
    );
  }

  void _scrollToManageIndex(int index) {
    // Defer until after setState so maxScrollExtent is correct.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_manageCatsOpen) return;
      _ensureIndexVisible(
        _manageScroll,
        index,
        itemExtent: _rowExtent,
        headerExtent: 0,
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
      final id = session.selectedSeriesCategoryId ??
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
    final id = session.selectedVodCategoryId ??
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
        itemExtent: _rowExtent,
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
    _ensureIndexVisible(
      _epgScroll,
      index,
      itemExtent: kEpgRowExtent,
    );
  }

  void _moveVertical(int delta) {
    // Watching + menu open: D-pad navigates the pause menu (not volume).
    if (session.isWatchMenuActive && !_overlayOpen) {
      unawaited(session.watchMenuMove(delta));
      return;
    }
    // Watching, menu closed: ↑↓ = volume.
    // delta < 0 = up → louder; delta > 0 = down → quieter.
    if (session.isWatchingExternal && !_overlayOpen) {
      unawaited(session.watchVolumeDelta(delta < 0 ? 5 : -5));
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
      // OSK uses D-pad to pick keys. Do not steal the field until B / RB.
      if (!_searchBrowseResults) return;
      if (!_acceptNav()) return;
      if (_searchHits.isEmpty || (delta < 0 && _searchIndex <= 0)) {
        _returnToSearchField();
        return;
      }
      setState(() {
        _searchIndex =
            (_searchIndex + delta).clamp(0, _searchHits.length - 1);
      });
      _scrollToSearchIndex(_searchIndex);
      return;
    }
    if (_manageCatsOpen) {
      if (!_acceptNav()) return;
      final n = session.categories.length;
      if (n == 0) return;
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
        _menuIndex = (_menuIndex + delta).clamp(0, _menuItems.length - 1);
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
        itemExtent: _rowExtent,
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
    // Watching + menu: ←/→ adjust current row (subs / audio / mute).
    if (session.isWatchMenuActive && !_overlayOpen) {
      unawaited(session.watchMenuAdjust(delta));
      return;
    }
    if (_sectionFocus && !session.isWatchingExternal && !_overlayOpen) {
      unawaited(_cycleSection(delta > 0 ? 1 : -1));
      return;
    }

    // Watching, menu closed: ←/→ = previous / next channel (or VOD seek).
    if (session.isWatchingExternal && !_overlayOpen) {
      unawaited(session.watchChannelAdjacent(delta));
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
    if (_isLive && _column == 1) {
      _moveEpgProgram(delta);
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
        itemExtent: _rowExtent,
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
    if (session.isWatchMenuActive) {
      unawaited(session.watchMenuMove(delta));
      return;
    }
    if (session.isWatchingExternal) {
      unawaited(session.watchChannelAdjacent(delta));
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
    if (_isLive && _column == 1) {
      if (!_acceptNav()) return;
      _shiftEpgWindow(delta < 0 ? -kEpgJump : kEpgJump);
      return;
    }
    if (_column == 0) {
      _moveVertical(delta);
    } else if (_isPosterGuide) {
      if (!_acceptNav()) return;
      _applyVodGridMove(dy: delta * 2);
    } else {
      _moveVertical(delta * 5);
    }
  }

  DateTime? _lastActivateAt;

  Future<void> _activate() async {
    // Belt-and-suspenders vs dual js+Enter on Deck.
    final now = DateTime.now();
    if (_lastActivateAt != null &&
        now.difference(_lastActivateAt!) < const Duration(milliseconds: 280)) {
      return;
    }
    _lastActivateAt = now;

    // While mpv is up: A opens/activates the watch menu (not the guide menu).
    if (session.isWatchingExternal) {
      if (_overlayOpen) {
        await session.watchQuit();
      } else {
        await session.watchActivate();
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
      await _toggleManageRow();
      return;
    }

    if (_menuOpen) {
      await _runMenuAction(_menuItems[_menuIndex].id);
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

  Future<void> _playFocusedLive() async {
    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    _rememberChanIndex();

    final err = await session.watchChannel(ch);
    if (!mounted) return;

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Embedded',
            onPressed: () {
              unawaited(_playEmbedded(ch));
            },
          ),
        ),
      );
    } else if (session.needsAppRestartForFullDisplay) {
      session.clearDisplayRestartHint();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Docked at handheld resolution — STEAM → Exit sdtv → open again '
            'for full TV (Native applies on launch only)',
          ),
          duration: Duration(seconds: 8),
        ),
      );
    }

    if (mounted) {
      setState(() => _column = 1);
      if (_isLive) {
        _scrollToEpgIndex(_chanIndex);
      } else {
        _scrollToChannelIndex(_chanIndex);
      }
    }
  }

  /// Chrome spike / fallback: Flutter texture player + [PlayerPage] HUD.
  Future<void> _playEmbedded(LiveChannel ch) async {
    final err = await session.playChannel(ch);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Chrome spike: $err'),
          duration: const Duration(seconds: 6),
        ),
      );
      // Still open the page so the user can read on-screen error + A retry.
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(session: session),
      ),
    );
    if (!mounted) return;
    try {
      await session.stopPlayback(notify: false).timeout(
            const Duration(seconds: 2),
          );
    } catch (e) {
      debugPrint('sdtv: stop after embedded player: $e');
    }
    if (mounted) setState(() => _column = 1);
  }

  /// Hierarchical back: about → manage → menu → categories ← channels.
  /// While watching: B closes watch menu first, else quits to guide.
  void _onBack() {
    if (session.isWatchingExternal) {
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
      setState(() => _manageCatsOpen = false);
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
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
        itemExtent: _rowExtent,
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
      itemExtent: _rowExtent,
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
      setState(() => _manageCatsOpen = false);
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
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
      _unfavOpen = false;
      _unfavChannel = null;
      _searchOpen = true;
      _searchBrowseResults = false;
      _searchIndex = 0;
      _searchHits = session.searchGuide(_searchCtrl.text);
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
    setState(() {
      _searchHits = session.searchGuide(_searchCtrl.text);
      _searchIndex = _searchHits.isEmpty
          ? 0
          : _searchIndex.clamp(0, _searchHits.length - 1);
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchOpen = false;
      _searchBrowseResults = false;
      _searchIndex = 0;
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

  Duration get _epgWindowLength => epgWindowLength(_epgProgramWidth);

  void _leaveEpgToCategories() {
    _rememberChanIndex();
    setState(() => _column = 0);
    _scrollTo(
      _catScroll,
      _catIndex,
      itemExtent: _rowExtent,
      headerExtent: _listHeaderExtent,
    );
  }

  void _moveEpgProgram(int delta) {
    final chans = session.channelsInCategory;
    if (chans.isEmpty) {
      if (delta < 0) _leaveEpgToCategories();
      return;
    }
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    final epg = session.cachedFullEpg(ch);
    final listings = epg?.listings ?? const <EpgProgram>[];
    if (listings.isEmpty) {
      if (delta < 0) {
        _leaveEpgToCategories();
        return;
      }
      _shiftEpgWindow(kEpgSlot);
      return;
    }
    final i = epg!.indexForTime(_epgFocusTime);
    if (delta < 0 && i <= 0) {
      _leaveEpgToCategories();
      return;
    }
    final next = (i + delta).clamp(0, listings.length - 1);
    if (next == i) {
      _shiftEpgWindow(delta > 0 ? kEpgSlot : -kEpgSlot);
      return;
    }
    final p = listings[next];
    final t = p.isLiveAt(DateTime.now())
        ? DateTime.now()
        : p.start.add(const Duration(minutes: 1));
    setState(() {
      _epgFocusTime = t;
      _epgWindowStart = epgEnsureVisible(
        windowStart: _epgWindowStart,
        windowLength: _epgWindowLength,
        start: p.start,
        end: p.end,
      );
    });
  }

  void _shiftEpgWindow(Duration delta) {
    final next = epgShiftWindow(_epgWindowStart, delta);
    final len = _epgWindowLength;
    var t = _epgFocusTime.add(delta);
    if (t.isBefore(next)) {
      t = next.add(const Duration(minutes: 1));
    } else if (!t.isBefore(next.add(len))) {
      t = next.add(len).subtract(const Duration(minutes: 1));
    }
    setState(() {
      _epgWindowStart = next;
      _epgFocusTime = t;
    });
    session.prefetchFullEpgAround(session.channelsInCategory, _chanIndex);
  }

  void _enterSearchResults() {
    if (!_searchOpen) return;
    _searchFocus.unfocus();
    setState(() => _searchBrowseResults = true);
    if (_searchHits.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _scrollToSearchIndex(_searchIndex);
      });
    }
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
    if (_searchHits.isEmpty) return;
    final hit = _searchHits[_searchIndex.clamp(0, _searchHits.length - 1)];
    await _applySearchHit(hit);
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
      catIdx = session.browseCategories
          .indexWhere((c) => c.categoryId == catId);
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
        itemExtent: _rowExtent,
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
        itemExtent: _rowExtent,
        headerExtent: _listHeaderExtent,
      );
      _scrollToVodIndex(idx);
    });
  }

  Future<void> _runMenuAction(String id) async {
    setState(() => _menuOpen = false);
    if (id == 'cancel') return;
    if (id == 'search') {
      _openSearch();
      return;
    }
    if (id == 'switch_source') {
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
      return;
    }
    if (id == 'chrome_spike') {
      // Experimental Flutter-texture path. Daily watch is A → external mpv.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Embedded is experimental and janky. '
            'A play uses smooth mpv (OSD chrome on the video).',
          ),
          duration: Duration(seconds: 5),
        ),
      );
      final chans = session.channelsInCategory;
      if (chans.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Highlight a channel first, then open Chrome spike'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
      setState(() => _column = 1);
      _rememberChanIndex();
      await _playEmbedded(ch);
      return;
    }
    if (id == 'hide_cat') {
      await _hideFocusedCategory();
      return;
    }
    if (id == 'manage_cats') {
      setState(() {
        _manageCatsOpen = true;
        _manageIndex = 0;
      });
      return;
    }
    if (id == 'about') {
      setState(() => _aboutOpen = true);
      return;
    }
    if (id == 'signout') {
      await session.signOut();
      return;
    }
    if (id == 'exit') {
      await _exitApp();
    }
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
        content: Text('Hidden: $name · ☰ Manage categories to restore'),
        duration: const Duration(seconds: 3),
      ),
    );
    setState(() {
      _column = 0;
    });
  }

  Future<void> _toggleManageRow() async {
    final all = session.categories;
    if (all.isEmpty) return;
    final i = _manageIndex.clamp(0, all.length - 1);
    final cat = all[i];
    // No SnackBar here — bulk hide would queue dozens of toasts.
    // Tile label/icon + header counts already update in place.
    await session.toggleCategoryHidden(cat.categoryId);
    if (mounted) setState(() {});
  }

  /// Y / F: star or unstar channel (guide focus, or now-playing while watching).
  Future<void> _toggleFavorite() async {
    if (_overlayOpen) return;
    _lastFavoriteAt = DateTime.now();

    LiveChannel? ch;
    if (session.isWatchingExternal) {
      // Search → play → Y used to no-op here; star the playing channel instead.
      ch = session.nowPlaying;
    } else if (_column == 1) {
      final chans = session.channelsInCategory;
      if (chans.isNotEmpty) {
        ch = chans[_chanIndex.clamp(0, chans.length - 1)];
      }
    }

    if (ch == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Highlight a channel (or play one), then Y to favorite'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Guide: confirm before removing a star. Add is still one-shot.
    // While mpv is up the overlay would be hidden, so unstar stays immediate.
    if (session.isFavorite(ch) && !session.isWatchingExternal) {
      setState(() {
        _unfavOpen = true;
        _unfavIndex = 0;
        _unfavChannel = ch;
      });
      return;
    }

    await _applyFavoriteToggle(ch);
  }

  void _closeUnfav() {
    setState(() {
      _unfavOpen = false;
      _unfavIndex = 0;
      _unfavChannel = null;
    });
  }

  Future<void> _resolveUnfav() async {
    final ch = _unfavChannel;
    final remove = _unfavIndex == 1;
    _closeUnfav();
    if (!remove || ch == null) return;
    await _applyFavoriteToggle(ch);
  }

  Future<void> _applyFavoriteToggle(LiveChannel ch) async {
    final nowFav = await session.toggleFavorite(ch);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFav ? '★ ${ch.name}' : '☆ Removed ${ch.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
    setState(() {});
  }

  List<({String id, String label, IconData icon})> get _vodDetailActions {
    final series = session.seriesDetailItem;
    if (series != null) return _seriesDetailActions(series);

    final item = session.vodDetailItem;
    final info = session.vodDetail ??
        (item != null ? VodInfo.fromVodItem(item) : null);
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
      out.add((
        id: 'start',
        label: 'Play Now',
        icon: Icons.play_arrow_rounded,
      ));
    }
    if (info != null && info.hasTrailer) {
      out.add((
        id: 'trailer',
        label: 'Watch trailer',
        icon: Icons.theaters_outlined,
      ));
    }
    return out;
  }

  List<({String id, String label, IconData icon})> _seriesDetailActions(
    SeriesItem series,
  ) {
    final info = session.vodDetail ?? VodInfo.fromVodItem(series.asVodItem);
    final cat = session.seriesCatalog;
    final resume = session.seriesResume(series);
    final epId = resume['episodeId'] ?? '';
    final resumeEp = epId.isEmpty ? null : cat?.episodeById(epId);
    final saved =
        resumeEp == null ? 0 : session.episodeProgressSeconds(resumeEp);
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
      out.add((
        id: 'start',
        label: 'Play Now',
        icon: Icons.play_arrow_rounded,
      ));
    }
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
    final err = await session.watchSeriesEpisode(
      show,
      ep,
      fromBeginning: fromBeginning,
    );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), duration: const Duration(seconds: 6)),
      );
    }
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
    String? err;
    if (id == 'resume') {
      err = await session.watchVod(item);
    } else if (id == 'start') {
      err = await session.watchVod(item, fromBeginning: true);
    } else if (id == 'trailer') {
      final info = session.vodDetail ?? VodInfo.fromVodItem(item);
      err = await session.watchTrailer(info);
    }
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), duration: const Duration(seconds: 6)),
      );
    }
  }

  Future<void> _runSeriesDetailActionId(String id) async {
    final show = session.seriesDetailItem;
    if (show == null) return;
    if (id == 'seasons') {
      _openSeriesEpisodes();
      return;
    }
    String? err;
    if (id == 'trailer') {
      final info = session.vodDetail ?? VodInfo.fromVodItem(show.asVodItem);
      err = await session.watchTrailer(info);
    } else if (id == 'resume') {
      final cat = session.seriesCatalog;
      final epId = session.seriesResume(show)['episodeId'] ?? '';
      final ep = cat?.episodeById(epId) ?? cat?.firstEpisode;
      if (ep == null) {
        err = session.vodDetailLoading
            ? 'Loading episodes…'
            : 'No episodes for this show.';
      } else {
        err = await session.watchSeriesEpisode(show, ep);
      }
    } else if (id == 'start') {
      final ep = session.seriesCatalog?.firstEpisode;
      if (ep == null) {
        err = session.vodDetailLoading
            ? 'Loading episodes…'
            : 'No episodes for this show.';
      } else {
        err = await session.watchSeriesEpisode(
          show,
          ep,
          fromBeginning: true,
        );
      }
    }
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), duration: const Duration(seconds: 6)),
      );
    }
  }

  Widget _moviesPane(
    ThemeData theme,
    String catTitle,
    List<VodItem> vods,
  ) {
    if (_vodDetailOpen) {
      final item = session.vodDetailItem ??
          (vods.isEmpty
              ? null
              : vods[_chanIndex.clamp(0, vods.length - 1)]);
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
                            ? 'No movies in this category.'
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

  Widget _seriesPane(
    ThemeData theme,
    String catTitle,
    List<SeriesItem> shows,
  ) {
    if (_seriesEpisodesOpen) {
      return _seriesEpisodesPane(theme);
    }
    if (_vodDetailOpen) {
      final item = session.seriesDetailItem?.asVodItem ??
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
                            ? 'No shows in this category.'
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
                separatorBuilder: (context, index) =>
                    const SizedBox(width: 8),
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
                              : theme.colorScheme.outline
                                  .withValues(alpha: 0.4),
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
                                  ? Icons.check_circle
                                  : Icons.play_circle_outline,
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
    if (ep.durationSecs > 0) {
      bits.add('${ep.durationSecs ~/ 60}m');
    }
    final saved = session.episodeProgressSeconds(ep);
    if (saved > 15) {
      bits.add('Resume ${saved ~/ 60}m');
    } else if (session.isEpisodeWatched(ep)) {
      bits.add('Watched');
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
        return '↑↓ actions · A select · B back';
      }
      if (_column == 1) {
        return '↑↓←→ posters · A title · B cats · ☰ Search';
      }
      return '↑↓ cats · B top · A open · ☰ Search';
    }
    if (_column == 1) {
      if (_epgAwayFromNow) {
        return '↑↓ channels · ←→ programs · LB/RB time · A play · B now';
      }
      return '↑↓ channels · ←→ programs · LB/RB time · A play · B cats';
    }
    return '↑↓ cats · B top · → guide · X hide · ☰ Search';
  }

  /// Quit the process so Game Mode returns to Steam (no STEAM → Exit game).
  Future<void> _exitApp() async {
    try {
      await session.stopPlayback(notify: false).timeout(
            const Duration(seconds: 1),
          );
    } catch (e) {
      debugPrint('sdtv: stop before exit: $e');
    }
    try {
      await session.player.dispose().timeout(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('sdtv: dispose before exit: $e');
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                    child: Row(
                      children: [
                        _SectionChip(
                          label: 'LIVE',
                          selected: _isLive,
                          focused: _sectionFocus && _isLive,
                        ),
                        const SizedBox(width: 8),
                        _SectionChip(
                          label: 'MOVIES',
                          selected: movies,
                          focused: _sectionFocus && movies,
                        ),
                        if (session.seriesAvailable) ...[
                          const SizedBox(width: 8),
                          _SectionChip(
                            label: 'TV SHOWS',
                            selected: series,
                            focused: _sectionFocus && series,
                          ),
                        ],
                        const SizedBox(width: 16),
                        Text(
                          'sdtv',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            session.useDemo
                                ? 'DEMO'
                                : session.useM3u
                                    ? 'M3U'
                                    : session.mockCatalog
                                        ? 'MOCK'
                                        : 'LIVE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Deploy fingerprint — must change after each package-deck.
                        Text(
                          SdtvBuildInfo.label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const Spacer(),
                        Text(
                          user,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.outline,
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
                          width: 280,
                          child: ListView.builder(
                            controller: _catScroll,
                            padding: const EdgeInsets.fromLTRB(24, 8, 12, 24),
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
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
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
                              return SizedBox(
                                height: _rowExtent,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: _BrowseTile(
                                    label: isFavCat
                                        ? '${cats[i].categoryName}'
                                            '${session.favoriteCount > 0 ? ' (${session.favoriteCount})' : ''}'
                                        : cats[i].categoryName,
                                    icon: isFavCat
                                        ? Icons.star_rounded
                                        : Icons.folder_outlined,
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
                          color: theme.colorScheme.outline
                              .withValues(alpha: 0.3),
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
                                      windowStart: _epgWindowStart,
                                      focusTime: _epgFocusTime,
                                      now: DateTime.now(),
                                      epgFor: session.cachedFullEpg,
                                      scrollController: _epgScroll,
                                      gridFocused:
                                          !_sectionFocus && _column == 1,
                                      m3u: session.useM3u &&
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
                                          _epgFocusTime = p.isLiveAt(
                                            DateTime.now(),
                                          )
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
                  Container(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: theme.colorScheme.outline
                              .withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    child: Text(
                      _footerHint,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),

              // —— In-page menu (no Navigator dialog) ——
              if (_menuOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _menuOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
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
                              'Menu',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Signed in as $user'
                              '${session.useDemo ? ' (demo)' : ''}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 20),
                            for (var i = 0; i < _menuItems.length; i++) ...[
                              if (i > 0) const SizedBox(height: 8),
                              _BrowseTile(
                                label: _menuItems[i].label,
                                icon: _menuItems[i].icon,
                                selected: _menuIndex == i,
                                danger: _menuItems[i].danger,
                                onTap: () =>
                                    _runMenuAction(_menuItems[i].id),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(
                              '↑↓ move · A select · B close',
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
                                  final active =
                                      session.activeSourceId == s.id;
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

              // —— Guide search (live, movies, TV shows; EPG later) ——
              if (_searchOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _closeSearch,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 560,
                      maxHeight: 560,
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
                              'Search',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Live, movies & TV shows'
                              '${session.hiddenCategoryCount > 0 ? ' · hidden cats marked' : ''}'
                              ' · EPG later',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _searchCtrl,
                              focusNode: _searchFocus,
                              autofocus: true,
                              style: theme.textTheme.titleMedium,
                              decoration: InputDecoration(
                                hintText: 'e.g. bloomberg, batman, friends…',
                                prefixIcon: const Icon(Icons.search),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                              ),
                              // Done/Search on the OSK used to submit and play
                              // the first hit. Play only after ↓ to a result.
                              textInputAction: TextInputAction.none,
                              onEditingComplete: () {},
                              onSubmitted: (_) {},
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: _searchCtrl.text.trim().isEmpty
                                  ? Text(
                                      'Type with OSK · B to list · A jumps there · B close',
                                      style: theme.textTheme.bodyLarge,
                                    )
                                  : _searchHits.isEmpty
                                      ? Text(
                                          'No matches for “${_searchCtrl.text.trim()}”',
                                          style: theme.textTheme.bodyLarge,
                                        )
                                      : ListView.builder(
                                          controller: _searchScroll,
                                          itemExtent: _rowExtent,
                                          itemCount: _searchHits.length,
                                          itemBuilder: (context, i) {
                                            final hit = _searchHits[i];
                                            final selected = _searchBrowseResults &&
                                                _searchIndex == i;
                                            final icon = hit.isVod
                                                ? Icons.movie_outlined
                                                : hit.isSeries
                                                    ? Icons.tv_outlined
                                                    : hit.isCategory
                                                        ? Icons.folder_outlined
                                                        : hit.isEpg
                                                            ? Icons.event_outlined
                                                            : Icons.live_tv_outlined;
                                            final label = hit.subtitle.isEmpty
                                                ? hit.title
                                                : '${hit.title}  ·  ${hit.subtitle}';
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 6,
                                              ),
                                              child: _BrowseTile(
                                                label: label,
                                                icon: icon,
                                                selected: selected,
                                                onTap: () async {
                                                  setState(
                                                    () => _searchIndex = i,
                                                  );
                                                  await _applySearchHit(hit);
                                                },
                                              ),
                                            );
                                          },
                                        ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _searchBrowseResults
                                  ? '↑ search box · A jump · B close'
                                  : 'Steam+X OSK · B to list · A jump · B close',
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

              // —— Manage categories (show / hide) ——
              if (_manageCatsOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _manageCatsOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 480,
                      maxHeight: 520,
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
                              'Manage categories',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'A toggles hide/show · Hidden stay off the guide.\n'
                              'Hidden: ${session.hiddenCategoryCount} · '
                              'Visible: ${session.visibleCategories.length}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: session.categories.isEmpty
                                  ? Text(
                                      'No categories from provider.',
                                      style: theme.textTheme.bodyLarge,
                                    )
                                  : ListView.builder(
                                      controller: _manageScroll,
                                      // Fixed extent keeps scroll math aligned
                                      // with the highlight (same bug as search).
                                      itemExtent: _rowExtent,
                                      itemCount: session.categories.length,
                                      itemBuilder: (context, i) {
                                        final cat = session.categories[i];
                                        final hidden =
                                            session.isCategoryHidden(
                                          cat.categoryId,
                                        );
                                        final selected = _manageIndex == i;
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 6,
                                          ),
                                          child: _BrowseTile(
                                            label: hidden
                                                ? '${cat.categoryName}  · hidden'
                                                : cat.categoryName,
                                            icon: hidden
                                                ? Icons.visibility_off_outlined
                                                : Icons.visibility_outlined,
                                            selected: selected,
                                            onTap: () async {
                                              setState(() => _manageIndex = i);
                                              await _toggleManageRow();
                                            },
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '↑↓ move · A toggle · B close',
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
                              '${session.useDemo ? ' (demo)' : session.useM3u ? ' (m3u)' : session.mockCatalog ? ' (mock)' : ' (live)'}\n'
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
                              onTap: () =>
                                  setState(() => _aboutOpen = false),
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
                            Text(
                              _unfavChannel?.name ?? '',
                              style: theme.textTheme.bodyLarge,
                            ),
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
    final bg = focused
        ? theme.colorScheme.primary
        : selected
            ? theme.colorScheme.primary.withValues(alpha: 0.35)
            : theme.colorScheme.surfaceContainerHighest;
    final fg = focused ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focused || selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: fg,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
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
    this.dimSelected = false,
    this.danger = false,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// Soft highlight when this row is the cursor but the other column is focused.
  final bool dimSelected;

  /// Destructive action (e.g. Sign out) — red styling so it is harder to mis-hit.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = selected || dimSelected;
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
    } else if (dimSelected) {
      bg = theme.colorScheme.primary.withValues(alpha: 0.28);
      fg = theme.colorScheme.onSurface;
    } else {
      bg = theme.colorScheme.surfaceContainerHighest;
      fg = theme.colorScheme.onSurface;
    }

    final borderColor = danger
        ? (selected ? dangerColor : dangerColor.withValues(alpha: 0.7))
        : (active
            ? theme.colorScheme.primaryContainer
            : Colors.transparent);

    final subColor = selected
        ? fg.withValues(alpha: 0.88)
        : theme.colorScheme.onSurface.withValues(alpha: 0.65);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: borderColor,
            width: 3,
          ),
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
            if (icon != null) ...[
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
