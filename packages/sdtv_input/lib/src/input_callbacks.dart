import 'package:flutter/widgets.dart';

/// Direct callbacks for couch chrome (bypasses Intent / Actions lookup quirks).
///
/// Prefer these for pad events on fullscreen surfaces (video player). Once
/// media_kit is *playing*, [Actions.maybeInvoke] for D-pad/bumpers often fails
/// while [onBack] still works — same root cause as earlier B issues.
class SdtvInputCallbacks extends InheritedWidget {
  const SdtvInputCallbacks({
    super.key,
    required this.onConfirm,
    required this.onBack,
    required this.onMenu,
    this.onDirection,
    this.onPageUp,
    this.onPageDown,
    required super.child,
  });

  final VoidCallback? onConfirm;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;

  /// D-pad / stick. When set, gamepad binding calls this instead of Actions.
  final void Function(TraversalDirection direction)? onDirection;

  /// LB / PageUp.
  final VoidCallback? onPageUp;

  /// RB / PageDown.
  final VoidCallback? onPageDown;

  static SdtvInputCallbacks? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SdtvInputCallbacks>();
  }

  static SdtvInputCallbacks? of(BuildContext context) {
    return maybeOf(context);
  }

  @override
  bool updateShouldNotify(SdtvInputCallbacks oldWidget) {
    return onConfirm != oldWidget.onConfirm ||
        onBack != oldWidget.onBack ||
        onMenu != oldWidget.onMenu ||
        onDirection != oldWidget.onDirection ||
        onPageUp != oldWidget.onPageUp ||
        onPageDown != oldWidget.onPageDown;
  }
}

/// Registry of login/form [FocusNode]s that should use Tab-style traversal.
class SdtvTextFocusRegistry {
  static final Set<FocusNode> nodes = <FocusNode>{};

  static void register(FocusNode node) => nodes.add(node);
  static void unregister(FocusNode node) => nodes.remove(node);

  static bool get primaryIsTextField {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    if (nodes.contains(primary)) return true;
    for (final n in nodes) {
      if (primary == n ||
          primary.ancestors.contains(n) ||
          n.descendants.contains(primary)) {
        return true;
      }
    }
    return false;
  }
}

extension on FocusNode {
  Iterable<FocusNode> get ancestors sync* {
    var p = parent;
    while (p != null) {
      yield p;
      p = p.parent;
    }
  }

  Iterable<FocusNode> get descendants sync* {
    for (final c in children) {
      yield c;
      yield* c.descendants;
    }
  }
}
