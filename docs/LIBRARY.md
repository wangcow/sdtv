# User library — local now, Continuity later

**Product of the Wangcow Corporation**

Favorites, resume positions, and watched flags live in one JSON document per playlist/panel scope (`user_library.v1`). sdtv stores it **only on the device**. Nothing is uploaded.

## What is in the document

| Field | Keys | Meaning |
|-------|------|---------|
| `favorites` | `i:` / `u:` live, `v:` movies, `s:` shows | Ordered ★ list |
| `progress` | `v:` movie, `se:` episode | Continue-watching seconds |
| `progressAt` | same keys as `progress` | Unix ms of that playhead. A stamp with no seconds means the spot was cleared |
| `watched` | `v:` movie, `se:` episode, `s:` completed show | Finished movies, episodes, and shows |
| `watchedAt` | same keys as `watched` | Unix ms when it was marked watched |
| `seriesResume` | series id → episodeId / season / episodeNum | Last episode |
| `seriesResumeAt` | series id | Unix ms of that episode pointer |
| `updatedAt` | document | Unix ms of the last edit |

Schema version is `v: 1` (`UserLibrary.schemaVersion` in `sdtv_core`). New fields are additive. `fromJson` still accepts a document that has only `progress` seconds and a `watched` list (no timestamps).

One playback sample writes progress, watched, and the series pointer together (`UserLibrary.withWatchUpdate` / `SettingsStore.saveWatchProgress`) under a single timestamp.

Device-only (not in this document): hidden categories, guide landing, last-played live channel. Panel credentials stay in the local settings store and are never part of this blob.

## Future: Wangcow Continuity (not this phase)

A paid Wangcow service can **host this same document** so a library follows a signed-in user. Example: they are 10 minutes into an episode on a phone; the living-room player picks up that spot, and a movie they already finished on either screen stays finished on both.

- Sign in with a Wangcow account (separate from the IPTV panel).
- Push/pull `UserLibrary` JSON scoped by provider (`xtream:base|user`, M3U URL, demo).
- Local storage stays the offline copy. After a pull, call `SettingsStore.mergeLibrary` (or `replaceLibrary` when the host copy is already merged) and `SessionController.reloadUserLibrary`.
- Conflict rule is `UserLibrary.merge`: watched keys union; the newer playhead wins; a newer clear beats an older spot; the newer series episode wins; favorites union, with the newer document’s order first. Un-starring on only one device is not a tombstone yet, so a star that still exists on either copy remains.
- sdtv still never hosts playlists, channels, or panel credentials.

Do not implement accounts, billing, or network sync until that product is scheduled. Do not store continue-watching or watched state anywhere except this document.
