/// Human-readable default controller mapping for docs and About.
///
/// Hardware gamepad buttons (Steam Deck / Xbox layout) map to semantic
/// actions. Flutter's [Shortcuts] layer uses keyboard LogicalKeyboardKey
/// equivalents; full SDL gamepad bridging lands in a later pass.
class SdtvButtonMap {
  const SdtvButtonMap._();

  static const move = 'D-pad / Left stick';
  static const confirm = 'A (bottom face) / Enter';
  static const back = 'B (right face) / Escape';
  static const menu = 'Start / Menu key';
  static const page = 'LB / RB (shoulders)';
  static const channelZap = 'D-pad up/down in player (planned)';

  static const summary = '''
Move:     D-pad or left stick
Confirm:  A / Enter
Back:     B / Escape
Menu:     Start
Page:     LB / RB
''';
}
