# PiliNara player source snapshot

This directory is an unmodified source snapshot of `lib/plugin/pl_player/`
from [Starfallan/PiliNara](https://github.com/Starfallan/PiliNara) commit
`b908eccfbcc3930c5ead47bc728e164ff1675cf6`, imported on 2026-10-18.

It is GPL-3.0-or-later and includes the upstream `LICENSE`. The snapshot is
outside `lib/`, so it has no effect on the Lumtub build yet. Lumtub will adapt
the player surface and controls while replacing Bilibili-only state, data URLs,
danmaku, account actions, and GetX bindings with its existing YouTube/yt-dlp
and media_kit state.
