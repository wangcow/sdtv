# Steam Deck setup — sdtv

**Product of the Wangcow Corporation**

> sdtv is a media player only. You supply your own Xtream Codes credentials. No channels are included.

## Install from GitHub releases

1. **STEAM** → Power → **Switch to Desktop**.
2. Install **mpv** (sdtv plays video through it): open **Discover**, search
   **mpv**, install it.
3. Download `sdtv-deck.tar.gz` from the latest
   [GitHub release](https://github.com/wangcow/sdtv/releases).
4. In **Konsole**:

   ```bash
   mkdir -p ~/sdtv
   tar -xzf ~/Downloads/sdtv-deck.tar.gz -C ~/sdtv
   ```

   To update later, run the same two lines again; settings and favourites
   are kept (they live outside `~/sdtv`).

### Add to Game Mode

1. In Desktop Mode, open **Steam**.
2. **Add a Game** → **Add a Non-Steam Game** → **Browse…** → pick
   `~/sdtv/run-sdtv.sh` (always launch this, not `./sdtv`).
3. Optional: in the shortcut's **Properties**, set the icon to
   `~/sdtv/sdtv.png` and rename it **sdtv**.
4. Return to Game Mode and launch **sdtv** from your library.

## Controller settings

1. Highlight sdtv → controller options (or STEAM button → Controller settings while running).
2. Set template to **Gamepad** (not Desktop / mouse & keyboard).
3. Confirm D-pad moves UI focus and A activates items.

See [CONTROLLER.md](CONTROLLER.md) for the full button map.

## Dock / TV resolution

When launching from **Game Mode**, **Gamescope** owns the nest size for the whole sdtv process.

1. **STEAM** → sdtv → **Properties** → **General**  
   - Resolution (external display): **Native** (recommended) or **Default** — not a fixed 1280×800.
2. **Settings → Display** (while docked): external resolution / scaling as you prefer for the TV.

### Why “almost full screen” until you restart sdtv

**Native / external resolution is applied when the game starts**, not when you dock mid-session.

| What you do | What you get |
|-------------|--------------|
| Launch sdtv **already docked** | Nest = TV (e.g. 1920×1080) → video can fill the screen |
| Launch **handheld**, then dock | Nest often stays **1280×800 (16:10)** letterboxed on the TV → looks *almost* full |
| **Exit sdtv** (Steam) and open again while docked | New nest at Native → full screen |

mpv cannot paint outside the Gamescope nest. Restarting only the player (or “respawning” mpv) does **not** fix this — only a **full sdtv relaunch** does.

sdtv detects that case and shows an on-screen / snack hint to exit and reopen.

Channels that are actually 720p will still look soft when the window correctly fills 1080p.

## Development build (now)

For development, run from source on Desktop Mode:

```bash
cd ~/sdtv-src
source tool/bazzite-flutter-env.sh   # Bazzite/Homebrew; skip on normal Fedora if dnf toolchain is installed
# Needs: brew install mpv   (the external player)
cd apps/sdtv
flutter pub get
flutter run -d linux
```

### Watching channels (Phase A: external mpv)

Selecting a channel **starts fullscreen `mpv`**, then returns to the TV Guide when mpv quits.

- Install **mpv** on the Deck (Desktop Mode → **Discover** → search **mpv** → install Flathub app `io.mpv.Mpv`).  
  Discover installs a **Flatpak**, not `/usr/bin/mpv` — that is normal; sdtv looks for Flatpak too.
- While watching, the Flutter HUD is painted on the mpv picture (bitmap overlay). It hides after a few seconds.
  - **← / →** or **A** — show the HUD · **← / →** while it is up moves the buttons
  - **A** on Play — pause (live unpause reloads the live edge) · **B** — Back, then quit to the guide
  - **LB / RB** — previous / next channel (same list / favorites), or ±10s on a movie or episode
  - **↑ / ↓** while the HUD is hidden — volume · **X** / **M** — mute
  - **☰** — subs / audio / mute text menu
  - Keyboard (PC, mpv has focus): same as the pad — arrows, Enter = A, Esc = B, Space pause, PgUp/PgDn channel, Tab menu, Q quit. See [CONTROLLER.md](CONTROLLER.md#keyboard-while-playing-pc)
- If mpv fails to start, the error snack names the problem.
- Override: create `~/sdtv/sdtv.env` with one of:
  ```bash
  SDTV_MPV_PATH=flatpak:io.mpv.Mpv
  # or system package:
  # SDTV_MPV_PATH=/usr/bin/mpv
  ```
- Debug: after launch, check `~/sdtv/.sdtv-runtime.txt` for `SDTV_MPV_PATH=…`.

### Watch chrome (daily path)

**A** on a channel starts **external mpv** (hardware decode, 60fps). The picture stays on mpv. The couch HUD is the Flutter chrome, rendered to an image and composited with mpv `overlay-add` (a bitmap, not ASS text). Gamescope still sees one fullscreen window. Focus stays in sdtv.

Stock mpv OSC (the seek bar) stays **off**. On live IPTV it rewinds the cache. **☰** opens the subs / audio / mute text menu. If the bitmap overlay fails, sdtv falls back to styled `show-text`. Live sessions use `--keep-open=yes` so a stream hiccup does not quit mpv.

A later use of the same bitmap is a clear corner so the guide can scroll over a live picture. That is not built yet. Do not put the video through a Flutter texture, and do not stack a second window under Gamescope.

### Smooth video (VAAPI)

Stutter + `decode: cpu/software` means **software decode**.

Video decodes in the Deck’s own mpv (system or Flatpak). sdtv bundles no mpv, codecs, `libva`, or Mesa. VAAPI needs the Deck’s driver:

`/usr/lib64/dri/radeonsi_drv_video.so`

`run-sdtv.sh` sets:

- `LIBVA_DRIVERS_PATH=/usr/lib64/dri`
- `LIBVA_DRIVER_NAME=radeonsi` (Steam Deck APU)

sdtv passes both to a system mpv. A Flatpak mpv (`io.mpv.Mpv`) gets neither: it finds the driver through its own runtime, and the host path breaks VA-API inside the sandbox.

| HUD | Meaning |
|-----|---------|
| `decode: vaapi · …` | Good — hardware path |
| `decode: cpu/software · mpv=bundled` | VAAPI driver still not engaged — check `~/sdtv/.sdtv-runtime.txt` |

After a failed/slow run, open `~/sdtv/.sdtv-runtime.txt` (written at launch) for paths/env.

### Live Xtream on Deck

**Connect to provider** uses your real panel (not demo). Enter:

- Server: `http://host:port` (panel root — no `/player_api.php`)
- Username / password from your provider

Badge **LIVE** = real catalog + real stream URLs. Channel zap opens a new URL each time.

Optional `~/sdtv/sdtv.env` (created by you, survives deploys if you re-add it):

```bash
# Offline / safe Connect without hitting provider:
SDTV_FORCE_MOCK=1
```

Deploy wipes `~/sdtv` contents — keep a copy of `sdtv.env` if you use it.

### Fast Game Mode test loop (recommended)

Stay in **Game Mode** on the Deck. Build and push from Bazzite over SSH — no Desktop typing each iteration.

#### One-time Deck setup (Desktop Mode once)

1. **Enable SSH** (Desktop → Konsole):
   ```bash
   passwd   # if you never set a password for user deck
   sudo systemctl enable --now sshd
   ```

2. **SSH key from Bazzite** (skip password prompts):
   ```bash
   ssh-copy-id deck@DECK_IP
   ssh deck@DECK_IP 'echo ok'
   ```

3. **First deploy + Non-Steam shortcut** (once):
   ```bash
   # on Bazzite
   export SDTV_DECK_HOST=deck@DECK_IP
   ./tool/deploy-deck.sh
   ```
   On Deck Desktop: Steam → **Add a Non-Steam Game** →  
   `/home/deck/sdtv/run-sdtv.sh` → name it **sdtv**.  
   Controller: **Gamepad** template (not Desktop).

Return to Game Mode. Later deploys overwrite `~/sdtv` in place; the shortcut stays valid.

#### Everyday (Deck stays in Game Mode)

```bash
cd ~/sdtv-src
export SDTV_DECK_HOST=deck@DECK_IP   # once per shell / add to ~/.bashrc

./tool/deploy-deck.sh              # rebuild + upload + remote extract
# ./tool/deploy-deck.sh --no-package   # re-push last tarball only
```

On the Deck: **Exit game** if sdtv is open → launch **sdtv** from the library again.

| Flag | Meaning |
|------|---------|
| *(default)* | `package-deck.sh` + scp + extract to `~/sdtv` |
| `--no-package` | Upload existing `dist/sdtv-deck.tar.gz` only |
| `--package-only` | Build tarball, no network |
| `--host deck@IP` | Target (else `$SDTV_DECK_HOST` or first arg) |

### Packaging details

```bash
bash tool/package-deck.sh   # or just ./tool/deploy-deck.sh
```

Produces the Flutter release bundle (no mpv or codec libraries, no brew GTK/X11/mesa), rewritten `DT_NEEDED`, and `run-sdtv.sh` (system-first `LD_LIBRARY_PATH`, VAAPI driver paths, system XKB/fontconfig paths, and mpv discovery).

Always launch **`run-sdtv.sh`**, not `./sdtv`. Prefer `./tool/deploy-deck.sh` over raw `scp -r` (avoids read-only lib Permission denied).

### Bazzite vs regular Fedora

| | Bazzite (immutable) | Fedora Workstation |
|--|---------------------|--------------------|
| Install clang/cmake/gtk | Homebrew + `tool/bazzite-flutter-env.sh` | `sudo dnf install clang cmake ninja-build gtk3-devel` |
| Day-to-day friction | Higher (env vars, brew) | Lower |
| Controller testing | Same code path (`/dev/input/js*`) | Same |
| Steam Deck parity | Excellent (same family) | Fine for UI; still validate on Deck |

Bazzite is **not** a blocker for controller support. If brew/env headaches annoy you, a normal Fedora laptop is a great daily driver; keep Bazzite/Deck for packaging and Game Mode acceptance tests.

### “Builds but no window” on Bazzite + NVIDIA

If you see:

```text
libEGL warning: pci id for fd … driver (null)
libEGL warning: egl: failed to create dri2 screen
```

and Flutter says “Syncing files…” with no GUI: **unset `LD_LIBRARY_PATH`**. Homebrew Mesa must not override system NVIDIA EGL. `tool/bazzite-flutter-env.sh` already unsets it. Then:

```bash
source tool/bazzite-flutter-env.sh
./tool/run.sh
```

If still invisible, try `export GDK_BACKEND=x11` before run.

Linux build needs `clang`, `cmake`, `ninja`, GTK 3 development libraries. Playback needs an `mpv` binary (system, Flatpak, or `brew install mpv` on the dev machine).

## Network tips

- Docked Ethernet reduces live-stream buffering.
- Wi‑Fi is fine for testing UI; stress-test streams when ready.

## Privacy

- Credentials stay on-device (local app data under `~/.local/share`).
- No Wangcow cloud login is required for core playback.
