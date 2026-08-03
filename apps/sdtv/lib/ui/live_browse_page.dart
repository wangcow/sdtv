import 'package:flutter/material.dart';
import 'package:sdtv_core/sdtv_core.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../state/session_controller.dart';
import 'player_page.dart';

class LiveBrowsePage extends StatelessWidget {
  const LiveBrowsePage({super.key, required this.session});

  final SessionController session;

  static String _categoryTitle(List<MediaCategory> cats, String? selectedId) {
    for (final c in cats) {
      if (c.categoryId == selectedId) return c.categoryName;
    }
    return 'All';
  }

  /// Dialogs must not open a second joystick reader — disable gamepad there
  /// and rely on the parent scope + keyboard/mouse for the modal.
  static Future<void> _confirmSignOut(
    BuildContext context,
    SessionController session,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SdtvInputScope(
        enableGamepad: false,
        onBack: () => Navigator.of(ctx).pop(false),
        child: AlertDialog(
          title: const Text('Sign out?'),
          content: const Text('Return to login and clear this session?'),
          actions: [
            SdtvFocusTile(
              label: 'Cancel',
              autofocus: true,
              onActivate: () {
                if (ctx.mounted) Navigator.of(ctx).pop(false);
              },
            ),
            const SizedBox(height: 8),
            SdtvFocusTile(
              label: 'Sign out',
              onActivate: () {
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              },
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await session.signOut();
    }
  }

  static void _showAbout(BuildContext context, String user, bool useDemo) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SdtvInputScope(
        enableGamepad: false,
        onBack: () => Navigator.of(ctx).pop(),
        onConfirm: () => Navigator.of(ctx).pop(),
        child: AlertDialog(
          title: const Text('About sdtv'),
          content: Text(
            'Live TV browse (Phase 1).\n'
            'Demo/mock catalog — no real streams until SDTV_ALLOW_LIVE=1.\n\n'
            'Signed in as $user'
            '${useDemo ? ' (demo)' : ''}\n\n'
            'Product of the Wangcow Corporation\n'
            'Apache License 2.0',
          ),
          actions: [
            SdtvFocusTile(
              label: 'Close',
              autofocus: true,
              onActivate: () {
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = session.categories;
    final channels = session.channelsInCategory;
    final selectedId = session.selectedCategoryId;
    final user = session.userInfo?.username ?? 'user';

    return SdtvInputScope(
      onBack: () => _confirmSignOut(context, session),
      onMenu: () => _showAbout(context, user, session.useDemo),
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
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 280,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(24, 8, 12, 24),
                          children: [
                            Text(
                              'CATEGORIES',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (var i = 0; i < cats.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: SdtvFocusTile(
                                  label: cats[i].categoryName,
                                  autofocus: i == 0,
                                  icon: Icons.folder_outlined,
                                  onActivate: () =>
                                      session.selectCategory(cats[i].categoryId),
                                ),
                              ),
                          ],
                        ),
                      ),
                      VerticalDivider(
                        width: 1,
                        color:
                            theme.colorScheme.outline.withValues(alpha: 0.3),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                          children: [
                            Text(
                              'CHANNELS · ${_categoryTitle(cats, selectedId)}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (channels.isEmpty)
                              Text(
                                'No channels in this category.',
                                style: theme.textTheme.bodyLarge,
                              ),
                            for (final ch in channels)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: SdtvFocusTile(
                                  label: '${ch.num > 0 ? '${ch.num}. ' : ''}${ch.name}',
                                  icon: Icons.live_tv_outlined,
                                  onActivate: () async {
                                    await session.playChannel(ch);
                                    if (!context.mounted) return;
                                    await Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            PlayerPage(session: session),
                                      ),
                                    );
                                    await session.stopPlayback();
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
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
                        'A play · B sign out · Start about',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
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
