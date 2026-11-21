# AGENTS.md — sdtv

Guidance for humans and coding agents working in this repo.

## Product

- **sdtv** = Steam Deck–first, controller-only IPTV player (TiviMate-like UX).
- App ID: `org.wangcow.SDTV`
- Player only — never ship playlists, channels, or credentials.
- **Product of the Wangcow Corporation** must remain in NOTICE and About UI.

## Stack

- Flutter Linux desktop + packages monorepo
- Playback: external mpv process over JSON IPC (`packages/sdtv_player`)
- Xtream Codes API client in `packages/sdtv_core`

## Hard rules

1. **Controller-first** — every new screen must be fully focus-navigable without a mouse.
2. **No live Xtream in CI** — use `tool/mock_xtream/fixtures/` only.
3. **Never commit credentials** — `.env`, passwords, real server URLs stay gitignored.
4. **Attribution** — keep Apache-2.0 LICENSE + NOTICE; About footer shows Wangcow line.
5. Prefer small, focused diffs; do not expand scope past the current phase.

## Layout

| Path | Role |
|------|------|
| `apps/sdtv` | Flutter app entry + UI |
| `packages/sdtv_input` | Gamepad → intents (product differentiator) |
| `packages/sdtv_core` | Models, Xtream client, fixtures parsers |
| `packages/sdtv_player` | Playback wrapper |
| `branding/` | App icon (SVG + 256px PNG) |
| `docs/` | Controller map, Steam Deck install |

## Commands

```bash
source tool/bazzite-flutter-env.sh   # ~/.sdk/flutter, else ~/sdk/flutter
dart pub get
cd apps/sdtv && flutter run -d linux
cd packages/sdtv_core && dart test
```

## Phase focus

Daily watch is **external mpv** (`vo=gpu`). Flutter is the guide. On-video chrome is the Flutter `PlayerChrome` rasterized onto that mpv with bitmap `overlay-add` (not ASS, not `show-text`). Do **not** chase Flutter-texture FPS for live TV — Deck embed is 7–15fps and cannot match mpv picture quality. Video must **never** go through a Flutter texture; the embedded media_kit player was removed.

- **Now:** Live tab is the EPG grid · external mpv + Flutter HUD bitmap · Movies / TV Shows poster grid · title landing · seasons/episodes · provider art cache · Search covers live, movies, and TV shows · ★ Favorites on live, movies, and TV shows
- **Next:** GitHub releases of the Deck tarball (`tool/package-deck.sh`). No Flatpak and no Flathub: Flathub's policy bars AI-written packaging.
- Later: program search in Search overlay · catch-up if the panel supports it · a clear corner in the same bitmap so the guide can scroll over a live picture · paid Wangcow Continuity (host the timestamped `UserLibrary` JSON across signed-in devices — merge with `UserLibrary.merge`; do not add a second watch store — see [docs/LIBRARY.md](docs/LIBRARY.md))
- Gamescope Game Mode is one nest. Do not chase X11 `--wid` / stacked windows, and do not write a second video presenter unless `overlay-add` cannot take the bitmap.
