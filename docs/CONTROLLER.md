# Controller map — sdtv

**Product of the Wangcow Corporation**

Couch navigation is the core product requirement. Every screen must work with a gamepad only.

## Default mapping (Steam Deck / Xbox layout)

| Action | Deck / Xbox | DualSense-style | Keyboard (dev) |
|--------|-------------|-----------------|----------------|
| Move focus | D-pad, left stick | D-pad, left stick | Arrow keys |
| Confirm | A (bottom) | Cross | Enter / Space |
| Back | B (right) | Circle | Escape |
| Menu | Start (☰) | Options | Context menu |
| Page up/down | LB / RB | L1 / R1 | PageUp / PageDown |
| Channel ± (player, later) | D-pad U/D or LB/RB | same | ↑ / ↓ |

## Steam Input

When launching from **Steam Game Mode** as a non-Steam game:

1. Open the game’s controller settings.
2. Choose a **Gamepad** template (not Desktop Configuration / mouse).
3. Avoid layouts that turn the right trackpad into a mouse for primary use.

sdtv reads standard gamepad / key events. If Steam remaps everything to mouse, couch UX breaks.

## Implementation notes

- Semantic intents live in `packages/sdtv_input` (`SdtvConfirmIntent`, `SdtvBackIntent`, …).
- Visual focus chrome: `SdtvFocusTile` — large ring, high contrast.
- **Keyboard** path: Flutter `Shortcuts` (arrows / Enter / Esc).
- **USB / Bluetooth gamepad path (Linux):** `LinuxJoystickReader` opens `/dev/input/js*` in a background isolate and maps xpad buttons/axes → intents. A raw Xbox pad does **not** send keyboard events; without this reader, the UI appears “broken” even though the OS sees the controller.
- Steam Game Mode may also inject Steam Input; we still prefer reading the joystick device so navigation works under plain `flutter run` on desktop.

## Acceptance (MVP)

- Login → browse categories → select channel → play → back → quit
- Hands never leave the controller
- No Steam Desktop mouse layout required
