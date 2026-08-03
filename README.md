# sdtv

**Steam Deck–first IPTV player** with a TiviMate-like couch experience.

Import your Xtream Codes URL, username, and password → browse Live TV (Movies / Series / EPG later) → navigate entirely with a gamepad. No mouse or trackpad-as-pointer required.

> **sdtv is a media player only.** It does not provide, host, or distribute any channels, playlists, or streams. You bring your own provider credentials.

**Product of the Wangcow Corporation**

| | |
|---|---|
| App ID | `org.wangcow.SDTV` |
| License | Apache-2.0 (see [LICENSE](LICENSE) + [NOTICE](NOTICE)) |
| Domain | [wangcow.com](https://wangcow.com) |
| Platform | Linux (Steam Deck / Flatpak first); Android later via Flutter |

## Product pillars

1. **Controller-first UI** — D-pad / stick focus, A confirm, B back. Keyboard works for desktop dev.
2. **Steam Game Mode** — Flatpak → non-Steam game → Gamepad Steam Input template.
3. **Hardware decode** — libmpv via media_kit, VAAPI on Deck.
4. **Xtream Codes first** — URL + user + pass. M3U later.
5. **Open source / Flathub-bound** — Apache-2.0 with Wangcow attribution in About.

## Status

**Phase 3 (live Xtream).** Deck MVP complete: demo/mock couch playback + packaging.  
**Connect** uses your real Xtream Codes server (catalog + stream URLs). **Demo** stays offline fixtures + public test HLS.

### Run

```bash
source tool/bazzite-flutter-env.sh
./tool/run.sh
```

1. **Continue with demo playlist** — offline mock catalog + bipbop HLS.  
2. **Connect to provider** — real `player_api.php` + `/live/user/pass/id.ts` (try `.m3u8` on failure).  
3. Gamepad: D-pad browse · A play/pause · B back · LB/RB channel.

Optional env:

| Variable | Meaning |
|----------|---------|
| `SDTV_ENABLE_GAMEPAD=0` | Disable joystick reader |
| `SDTV_FORCE_MOCK=1` | Connect uses mock catalog (CI / offline) |
| `SDTV_ALLOW_LIVE=0` | Legacy alias for force-mock |
| `SDTV_DEMO_STREAM=url` | Override demo HLS URL |

On Deck, put env in `~/sdtv/sdtv.env` next to `run-sdtv.sh` (see [docs/STEAM_DECK.md](docs/STEAM_DECK.md)).

## Repo layout

```text
sdtv/
  apps/sdtv/           # Flutter Linux app
  packages/
    sdtv_core/         # Xtream client, models, cache
    sdtv_input/        # Gamepad → Flutter intents (critical)
    sdtv_player/       # media_kit / libmpv wrapper (stub)
  flatpak/             # org.wangcow.SDTV manifest stubs
  tool/mock_xtream/    # Fixture JSON for safe offline dev
  docs/                # Controller map, Steam Deck setup
```

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install/linux) stable (Linux desktop)
- Linux toolchain: `clang`, `cmake`, `ninja`, `pkg-config`, GTK 3 dev libs
- For playback later: `libmpv` / VAAPI stack

### Bazzite / immutable Fedora (this machine)

Host packages are locked; use **Homebrew** for the Flutter Linux toolchain (already proven on this project):

```bash
brew install cmake ninja llvm gtk+3 xorgproto mpv
# Flutter SDK (if needed):
# git clone https://github.com/flutter/flutter.git -b stable ~/sdk/flutter
```

Then **always** load the env (or use `./tool/run.sh`, which does it for you):

```bash
source tool/bazzite-flutter-env.sh
```

You do **not** need a separate laptop just because Bazzite is immutable.

If Flutter was installed under `~/sdk/flutter`:

```bash
export PATH="$HOME/sdk/flutter/bin:$PATH"
```

## Develop

The Flutter **app** lives in `apps/sdtv` (not the repo root). Running `flutter run` from the monorepo root fails with `Target file "lib/main.dart" not found`.

```bash
cd ~/Documents/Programming/projects/sdtv
source tool/bazzite-flutter-env.sh

# From repo root — resolve workspace
dart pub get   # or: flutter pub get

# Run the app (must be apps/sdtv)
cd apps/sdtv
flutter run -d linux
```

Or from anywhere in the repo (loads Bazzite/Homebrew env automatically):

```bash
./tool/run.sh
```

Run package tests (mock fixtures only — no live providers):

```bash
cd packages/sdtv_core && dart test
cd ../sdtv_input && flutter test
```

### Controller playground

The default screen is a **focus maze** (no network). Use:

- Arrow keys / D-pad / left stick — move focus  
- Enter / A — activate  
- Escape / B — back (logs action)  
- See [docs/CONTROLLER.md](docs/CONTROLLER.md)

### Xtream testing policy

**Mocks only in CI and early development.** Do not commit real provider URLs or passwords. A paid Xtream account can be banned if abused by automated clients — keep live credentials local and gitignored until you deliberately test playback on your machine.

Fixtures live under `tool/mock_xtream/fixtures/`.

## Flatpak (stub)

```text
flatpak/
  org.wangcow.SDTV.yml
  org.wangcow.SDTV.desktop
  org.wangcow.SDTV.metainfo.xml
```

Build pipeline and Flathub submission come after MVP Live TV is Deck-validated.

## Steam Deck (preview)

See [docs/STEAM_DECK.md](docs/STEAM_DECK.md). Short version: install Flatpak → add as non-Steam game → set controller template to **Gamepad** (not Desktop/mouse).

## MVP roadmap

1. ~~Scaffold + controller playground~~  
2. Xtream login (mock then optional live) + live categories/channels  
3. libmpv playback + channel zap  
4. Favorites / short EPG  
5. Movies + Series + full EPG grid  
6. Flathub

## License

Copyright 2026 Wangcow Corporation  

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

**Product of the Wangcow Corporation** — this attribution must be preserved in redistributions and shown in the application About footer.
