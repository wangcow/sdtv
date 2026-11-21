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

## Watching

**A** on a channel, movie or episode opens it full screen in **mpv**, which
decodes in hardware (VA-API). sdtv's controls are drawn on top of the
picture and hide after a few seconds; **B** hides them, and **B** again goes
back to the guide. The full button map is in [CONTROLLER.md](CONTROLLER.md).

mpv from **Discover** is the Flathub app `io.mpv.Mpv`. That is a Flatpak,
not `/usr/bin/mpv`, which is normal: sdtv finds either.

## Connecting to your provider

**Connect to provider** asks for:

- **Server:** `http://host:port`, the panel root (no `/player_api.php`)
- **Username** and **password** from your provider

M3U playlist URLs work too (Live TV only). Saved playlists can be switched
in **☰ → Settings**.

## Troubleshooting

**Settings file.** `~/sdtv/sdtv.env` (create it yourself) is read at launch:

```bash
# Use a specific mpv (the default finds a system or Flatpak mpv):
SDTV_MPV_PATH=flatpak:io.mpv.Mpv
# SDTV_MPV_PATH=/usr/bin/mpv
```

All variables are listed in the [README](../README.md#environment-variables).
Re-extracting a release keeps it; `deploy-deck.sh` (below) replaces `~/sdtv`
and does not.

**Logs**, in `~/sdtv`:

| File | What's in it |
|------|--------------|
| `.sdtv-runtime.txt` | Paths and settings of the last launch (mpv, VA-API) |
| `.sdtv-last-run.log` | The last launch's log (`.sdtv-prev-run.log` is the one before) |
| `.sdtv-play.log` | Stream start timings and retries across launches; URLs keep only the host |

**Stuttering video** usually means software decoding. sdtv bundles no mpv,
codecs or drivers and uses the Deck's VA-API driver
(`/usr/lib64/dri/radeonsi_drv_video.so`). `run-sdtv.sh` points a system mpv
at it (`LIBVA_DRIVERS_PATH`, `LIBVA_DRIVER_NAME=radeonsi`); a Flatpak mpv
finds it through its own runtime.

**A channel won't start.** sdtv waits, retries the same stream, then tries
the HLS version before showing an error card with **Retry**. Some panels
start a channel only when the first viewer asks, so the first open can be
slow.

## Testing your own builds on a Deck

For development: build on a Linux PC and push to the Deck over SSH while it
stays in Game Mode. Building needs the toolchain in the
[README](../README.md#development).

**One-time setup**

1. On the Deck, in Desktop Mode (Konsole):
   ```bash
   passwd                              # if user deck has no password yet
   sudo systemctl enable --now sshd
   ```
2. On the PC:
   ```bash
   ssh-copy-id deck@DECK_IP
   export SDTV_DECK_HOST=deck@DECK_IP  # or add it to ~/.bashrc
   ./tool/deploy-deck.sh
   ```
3. On the Deck, add `/home/deck/sdtv/run-sdtv.sh` as a non-Steam game and
   set its controller template to **Gamepad**.

**Every change:** run `./tool/deploy-deck.sh` on the PC, then quit and
relaunch sdtv on the Deck.

| Flag | Effect |
|------|--------|
| *(none)* | Build the tarball, upload it, extract to `~/sdtv` |
| `--no-package` | Upload the existing `dist/sdtv-deck.tar.gz` only |
| `--package-only` | Build the tarball only |
| `--host deck@IP` | Target Deck (else `$SDTV_DECK_HOST`) |

`tool/package-deck.sh` builds the release bundle (no mpv, codecs or Mesa
inside), rewrites library paths to prefer the system's, and writes
`run-sdtv.sh`. Always launch `run-sdtv.sh`, not `./sdtv`.

**Building on Bazzite (or another immutable Fedora):** install the toolchain
with Homebrew and `source tool/bazzite-flutter-env.sh`. If the app builds
but no window appears (`libEGL warning: … failed to create dri2 screen`),
Homebrew's Mesa is overriding the GPU driver: make sure `LD_LIBRARY_PATH` is
unset (the script does this), and try `export GDK_BACKEND=x11`.

## Network tips

- Docked Ethernet reduces live-stream buffering.
- Wi‑Fi is fine for testing UI; stress-test streams when ready.

## Screensaver during playback

In Game Mode, Steam shows a library slideshow after a few idle minutes, and
it does not notice video in non-Steam apps on its own. sdtv asks Steam to
hold the screensaver off while a video plays (`org.freedesktop.ScreenSaver`
Inhibit, which Steam provides in Game Mode). Pause, open ☰, or go back to
the guide and the normal screensaver timer applies again.

## Privacy

- Credentials stay on-device (local app data under `~/.local/share`).
- No Wangcow cloud login is required for core playback.
