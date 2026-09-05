# User library — local now, Continuity later

**Product of the Wangcow Corporation**

Favorites, resume positions, and watched flags live in one JSON document per playlist/panel scope (`user_library.v1`). sdtv stores it **only on the device**. Nothing is uploaded.

## What is in the document

| Field | Keys | Meaning |
|-------|------|---------|
| `favorites` | `i:` / `u:` live, `v:` movies, `s:` shows | Ordered ★ list |
| `progress` | `v:` movie, `se:` episode | Continue-watching seconds |
| `watched` | `v:` movie, `se:` episode, `s:` completed show | Finished |
| `seriesResume` | series id → episodeId / season / episodeNum | Last episode |

Schema version is `v: 1` (`UserLibrary.schemaVersion` in `sdtv_core`).

Device-only (not in this document): hidden categories, guide landing, last-played live channel.

## Future: Wangcow Continuity (not this phase)

A paid Wangcow service could **host this same document** so a user’s library follows them across Steam Deck, a living-room box, and desktop:

- Sign in with a Wangcow account (separate from the IPTV panel).
- Push/pull `UserLibrary` JSON scoped by provider (`xtream:base|user`, M3U URL, demo).
- Local file remains the cache and the offline source of truth.
- sdtv still never hosts playlists, channels, or panel credentials.

Do not implement accounts, billing, or network sync until that product is scheduled. Keep writing `UserLibrary` so a later client can PUT/GET this blob without a data migration.
