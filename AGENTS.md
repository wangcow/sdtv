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

- **Phase 0:** scaffold, controller playground, mocks (current)
- **Phase 1:** login + live TV list + mpv play
- Later: EPG, VOD, Series, Flathub
