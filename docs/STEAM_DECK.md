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

### Shipping a release bundle to another Deck

On the **build machine** (Bazzite + Homebrew mpv):

```bash
cd ~/Documents/Programming/projects/sdtv
source tool/bazzite-flutter-env.sh
# Needs: brew install mpv patchelf
bash tool/package-deck.sh
```

That produces:

- `apps/sdtv/build/linux/x64/release/bundle/` — full tree with brew `libmpv` + deps, soname links, absolute `DT_NEEDED` rewritten, `run-sdtv.sh`
- `dist/sdtv-deck.tar.gz` — same tree as a single archive (preferred for transfer)

#### Deploy (recommended)

**Do not** `scp -r` over a previous install. Old brew libs are often read-only (`555`), so scp hits **Permission denied**, leaves a half-updated tree, and you still get `libmujs` / Cellar errors.

On the **Deck** (ssh or Konsole):

```bash
rm -rf ~/sdtv ~/Documents/sdtv
mkdir -p ~/sdtv
```

On the **build machine**:

```bash
scp dist/sdtv-deck.tar.gz deck@DECK_IP:~/sdtv-deck.tar.gz
```

On the **Deck**:

```bash
tar -xzf ~/sdtv-deck.tar.gz -C ~/sdtv
chmod +x ~/sdtv/run-sdtv.sh ~/sdtv/sdtv
cd ~/sdtv && ./run-sdtv.sh
```

Always launch with **`./run-sdtv.sh`**, not `./sdtv` — the wrapper sets `LD_LIBRARY_PATH` to the bundled `lib/` only.

**Game Mode:** Steam → Add a Non-Steam Game → pick `~/sdtv/run-sdtv.sh`.

If you still see `libmujs.so` / Cellar path errors:

1. Confirm you wiped the old dir (`rm -rf`) before extract.
2. Check `ls -la ~/sdtv/lib/libmpv* ~/sdtv/lib/libmujs*` — both must exist.
3. Re-run `package-deck.sh` and redeploy the tarball.### Bazzite vs regular Fedora

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
