import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'input_callbacks.dart';
import 'pad_router.dart';

/// True when we should open `/dev/input/js*`.
///
/// On by default for Linux. Disable with `SDTV_ENABLE_GAMEPAD=0`.
bool sdtvGamepadBindingEnabledByDefault() {
  if (kIsWeb) return false;
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  final flag = Platform.environment['SDTV_ENABLE_GAMEPAD']?.toLowerCase();
  if (flag == '0' || flag == 'false' || flag == 'no') return false;
  try {
    return Platform.isLinux;
  } catch (_) {
    return false;
  }
}

/// Keyboard / OSK shortcuts. Prefer [NextFocusIntent] for Tab (forms).
Map<ShortcutActivator, Intent> sdtvNavigationShortcuts() {
  return <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.arrowUp):
        const DirectionalFocusIntent(TraversalDirection.up),
    const SingleActivator(LogicalKeyboardKey.arrowDown):
        const DirectionalFocusIntent(TraversalDirection.down),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const DirectionalFocusIntent(TraversalDirection.left),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const DirectionalFocusIntent(TraversalDirection.right),

    const SingleActivator(LogicalKeyboardKey.tab): const NextFocusIntent(),
    const SingleActivator(LogicalKeyboardKey.tab, shift: true):
        const PreviousFocusIntent(),

    const SingleActivator(LogicalKeyboardKey.enter): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.select): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.space): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonA):
        const SdtvConfirmIntent(),

    const SingleActivator(LogicalKeyboardKey.escape): const SdtvBackIntent(),
    const SingleActivator(LogicalKeyboardKey.goBack): const SdtvBackIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonB):
        const SdtvBackIntent(),
    const SingleActivator(LogicalKeyboardKey.browserBack):
        const SdtvBackIntent(),

    const SingleActivator(LogicalKeyboardKey.contextMenu):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonStart):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonMode):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonY):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.f1): const SdtvMenuIntent(),

    const SingleActivator(LogicalKeyboardKey.gameButtonLeft1):
        const SdtvPageUpIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonRight1):
        const SdtvPageDownIntent(),
    const SingleActivator(LogicalKeyboardKey.pageUp): const SdtvPageUpIntent(),
    const SingleActivator(LogicalKeyboardKey.pageDown):
        const SdtvPageDownIntent(),
  };
}

Map<Type, Action<Intent>> sdtvDefaultActions({
  VoidCallback? onConfirm,
  VoidCallback? onBack,
  VoidCallback? onMenu,
}) {
  return <Type, Action<Intent>>{
    DirectionalFocusIntent: DirectionalFocusAction(),
    NextFocusIntent: CallbackAction<NextFocusIntent>(
      onInvoke: (_) {
        FocusManager.instance.primaryFocus?.nextFocus();
        return null;
      },
    ),
    PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
      onInvoke: (_) {
        FocusManager.instance.primaryFocus?.previousFocus();
        return null;
      },
    ),
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) {
        onConfirm?.call();
        return null;
      },
    ),
    SdtvConfirmIntent: CallbackAction<SdtvConfirmIntent>(
      onInvoke: (_) {
        onConfirm?.call();
        return null;
      },
    ),
    SdtvBackIntent: CallbackAction<SdtvBackIntent>(
      onInvoke: (_) {
        onBack?.call();
        return null;
      },
    ),
    SdtvMenuIntent: CallbackAction<SdtvMenuIntent>(
      onInvoke: (_) {
        onMenu?.call();
        return null;
      },
    ),
    SdtvPageUpIntent: CallbackAction<SdtvPageUpIntent>(
      onInvoke: (_) => null,
    ),
    SdtvPageDownIntent: CallbackAction<SdtvPageDownIntent>(
      onInvoke: (_) => null,
    ),
  };
}

/// Registers pad handlers on [SdtvPadRouter] and provides keyboard Shortcuts.
///
/// Does **not** open `/dev/input/js*` — mount a single [SdtvGamepadBinding] at
/// the app root (see [SdtvApp]). Nested scopes only push/pop layers so the
/// player can sit on top of browse without fighting for the device.
class SdtvInputScope extends StatefulWidget {
  const SdtvInputScope({
    super.key,
    required this.child,
    this.onConfirm,
    this.onBack,
    this.onMenu,
    this.onDirection,
    this.onPageUp,
    this.onPageDown,
    this.extraShortcuts = const {},
    this.extraActions = const {},
    @Deprecated('Ignored — use app-root SdtvGamepadBinding') this.enableGamepad,
  });

  final Widget child;
  final VoidCallback? onConfirm;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final void Function(TraversalDirection direction)? onDirection;
  final VoidCallback? onPageUp;
  final VoidCallback? onPageDown;
  final Map<ShortcutActivator, Intent> extraShortcuts;
  final Map<Type, Action<Intent>> extraActions;
  final bool? enableGamepad;

  @override
  State<SdtvInputScope> createState() => _SdtvInputScopeState();
}

class _SdtvInputScopeState extends State<SdtvInputScope> {
  final SdtvPadLayer _layer = SdtvPadLayer();

  @override
  void initState() {
    super.initState();
    _syncLayer();
    SdtvPadRouter.instance.push(_layer);
  }

  @override
  void didUpdateWidget(SdtvInputScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only refresh callbacks — never re-push. Re-push would steal the top
    // of the stack from a pushed route (player) whenever browse rebuilds.
    _syncLayer();
  }

  @override
  void dispose() {
    SdtvPadRouter.instance.pop(_layer);
    super.dispose();
  }

  void _syncLayer() {
    _layer
      ..onConfirm = widget.onConfirm
      ..onBack = widget.onBack
      ..onMenu = widget.onMenu
      ..onDirection = widget.onDirection
      ..onPageUp = widget.onPageUp
      ..onPageDown = widget.onPageDown;
  }

  @override
  Widget build(BuildContext context) {
    return SdtvInputCallbacks(
      onConfirm: widget.onConfirm,
      onBack: widget.onBack,
      onMenu: widget.onMenu,
      onDirection: widget.onDirection,
      onPageUp: widget.onPageUp,
      onPageDown: widget.onPageDown,
      child: Shortcuts(
        shortcuts: {
          ...sdtvNavigationShortcuts(),
          ...widget.extraShortcuts,
        },
        child: Actions(
          actions: {
            ...sdtvDefaultActions(
              onConfirm: widget.onConfirm,
              onBack: widget.onBack,
              onMenu: widget.onMenu,
            ),
            ...widget.extraActions,
          },
          child: widget.child,
        ),
      ),
    );
  }
}
