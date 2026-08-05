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
| Hide category | X (guide) | M (guide) |
| Search | ☰ → Search | `/` or Ctrl+F |
| Page jump | LB / RB | PageUp / PageDown |

### Favorites

- **Y** (or **F**, long-press on touch) toggles a star on the focused channel.
- **★ Favorites** is pinned at the top of the category list.
- Stars are stored locally, scoped per playlist/panel.

### Hidden categories

- **X** (guide) or **☰ → Hide category** removes the focused category from the list (not ★ Favorites).
- **☰ → Manage categories** lists every provider category; **A** toggles hidden/shown.
- Hidden ids are stored locally, scoped per Xtream account / M3U URL (same as favorites).

### Last played

- Starting playback (or zapping to a channel) saves **guide category + channel** for that playlist/panel.
- That includes **★ Favorites** — if you were in Favorites, reopen lands there (not the provider category where the channel also lives).
- On next connect / app launch, the guide opens on that category with the channel focused (channel column selected when resume works).
- If the channel was unstarred since last play, resume falls back to its provider category.

### Saved playlists

- Successful **Demo / M3U / Xtream** connect is stored on-device (no retyping).
- Login home lists **SAVED PLAYLISTS** — **A** opens one.
- Guide **☰ → Switch playlist** swaps sources without signing out.
- Favorites / hidden cats / last-played stay **per source** (scoped).

### Search

- **☰ → Search** or **`/`** / **Ctrl+F** opens guide search.
- Filters **visible** categories + channels (hidden cats excluded). Type with keyboard or Deck OSK (Steam+X).
- **↑↓** move results · **A** on a channel **plays** it · **A** on a category opens that list · **B** closes.
- Result model includes `GuideSearchKind.epg` for future program search — same UI.

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

### Mini guide (short EPG — now / next)

TiviMate-style banner on the mpv OSD:

- **On channel open** and **after each successful zap**: channel name, **NOW** (time range + title + progress), **NEXT** (start + title).
- Data from Xtream `get_short_epg` (demo/mock synthesizes programs). **M3U** has no panel EPG — channel name only.
- In the **guide**, focused channels prefetch now/next; the current program appears as a **subtitle** under the channel name when cached.

Full EPG grid / program search is later.

### Watch menu (navigable pause UI)

mpv’s OSC is mostly **mouse**-oriented; D-pad does not “focus” its buttons well.  
sdtv uses a **mode switch** instead:

| Mode | How you enter | D-pad / shoulders | A | B |
|------|----------------|-------------------|---|---|
| **Playing** | Start channel / Resume | Volume ↑↓ · Channel ←→ / LB RB | Open menu (pauses) | Quit to guide |
| **Watch menu** | A while playing | Move selection · ←→ change subs/audio | Activate row | Close menu (stay paused) |

Menu rows (OSD list with ▶ cursor):

1. **Resume** — unpause, hide menu  
2. **Subtitles** — A / ←→ cycle tracks (Off when none)  
3. **Audio** — A / ←→ cycle tracks  
4. **Mute** — toggle  
5. **Back to guide** — quit mpv  

While the menu is open, channel zap and volume on the D-pad are **disabled** so you are clearly “in the menu.”  
Live streams may still show a weak OSC seek bar (no duration); that is expected.

## Steam Input

When launching from **Steam Game Mode** as a non-Steam game:

1. Open the game’s controller settings.
2. Choose a **Gamepad** template (not Desktop Configuration / mouse).
3. Avoid layouts that turn the right trackpad into a mouse for primary use.

sdtv reads standard gamepad / key events. If Steam remaps everything to mouse, couch UX breaks.

### Dock + Xbox (or other) pad

sdtv opens **all** `/dev/input/js*` devices and **re-scans every ~2s** (also on display metrics / resume). You can power on an Xbox controller after docking without restarting the app.

If the pad still only drives the **Steam** overlay and not sdtv:

- Confirm the game’s Steam Input template is **Gamepad** (not Desktop).
- Quit to the guide and back in once (Steam sometimes rebinds only on launch).
- Prefer leaving the pad on before opening sdtv when possible.

### Dock while watching (resolution)

mpv is started fullscreen. Docking handheld → 1080p TV can leave the VO at the old (800p) size under **Gamescope**.

sdtv tries to recover by:

1. On Flutter metrics change — pass **physical pixel size** into mpv and set **geometry** (not just `fullscreen=yes`)
2. Burst re-fit over ~3s (Gamescope settles slowly)
3. While watching, compare mpv `osd-*` vs `display-*` / last Flutter size every 3s

You may see brief black flashes during re-fit.

**Steam game resolution:** for Non-Steam sdtv, set Properties → General → resolution for external display to **Default** or **Native** (not locked 1280×800). Otherwise Gamescope never becomes 1080p and no app can fill the TV.

Note: many IPTV channels are **native 720p** — soft on a 1080p set when the window *is* full-screen; that is the stream.

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
