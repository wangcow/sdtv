# Controller map — sdtv

**Product of the Wangcow Corporation**

Couch navigation is the core product requirement. Every screen must work with a **gamepad** and a **keyboard** (desktop / future Flatpak users).

## Live / Movies

Top chips: **LIVE** · **MOVIES**. From the first category, **↑** focuses the chips · **←/→** switch · **↓** or **A** back to the list. Movies use Xtream `get_vod_*` (M3U has no movie catalog). Demo uses a mock list + public HLS.

While a movie is playing: **A** menu (Resume, ±10s, subs, audio, mute, back) · **←/→** or **LB/RB** seek 10s · **B** back to Movies. Position is saved every 10s (continue watching). No live-edge reload.

## Guide (browse)

| Action | Deck / Xbox | Keyboard |
|--------|-------------|----------|
| Move focus | D-pad, left stick | Arrow keys |
| Confirm / open | A | Enter / Space |
| Back | B | Escape |
| Menu | Start (☰) | Context menu / F1 |
| Favorite channel | Y | F |
| Hide category | X (guide) | M (guide) |
| Search | ☰ Start → Search | `/` or Ctrl+F |
| Page jump | LB / RB | PageUp / PageDown |

### Favorites

- **Y** (or **F**, long-press on touch) stars the focused channel. Y again on a starred channel asks **Keep / Remove** (A confirms, B keeps).
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

- **☰ Start → Search** (Search is the first menu row) or keyboard **`/`** / **Ctrl+F** opens guide search. The guide footer shows **☰ Search**, not `/`.
- Filters **visible** categories + channels (hidden cats excluded). Type with keyboard or Deck OSK (Steam+X).
- Deck OSK (Steam+X): **A** types a letter and does **not** leave the box. When finished, **B** (or **RB**) moves to the result list, then **A** jumps to that category/channel in the guide (does not play yet). **B** again closes search.
- Result model includes `GuideSearchKind.epg` for future program search — same UI.

## Player chrome (external mpv — daily)

Video is **mpv**, not a Flutter texture. Banner + pause menu are drawn on mpv’s OSD (ASS overlay). That is the TiviMate-like path that can stay at 60fps.

Stock mpv OSC (seek bar) is **disabled** — on live it rewinds the cache.

☰ → **Embedded player (slow)** is an experiment only. Do not use it for daily live TV.

## Watching (external mpv — daily default)

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

mpv’s OSC seek bar is **disabled** for live (it rewound the live cache → old segment / wrong audio).  
sdtv uses a **text menu** instead:

| Mode | How you enter | D-pad / shoulders | A | B |
|------|----------------|-------------------|---|---|
| **Playing** | Start channel / Resume | Volume ↑↓ · Channel ←→ / LB RB | Open menu (pauses) | Quit to guide |
| **Watch menu** | A while playing | Move selection · ←→ change subs/audio | Activate row | Close menu (stay paused) |

Menu rows (OSD list with ▶ cursor):

1. **Resume** — reload at **live edge** (not mid old buffer), then play  
2. **Subtitles** — A / ←→ cycle tracks (Off when none)  
3. **Audio** — A / ←→ cycle tracks  
4. **Mute** — toggle  
5. **Back to guide** — quit mpv  

While the menu is open, channel zap and volume on the D-pad are **disabled**.  
Brief black/rebuffer on **Resume** is normal for live IPTV.

### Stall / dead stream

If the picture is frozen or buffering for **15 seconds**, sdtv opens an error sheet. The first line is a **code + reason**:

| Code | Meaning |
|------|---------|
| `E401`–`E504` | HTTP from the panel (mpv log) |
| `E-TMO` / `E-NET` / `E-TLS` | Timeout, network, TLS |
| `E-OPEN` / `E-DEC` | Couldn’t open / decode |
| `A-BUF` | Buffering 15s, no HTTP line |
| `A-EOF` | Stream ended (keep-open hold) |
| `A-IDLE` / `A-HOLD` | mpv idle / playback stopped |
| `A-STALL` | Clock ran, then froze |
| `A-MPV` / `A-IPC` | mpv didn’t start / IPC died |
| `A-UNK` | Unclassified |

`E*` = provider/network. `A-*` = sdtv/mpv probe, not an HTTP status.

1. **Retry** — reload at live edge (then HLS if needed)  
2. **Back to guide** — quit mpv  

**A** selects · **B** goes to the guide. After a successful retry the 15s clock starts over.

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

**Steam Deck limitation:** Gamescope picks nest resolution at **game launch**. Docking mid-session usually keeps the handheld nest (e.g. 1280×800) scaled onto the TV — picture looks *almost* full with bars. **Native** in sdtv’s Steam properties only applies the next time you **start** sdtv while docked.

| Fix | Result |
|-----|--------|
| STEAM → Exit sdtv → open again (while docked) | Full TV nest — this is the real fix |
| Respawn mpv / B → play again | Same nest — still almost full |
| sdtv OSD / snack after dock | Reminds you to relaunch |

Set Properties → external resolution to **Native**. Many IPTV streams are still 720p content even when the window is full 1080p.

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
