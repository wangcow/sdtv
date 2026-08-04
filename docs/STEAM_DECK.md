# Steam Deck setup — sdtv

**Product of the Wangcow Corporation**

> sdtv is a media player only. You supply your own Xtream Codes credentials. No channels are included.

## Install (once Flatpak ships)

1. **STEAM** → Power → **Switch to Desktop**.
2. Open **Discover**, search **sdtv**, install the Flatpak (`org.wangcow.SDTV`).
3. Optional: pin or create a desktop shortcut.

### Add to Game Mode

1. In Desktop Mode, open **Steam**.
2. **Add a Game** → **Add a Non-Steam Game**.
3. Browse to the sdtv export, or use a wrapper that runs:

   ```bash
   flatpak run org.wangcow.SDTV
   ```

4. Return to Game Mode and launch **sdtv** from your library.

## Controller settings

1. Highlight sdtv → controller options (or STEAM button → Controller settings while running).
2. Set template to **Gamepad** (not Desktop / mouse & keyboard).
3. Confirm D-pad moves UI focus and A activates items.

See [CONTROLLER.md](CONTROLLER.md) for the full button map.

## Development build (now)

Until Flatpak is published, run from source on Desktop Mode:

```bash
cd ~/Documents/Programming/projects/sdtv
source tool/bazzite-flutter-env.sh   # Bazzite/Homebrew; skip on normal Fedora if dnf toolchain is installed
# Needs: brew install mpv   (libmpv for media_kit)
cd apps/sdtv
flutter pub get
flutter run -d linux
```

### Smooth video (VAAPI)

Stutter + `decode: cpu/software` means **software decode**.

We ship brew `libmpv` + `libva`, but **not** brew Mesa. VAAPI needs the Deck’s driver:

`/usr/lib64/dri/radeonsi_drv_video.so`

`run-sdtv.sh` sets:

- `LIBVA_DRIVERS_PATH=/usr/lib64/dri`
- `LIBVA_DRIVER_NAME=radeonsi` (Steam Deck APU)
- prefers system `libmpv` when present

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
cd ~/Documents/Programming/projects/sdtv
export SDTV_DECK_HOST=deck@192.168.1.180   # once per shell / add to ~/.bashrc

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

Produces brew **libmpv + codecs** (not brew GTK/X11/mesa), rewritten `DT_NEEDED`, and `run-sdtv.sh` (sets media `LD_LIBRARY_PATH` + system XKB/fontconfig paths).

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

Linux build needs `clang`, `cmake`, `ninja`, GTK 3 development libraries, and (for playback later) `libmpv`.

## Network tips

- Docked Ethernet reduces live-stream buffering.
- Wi‑Fi is fine for testing UI; stress-test streams when ready.

## Privacy

- Credentials stay on-device (XDG config under Flatpak).
- No Wangcow cloud login is required for core playback.
