# Lumtub

**A lightweight YouTube client for Windows. No Electron, no web player.**

Lumtub was called YTPlus until October 2026. Updating keeps your settings, library and sign-in: the data folder is renamed on first launch.

Lumtub is built with Flutter, [media_kit](https://github.com/media-kit/media-kit) (libmpv) and [yt-dlp](https://github.com/yt-dlp/yt-dlp). It uses neither Electron nor a web player. Its interface follows [PiliNara](https://github.com/Starfallan/PiliNara), a third-party Bilibili client.

[Features](#features) · [Privacy](#privacy) · [Install](#install-and-use) · [Building](#building) · [License](#license-and-attribution)

## Features

**Browsing**
- Home: continue watching, recently watched, and a "For you" feed worked out on your computer. It mixes long-term interests, recent interests, exploration, and popular and new videos; it scrolls endlessly, each card says why it was suggested, and any video can be marked "Not interested".
- Explore: video and live halves split into categories, Bilibili style, each with sub-categories. Browse by For you, Popular, Latest, Hidden gems or Long videos, filter by length and quality (1080p, 4K, HDR), and see upcoming streams and replays. Categories can be added, hidden, pinned and reordered. Videos and live both start with Recommended (your interests mixed with the categories) and All (every category, not personalised), which can be shuffled. Filter by region (YouTube's country setting) and language (guessed from the title).
- Search: suggestions and history, sort order, upload date and length filters, and videos, Shorts, live streams, channels or playlists only.
- Channel pages: videos, Shorts, live, playlists, podcasts and community posts, with search inside the channel. A post's comments open on the right.
- Subscriptions, history, local playlists and favorites. Alt+← or the mouse back button returns to the previous page.

**Playback**
- libmpv playback with hardware decoding, video and audio quality, speed, subtitles (including automatic and translated captions), chapters, fullscreen and keyboard shortcuts. The watch page's title, description and chapter names, posts, comments and subtitles follow the interface language where a translation exists.
- Streams come through Piped by default (the fastest public server is picked automatically), falling back to YouTube directly.
- Optional SponsorBlock, dislike counts (Return YouTube Dislike) and DeArrow titles and thumbnails in place of clickbait, all off by default.
- Comments, related videos and descriptions. On wide windows comments and Up next share tabs to the right of the player.

**Google account (optional)**
- Sync subscriptions and playlists, like or dislike videos, post comments and replies, save to YouTube playlists, and subscribe on YouTube when following a channel.
- Needs your own Google OAuth client (see below). Credentials are kept on your computer, encrypted with Windows DPAPI.

**Other**
- English interface. Subtitle and caption languages are unaffected and can be any language YouTube offers.
- Proxy: follow the system, none, or a manual HTTP / SOCKS5 proxy.
- Light and dark themes, accent colours, fonts, card size and more.
- Settings can be exported, imported and reset.

**Channel blocking**
- Optional block lists for channels, switched on or off in settings.
- Block a channel, or stop recommending one: add it in settings by link or full name, or from the menu on a video card, channel page or the watch page. Channels not recommended still show in searches and follows.

## Privacy

Recommendations, history, searches and "Not interested" stay on your computer and are never uploaded. Lumtub does not read browser cookies. When Piped is used, the Piped server knows which video you watch; to avoid that, choose a direct YouTube connection under Settings › Playback.

## Install and use

1. Download the portable ZIP or the installer for your PC from the **Build** GitHub Actions workflow or from Releases: `x64-v3` for CPUs with AVX2 (most from 2015 on), `x64` for older ones, `arm64` for Windows on ARM.
2. Unzip and run `lumtub.exe`; no administrator rights are needed.
3. The first start downloads yt-dlp and Deno and needs access to GitHub. Updates are checked at most once a day and apply after a restart.

Data lives in the `config`, `data`, `cache`, `components` and `logs` folders under `%LOCALAPPDATA%\Lumtub` for the installed app, and in the `userdata` folder next to `lumtub.exe` for the portable ZIP (delete its `portable.txt` to use `%LOCALAPPDATA%` instead; a portable copy in a folder it cannot write to falls back to it as well). The log is `logs\lumtub.log`; Settings › About can copy diagnostics.

### Google sign-in

1. In Google Cloud Console, create an OAuth client of type "Desktop app" and enable YouTube Data API v3.
2. Enter its client ID and secret under Settings › Google account and sign in. They can also be built in through the repository secrets `LUMTUB_GOOGLE_CLIENT_ID` and `LUMTUB_GOOGLE_CLIENT_SECRET`.
3. A client you create yourself is not reviewed by Google, so sign-in may warn that the app is unverified; continue past it.

## Building

The Windows build runs on GitHub Actions (`.github/workflows/build.yml`) for pushes and pull requests to `main`, or by hand from the Actions page. For each of x64, x64-v3 and arm64 it bundles a verified libmpv for that CPU, builds and tests the Rust library in `native/lumtub_core` (release profile with fat LTO, one codegen unit, and `target-cpu=x86-64-v3` for x64-v3), runs `flutter analyze` and the unit tests, and uploads a portable ZIP and an Inno Setup installer. Pushing a `v*` tag (such as `v0.2.0`) also publishes them as a GitHub release.

`lumtub_core.dll` is optional at run time: without it Lumtub works as before, minus what it adds (for now, stopping yt-dlp also stops the ffmpeg and Deno it started, and none of them outlive Lumtub).

Building locally needs Flutter 3.47 and Visual Studio with the C++ desktop workload, plus Rust for the native library:

```powershell
flutter pub get
flutter test
flutter build windows --release
cargo build --release --manifest-path native/lumtub_core/Cargo.toml
```

### Translations

The interface is English for now. Source strings are still written in simplified Chinese in the code and wrapped in `tr('…')`, and `lib/l10n/strings_en.dart` maps them to English; `test/l10n_test.dart` checks that every string has an English translation. Chinese interface languages are switched off for the moment.

## Known limits

- Windows only for now.
- Search or playback can break when YouTube changes; an updated yt-dlp usually fixes it.
- The official API cannot like or comment on community posts.

## License and attribution

Lumtub is licensed under the GNU General Public License, version 3 or later (`GPL-3.0-or-later`).

The settings tiles in `lib/widgets/pilinara_settings_tiles.dart` are adapted from [PiliNara](https://github.com/Starfallan/PiliNara), copyright its contributors, and remain under GPL-3.0-or-later. `vendor/pilinara-settings/` and `vendor/pilinara-player/` are unmodified PiliNara source snapshots kept for reference; they are not built. `vendor/media_kit_video/` is a copy of media_kit_video with one Windows fix (see its `LUMTUB.md`).

The bundled Noto Sans SC font is under the SIL Open Font License 1.1 (`assets/fonts/OFL.txt`). Other packages and runtime components keep their own licenses; review `NOTICE` before redistributing.
