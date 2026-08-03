import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../state/session_controller.dart';
import 'player_page.dart';

/// Two-column live browser with **explicit** column navigation.
///
/// Flutter's geometric [DirectionalFocus] is wrong for TiviMate-style grids
/// (Down jumps sideways into channels, Left/Right walk categories). We own
/// the D-pad: Up/Down within a column, Left/Right switch columns.
class LiveBrowsePage extends StatefulWidget {
  const LiveBrowsePage({super.key, required this.session});

  final SessionController session;

  @override
  State<LiveBrowsePage> createState() => _LiveBrowsePageState();
}

class _LiveBrowsePageState extends State<LiveBrowsePage> {
  /// 0 = categories, 1 = channels
  int _column = 0;
  int _catIndex = 0;
  int _chanIndex = 0;

  final _catScroll = ScrollController();
  final _chanScroll = ScrollController();
  final List<FocusNode> _catNodes = [];
  final List<FocusNode> _chanNodes = [];
  String? _lastCategoryId;

  SessionController get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    _rebuildCatNodes();
    _rebuildChanNodes();
    _lastCategoryId = session.selectedCategoryId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_catNodes.isNotEmpty) _catNodes[0].requestFocus();
    });
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _disposeNodes(_catNodes);
    _disposeNodes(_chanNodes);
    _catScroll.dispose();
    _chanScroll.dispose();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    if (_catNodes.length != session.categories.length) {
      _rebuildCatNodes();
    }
    // Always rebuild channel focus nodes when category changes (counts may match).
    if (session.selectedCategoryId != _lastCategoryId ||
        _chanNodes.length != session.channelsInCategory.length) {
      _lastCategoryId = session.selectedCategoryId;
      _rebuildChanNodes();
      _chanIndex = 0;
    }
    setState(() {});
  }

  void _disposeNodes(List<FocusNode> nodes) {
    for (final n in nodes) {
      n.dispose();
    }
    nodes.clear();
  }

  void _rebuildCatNodes() {
    _disposeNodes(_catNodes);
    for (var i = 0; i < session.categories.length; i++) {
      _catNodes.add(FocusNode(debugLabel: 'cat-$i'));
    }
    _catIndex = _catIndex.clamp(0, (_catNodes.length - 1).clamp(0, 9999));
  }

  void _rebuildChanNodes() {
    _disposeNodes(_chanNodes);
    for (var i = 0; i < session.channelsInCategory.length; i++) {
      _chanNodes.add(FocusNode(debugLabel: 'chan-$i'));
    }
    _chanIndex = _chanIndex.clamp(0, (_chanNodes.length - 1).clamp(0, 9999));
  }

  void _focusCurrent() {
    final nodes = _column == 0 ? _catNodes : _chanNodes;
    final idx = _column == 0 ? _catIndex : _chanIndex;
    if (nodes.isEmpty) return;
    final i = idx.clamp(0, nodes.length - 1);
    nodes[i].requestFocus();
    // Keep focused row visible.
    final controller = _column == 0 ? _catScroll : _chanScroll;
    if (controller.hasClients) {
      final offset = (i * 72.0).clamp(0.0, controller.position.maxScrollExtent);
      controller.animateTo(
        offset,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  void _moveVertical(int delta) {
    if (_column == 0) {
      if (_catNodes.isEmpty) return;
      _catIndex = (_catIndex + delta).clamp(0, _catNodes.length - 1);
      final cat = session.categories[_catIndex];
      session.selectCategory(cat.categoryId);
      // Channels rebuild via listener.
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrent());
    } else {
      if (_chanNodes.isEmpty) return;
      _chanIndex = (_chanIndex + delta).clamp(0, _chanNodes.length - 1);
      _focusCurrent();
    }
    setState(() {});
  }

  void _moveHorizontal(int delta) {
    if (delta > 0 && _column == 0) {
      _column = 1;
      if (_chanNodes.isEmpty) _rebuildChanNodes();
      _chanIndex = _chanIndex.clamp(0, (_chanNodes.length - 1).clamp(0, 9999));
    } else if (delta < 0 && _column == 1) {
      _column = 0;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrent());
  }

  Future<void> _activateCurrent() async {
    if (_column == 0) {
      if (_catNodes.isEmpty) return;
      final cat = session.categories[_catIndex];
      session.selectCategory(cat.categoryId);
      _column = 1;
      _chanIndex = 0;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrent());
      return;
    }
    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    await session.playChannel(ch);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(session: session),
      ),
    );
    await session.stopPlayback();
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrent());
    }
  }

  /// System menu — no nested gamepad scope (avoids freeze / stuck barrier).
  Future<void> _openSystemMenu() async {
    // If a route is already up, B closes it.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    final user = session.userInfo?.username ?? 'user';
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Menu'),
          content: Text(
            'Signed in as $user${session.useDemo ? ' (demo)' : ''}\n\n'
            'D-pad: move · A: select · B: close',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            // Column of focusables — parent page keeps pad; focus moves here.
            SizedBox(
              width: 320,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SdtvFocusTile(
                      label: 'About',
                      autofocus: true,
                      icon: Icons.info_outline,
                      onActivate: () => Navigator.of(ctx).pop('about'),
                    ),
                    const SizedBox(height: 8),
                    SdtvFocusTile(
                      label: 'Sign out',
                      icon: Icons.logout,
                      onActivate: () => Navigator.of(ctx).pop('signout'),
                    ),
                    const SizedBox(height: 8),
                    SdtvFocusTile(
                      label: 'Cancel',
                      icon: Icons.close,
                      onActivate: () => Navigator.of(ctx).pop('cancel'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    if (action == 'about') {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('About sdtv'),
          content: Text(
            'Live TV browse (Phase 1).\n'
            'Demo/mock catalog — no real streams until SDTV_ALLOW_LIVE=1.\n\n'
            'Signed in as $user'
            '${session.useDemo ? ' (demo)' : ''}\n\n'
            'Product of the Wangcow Corporation\n'
            'Apache License 2.0',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else if (action == 'signout') {
      // Pop is already done; tear down session.
      await session.signOut();
    }

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrent());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = session.categories;
    final channels = session.channelsInCategory;
    final selectedId = session.selectedCategoryId;
    final user = session.userInfo?.username ?? 'user';

    return SdtvInputScope(
      onBack: _openSystemMenu,
      onMenu: _openSystemMenu,
      onConfirm: () {
        // Prefer tile ActivateIntent; fallback activate current index.
        final focusCtx = FocusManager.instance.primaryFocus?.context;
        if (focusCtx != null) {
          final handled =
              Actions.maybeInvoke(focusCtx, const ActivateIntent());
          if (handled != null) return;
        }
        _activateCurrent();
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
      },
      extraShortcuts: {
        // When Steam injects arrows as keys
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const DirectionalFocusIntent(TraversalDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const DirectionalFocusIntent(TraversalDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const DirectionalFocusIntent(TraversalDirection.left),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const DirectionalFocusIntent(TraversalDirection.right),
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Row(
                  children: [
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
                        color: theme.colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        session.useDemo ? 'DEMO / MOCK' : 'LIVE TV',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
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
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                'CATEGORIES',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            );
                          }
                          final i = index - 1;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: SdtvFocusTile(
                              label: cats[i].categoryName,
                              focusNode: _catNodes[i],
                              autofocus: i == 0,
                              icon: Icons.folder_outlined,
                              onActivate: () {
                                _catIndex = i;
                                _column = 1;
                                session.selectCategory(cats[i].categoryId);
                                setState(() {});
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) {
                                  _chanIndex = 0;
                                  _focusCurrent();
                                });
                              },
                            ),
                          );
                        },
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      color: theme.colorScheme.outline.withValues(alpha: 0.3),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _chanScroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                        itemCount: channels.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            final title = () {
                              for (final c in cats) {
                                if (c.categoryId == selectedId) {
                                  return c.categoryName;
                                }
                              }
                              return 'All';
                            }();
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                'CHANNELS · $title',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            );
                          }
                          final i = index - 1;
                          final ch = channels[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: SdtvFocusTile(
                              label:
                                  '${ch.num > 0 ? '${ch.num}. ' : ''}${ch.name}',
                              focusNode:
                                  i < _chanNodes.length ? _chanNodes[i] : null,
                              icon: Icons.live_tv_outlined,
                              onActivate: () async {
                                _chanIndex = i;
                                _column = 1;
                                await session.playChannel(ch);
                                if (!context.mounted) return;
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        PlayerPage(session: session),
                                  ),
                                );
                                await session.stopPlayback();
                                if (mounted) {
                                  WidgetsBinding.instance
                                      .addPostFrameCallback(
                                          (_) => _focusCurrent());
                                }
                              },
                            ),
                          );
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
                      color: theme.colorScheme.outline.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '↑↓ list · ←→ columns · A open · B menu',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        'Product of the Wangcow Corporation',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
