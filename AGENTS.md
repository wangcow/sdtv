# AGENTS.md — sdtv

Guidance for humans and coding agents working in this repo.

## Product

- **sdtv** = Steam Deck–first, controller-only IPTV player (TiviMate-like UX).
- App ID: `org.wangcow.SDTV`
- Player only — never ship playlists, channels, or credentials.
- **Product of the Wangcow Corporation** must remain in NOTICE and About UI.

## Stack

- Flutter Linux desktop + packages monorepo
- Playback: media_kit / libmpv (Phase 1+)
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
| `flatpak/` | Flatpak manifest + metainfo |
| `docs/` | Controller map, Steam Deck install |

## Commands

```bash
export PATH="${HOME}/sdk/flutter/bin:$PATH"
dart pub get
cd apps/sdtv && flutter run -d linux
cd packages/sdtv_core && dart test
```

## Phase focus

Daily watch is **external mpv** (`vo=gpu`). Flutter is the guide. On-video chrome is mpv OSD / ASS overlay. Do **not** chase Flutter-texture FPS for live TV — Deck embed is 7–15fps and cannot match mpv picture quality.

- **Now:** Live tab is the EPG grid · external mpv + OSD/ASS chrome · Movies / TV Shows poster grid · title landing · seasons/episodes · provider art cache · Search covers live, movies, and TV shows
- **Next:** Flathub
- Later: program search in Search overlay · catch-up if the panel supports it
- **Future product (not this phase):** Flutter HUD *over* live mpv so widgets sit on a separate plane. Video must **never** go through `media_kit`’s `Video` texture. Gamescope Game Mode is the hard constraint — do not chase X11 `--wid` / stacked windows.
