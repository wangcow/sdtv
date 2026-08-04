# Controller map — sdtv

**Product of the Wangcow Corporation**

Couch navigation is the core product requirement. Every screen must work with a **gamepad** and a **keyboard** (desktop / future Flatpak users).

## Guide (browse)

| Action | Deck / Xbox | Keyboard |
|--------|-------------|----------|
| Move focus | D-pad, left stick | Arrow keys |
| Confirm / open | A | Enter / Space |
| Back | B | Escape |
| Menu | Start (☰) | Context menu / F1 |
| Favorite channel | Y | F |
| Page jump | LB / RB | PageUp / PageDown |

### Favorites

- **Y** (or **F**, long-press on touch) toggles a star on the focused channel.
- **★ Favorites** is pinned at the top of the category list.
- Stars are stored locally, scoped per playlist/panel.

## Watching (external mpv — Phase B)

Flutter keeps reading the pad (Deck); mpv also has keyboard maps when it has focus (desktop).

| Action | Deck / Xbox | Keyboard |
|--------|-------------|----------|
| Pause | A | Space / P |
| Quit to guide | B | Esc / Q |
| Channel − / + | LB / RB or D-pad ←/→ | PageUp / PageDown, `<` / `>`, N next |
| Volume − / + | D-pad ↓ / ↑ | Arrow ↓ / ↑ |
| Mute | X | M |

Zap walks the **current list** (★ Favorites or the category you played from).

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
