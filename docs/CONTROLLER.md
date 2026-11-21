# Controller map — sdtv

**Product of the Wangcow Corporation**

Couch navigation is the core product requirement. Every screen must work with a **gamepad** and a **keyboard** (desktop users).

## Live / Movies / TV Shows

Top chips: **LIVE** · **MOVIES** · **TV SHOWS**. From the first category, **↑** focuses the chips · **←/→** switch · **↓** or **A** back to the list. Movies use Xtream `get_vod_*`; TV Shows use `get_series_*` (M3U has neither catalog). Demo uses a mock list + public HLS.

**LIVE** right pane is the **TV Guide** (channel names + program timeline). It replaces the old channel list / now·next miniguide. The guide shows now and later only. **↑↓** channels · **LB/RB** switch section (Live ⇄ Movies ⇄ TV Shows) · **←** returns to categories · **→** does nothing · **A** plays the live channel. **B** jumps to now when the timeline is ahead of now; **B** again (already at now) returns to categories. **G** also jumps the window to now.

Movies and TV Shows right panes are a **poster grid**. **←** on the first column of a row returns to categories · **↑↓** move by row · **→** stays in the row · **A** opens the **title landing page** (does not play) · **B** back to categories. A green check and a dimmed poster mean the movie (or every episode of the show) has been watched to the end. The poster under the cursor stays brighter. In-progress titles keep a resume bar and are not dimmed.

**Title landing:** poster, title, description, director, cast, provider rating. **↑↓** actions · **A** select · **B** / **←** back to the same poster. **LB/RB** do nothing here (they switch sections from the guide, and change season on the episode list).

- **Movies:** in-progress titles get **Resume Playing** · **Start from Beginning**; otherwise **Play Now**. Then **Add to Favorites** / **Remove from Favorites**. **Watch trailer** is hidden when the panel has none.
- **TV Shows:** in-progress shows get **Resume Playing** (last episode) · **Start from Beginning** (S1E1); otherwise **Play Now**. Then **Add to Favorites** / **Remove from Favorites**. **Seasons & episodes** is always present. **Watch trailer** is hidden when none.

YouTube trailers open in the system/YouTube client (TiviMate-style), not mpv.

**Seasons & episodes (TV Shows):** **↑↓** pick an episode · **LB/RB** change season · **A** plays that episode · **B** / **←** back to the title. **☰** still opens Search (do not use RB for Search here). Resume progress is per episode. A finished episode shows a green check, a dimmed row, and the word **Watched** at the start of the subtitle. The highlighted row stays bright.

While a movie or episode is playing, the Flutter HUD is on the video. **←/→** moves the buttons · **↑** the scrubber · **LB/RB** seek 10s · **A** confirms the focused button (Play pauses) · **B** hides the HUD, then **B** again returns to the title (position is saved). **☰** opens subs, audio, and mute. Position is also saved every 10s. No live-edge reload. When an episode ends, the **next episode starts automatically**; **Next ep** on the HUD skips there early (your place in this episode is saved). The last episode holds on the final frame — **B** back to the title.

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
| Jump guide to now | — | `G` |
| Page jump / EPG time | LB / RB | PageUp / PageDown |

On the **category column** (Live, Movies, and TV Shows): **B** jumps to the top of the list. **B** again (already at the top) opens the in-page menu (Search, Switch playlist, …). **☰ Start** still opens that menu immediately. From the Live guide, **B** snaps to now if you have moved forward in time, then **B** returns to categories. From the poster column, **B** returns to categories.

### Keyboard while playing (PC)

The mpv window has keyboard focus while a stream plays. Its keys are sent back to sdtv over IPC (`script-message sdtv-key …`), so they drive the same HUD, menus and channel list as the pad. mpv acts on none of them itself.

| Key | Same as | Does |
|-----|---------|------|
| ← → ↑ ↓ | D-pad | Move HUD focus / menu rows / scrubber (↑↓ zap live when the HUD is hidden) |
| Enter | A | Press the focused HUD button or menu row |
| Esc / Backspace | B | Back (HUD → Back button → guide; closes menus) |
| Space / P | — | Play / pause |
| PgUp / PgDn, `<` `>`, `n` | LB / RB | Previous / next channel, or ±10 s on a movie |
| Tab | ☰ | Subs / audio / mute menu |
| M | X | Mute |
| F | Y | Favourite the live channel |
| Q | — | Quit to the guide (movie position is saved) |

On the Deck, Steam can inject a key (Esc for B) alongside a pad press. sdtv ignores a forwarded key that arrives within 300 ms of pad input, so nothing fires twice.

### Favorites

- **Live:** **Y** (or **F**) stars the focused channel. Y again asks **Keep / Remove**. While a *live* channel is playing, Y still stars that channel.
- **Movies / TV Shows:** star only from the **title landing** — **Add to Favorites** / **Remove from Favorites** (or **Y** on that page). Y while a movie or episode is playing does nothing.
- **★ Favorites** is pinned at the top of Live, Movies, and TV Shows category lists. A gold star on the poster marks a favorite; a green check and a dimmed poster mean watched.
- Stars, resume positions, and watched movies, episodes, and shows are one local `UserLibrary` document per playlist/panel. Each spot and watched flag has a timestamp so a future paid Wangcow Continuity host can merge them across signed-in devices (phone, TV, Deck). That sync is not built yet. See [LIBRARY.md](LIBRARY.md).

### Hidden categories

- **X** (guide) or **☰ → Hide category** removes the focused category from the list (not ★ Favorites).
- **☰ → Settings → Manage categories** (full screen) lists every Live category in your order. **X** hides / shows the focused one · **A** picks it up, **↑↓** move it, **A** or **B** drops it · **B** back to Settings. The order and hidden list are saved per playlist.
- Hidden ids are stored locally, scoped per Xtream account / M3U URL (same as favorites).

### Last played

- Starting playback (or zapping) still saves last-played for About / continue-watching.
- **Launch does not reopen that live category.** Search-jumping into e.g. 24/7 T-Z and quitting must not pin the guide there forever.
- Cold start restores the last **LIVE / MOVIES / TV SHOWS tab**. Live opens on **★ Favorites** (or the first visible category) on the category column. Movies and TV Shows restore the last category you were browsing in that tab.

### Saved playlists

- Successful **Demo / M3U / Xtream** connect is stored on-device (no retyping).
- Login home lists **SAVED PLAYLISTS** — **A** opens one.
- Guide **☰ → Switch playlist** swaps sources without signing out.
- Favorites / hidden cats / last-played stay **per source** (scoped). The watch library (favorites, progress, watched movies / episodes / shows) is the same timestamped `UserLibrary` JSON a future Continuity service would host.

### Search

- **☰ Start → Search** (Search is the first menu row) or keyboard **`/`** / **Ctrl+F** opens search. The footer shows **☰ Search**, not `/`.
- Matches **Live** channels (not channel categories), **Movies**, and **TV Shows** (titles + their categories). Hidden cats still appear, marked. Type with keyboard or Deck OSK (Steam+X).
- Physical keyboard: type, then **↓** moves to the result list (**↑** on the first result returns to the box) · **Enter** jumps there.
- Deck OSK (Steam+X): **A** types a letter and does **not** leave the box. When finished, **B** moves to the result list, then **A** on a movie or show opens its title page (**B** from there lands on its poster in the grid); **A** on a channel jumps to it in the Live guide; **A** on a category opens that category. A does not start playback. **↑** on the first result returns to the search box to edit the query. **B** from the list closes search. **LB/RB** are not Search — they change season (TV episodes) or switch section (guide).
- Result model includes `GuideSearchKind.epg` for future program search — same UI.

## Player chrome (external mpv — daily)

Video is **mpv** (`vo=gpu`), not a Flutter texture. The couch HUD is Flutter chrome painted onto the video as two bitmaps, a top and a bottom band (`overlay-add`). The picture stays on mpv. D-pad focus stays in the app. The bitmaps update when you press a button, when mpv reports a pause or length change, and once a second while a VOD clock is on screen. It hides after a few seconds so the middle of the picture stays clear.

Stock mpv OSC (seek bar) is **disabled** — on live it rewinds the cache. Styled `show-text` is only the fallback if the bitmap overlay fails, plus short readouts (volume) while the HUD is hidden. The pause list (subs / audio / mute) is still that text menu.

**A** on a channel, program, movie, episode, or file trailer plays it on mpv straight away. YouTube trailers still open outside the app.

## Watching (external mpv — daily default)

Flutter keeps reading the pad (Deck). Keyboard maps apply when mpv has focus (desktop): Space / P pause, Esc / Q quit, PageUp / PageDown channel, arrows volume.

The Flutter HUD starts visible, then hides. **← / →** or **A** brings it back.

| Action | When | Deck / Xbox |
|--------|------|-------------|
| Show HUD | Hidden | ← / → or A |
| Move chrome | HUD visible | ← / → along the buttons. Live: Prev ch · Play · Next ch · **Last ch** (flips to the channel you came from, after the first zap) · CC · Audio · Favourite · Guide. Movies / episodes: −10s · Play · +10s · **Next ep** (shows) · CC · Audio · Back |
| Scrubber | VOD HUD | ↑ focuses the bar · ← / → seeks · ↓ leaves it |
| Channel − / + | Live | LB / RB, or ↑ / ↓ while the HUD is visible |
| Seek ±10s | Movie / episode | LB / RB |
| Volume − / + | HUD hidden | ↑ / ↓ |
| Play / pause | HUD visible, Play focused | A (live unpause reloads the live edge) |
| Focus Back | HUD visible | B |
| Quit to guide | HUD hidden, or Back focused | B |
| Subs / audio / mute | Any time | ☰ opens the text menu (pauses). B or ☰ closes it and keeps playing |
| Mute | Any time | X |

Zap walks the **current list** (★ Favorites or the category you played from).

### TV Guide (Live right pane)

The Live tab **is** the EPG grid — not a separate overlay and not a channel list with now/next subtitles.

- Left: categories (including ★ Favorites). **→** / **A** enters the grid.
- Right: channel column + program timeline. Bottom strip is the focused program (title, time, description).
- **↑↓** channels · **LB/RB** switch section · **←** returns to categories · **G** jump to now · **A** plays **live** · **B** now (if the timeline is ahead) then categories
- A vertical line marks **now**. Demo/mock synthesizes a day’s listings. Real Xtream uses `get_simple_data_table` (falls back to `get_short_epg`). **M3U** has no panel EPG — channel names only.
- Selecting a past or future program still plays **live** (no catch-up in this phase)

While **watching**, a zap updates the Flutter HUD title on the video. That is not the browse guide, and it does not yet list now/next.

Program search in the Search overlay is later.

### Watch menu (navigable pause UI)

mpv’s OSC seek bar is **disabled** for live (it rewound the live cache → old segment / wrong audio).  
sdtv uses a **text menu** instead:

| Mode | How you enter | D-pad / shoulders | A | B |
|------|----------------|-------------------|---|---|
| **Playing** | Start channel / Resume | HUD focus, or volume while the HUD is hidden · LB/RB channel or seek | HUD confirm (play/pause on Play) | Back, then quit |
| **Watch menu** | ☰ while playing | Move selection · ←→ change subs/audio | Activate row | Close menu and keep playing |

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
