# sdtv

**A controller-only IPTV player for the Steam Deck**, in the spirit of
TiviMate: a TV guide, Movies and TV Shows, all driven from the gamepad in
Steam's Game Mode. Video plays in [mpv](https://mpv.io) with hardware
decoding.

> **sdtv is a player only.** It does not provide, host or distribute any
> channels, playlists or streams. You bring your own provider account.

**Product of the Wangcow Corporation** · App ID `org.wangcow.SDTV` ·
[Apache-2.0](LICENSE)

## Features

- **Live TV guide:** channels down the side, programmes across a timeline,
  channel logos, now / next for the focused channel.
- **Movies and TV Shows:** poster grids, a title page (plot, cast, rating,
  trailer), seasons and episodes, resume where you left off, watched marks,
  and the next episode starts on its own.
- **On-screen controls while watching:** previous / next / last channel,
  next episode, seek, subtitles and audio tracks, drawn over the mpv video.
- **Favorites** for live channels, movies and shows.
- **Search** across live channels, movies and TV shows.
- **Your guide, your order:** hide categories you never watch and move the
  ones you do to the top.
- **Several playlists:** Xtream Codes accounts and M3U playlists, with a
  switcher in Settings.
- **Deck-friendly:** keeps Steam's screensaver away during playback and
  recovers from slow-starting or failed streams with a retry card.
- **Demo mode:** a built-in sample catalog (playing a public test stream)
  to try sdtv without an account.

## Install on the Steam Deck

1. In Desktop Mode, install **mpv** from **Discover**.
2. Download `sdtv-deck.tar.gz` from the latest
   [release](https://github.com/wangcow/sdtv/releases) and extract it to
   `~/sdtv`.
3. Add `~/sdtv/run-sdtv.sh` to Steam as a non-Steam game.
4. In Game Mode, set the controller template to **Gamepad**.

Step-by-step instructions, updating, and troubleshooting are in
[docs/STEAM_DECK.md](docs/STEAM_DECK.md).

sdtv is released only as this tarball. There is no Flatpak and it is not on
Flathub: Flathub's policy bars AI-written packaging, and sdtv is largely
AI-written.

## Controls at a glance

| Button | In the guide | While watching |
|--------|--------------|----------------|
| D-pad / stick | Move | Move between on-screen buttons |
| **A** | Select / play | Press the focused button |
| **B** | Back | Hide the controls, then leave |
| **LB / RB** | Switch Live ⇄ Movies ⇄ TV Shows | Channel − / + (live) · seek (movies, shows) |
| **Y** | Favorite | Favorite (live) |
| **X** | Hide the focused category | Mute |
| **☰** | Menu: Search, Settings, Exit | Subtitles, audio, mute |

The full map is in [docs/CONTROLLER.md](docs/CONTROLLER.md). A keyboard
works too (arrows, Enter, Esc).

## Development

sdtv is a Flutter Linux app in a pub workspace:

```text
apps/sdtv/              Flutter app: UI and session state
packages/sdtv_core/     Xtream / M3U clients, models, EPG
packages/sdtv_input/    Gamepad → focus and actions
packages/sdtv_player/   External mpv: launch, JSON IPC, HUD bitmap overlay
tool/                   run, package and deploy scripts; mock Xtream fixtures
docs/                   Controller map, Steam Deck guide, library format
```

**You need:** Flutter (stable) with Linux desktop support, the Linux
toolchain (`clang`, `cmake`, `ninja`, `pkg-config`, GTK 3 headers) and an
`mpv` binary.

```bash
dart pub get                 # from the repo root
./tool/run.sh                # or: cd apps/sdtv && flutter run -d linux
```

On Bazzite or another immutable Fedora, install the toolchain with Homebrew
and `source tool/bazzite-flutter-env.sh` first (it finds Flutter in
`~/.sdk/flutter` or `~/sdk/flutter`).

**Tests** use mock fixtures only and never reach a real provider:

```bash
cd packages/sdtv_core && dart test
cd packages/sdtv_input && flutter test
cd packages/sdtv_player && flutter test
cd apps/sdtv && flutter test
```

[CI](.github/workflows/ci.yml) runs `flutter analyze` (any finding fails,
infos included) and all four suites on pushes to `main` and on pull
requests.

**Trying a build on a Deck:** `./tool/deploy-deck.sh` packages the app and
copies it to a Deck over SSH (see
[docs/STEAM_DECK.md](docs/STEAM_DECK.md#fast-game-mode-test-loop-recommended)).

### Environment variables

| Variable | Effect |
|----------|--------|
| `SDTV_FORCE_MOCK=1` | Connect uses the mock catalog instead of a real panel |
| `SDTV_MPV_PATH` | mpv to use: a path, or `flatpak:io.mpv.Mpv` |
| `SDTV_ENABLE_GAMEPAD=0` | Turn off the joystick reader |
| `SDTV_PAD_ALL=1` | Read every joystick, even when Steam Input's virtual pads are present |
| `SDTV_DEMO_STREAM` | Stream URL for demo mode |
| `SDTV_PLAY_LOG` | File for stream start diagnostics (`run-sdtv.sh` sets it) |

On the Deck, put these in `~/sdtv/sdtv.env`.

### Rules for contributors

- Every screen must work with a controller alone.
- Never commit credentials, provider URLs or playlists. Use the fixtures in
  `tool/mock_xtream/fixtures/`. Automated traffic can get a real account
  banned.
- Video always plays in mpv, never through a Flutter texture.

More in [AGENTS.md](AGENTS.md).

### Releasing

```bash
bash tool/package-deck.sh    # → dist/sdtv-deck.tar.gz
```

Attach `dist/sdtv-deck.tar.gz` to a tagged GitHub release.

## License

Copyright 2026 Wangcow Corporation. Licensed under the Apache License 2.0;
see [LICENSE](LICENSE) and [NOTICE](NOTICE).

**Product of the Wangcow Corporation:** this attribution must be kept in
redistributions and is shown in the app's About screen.
