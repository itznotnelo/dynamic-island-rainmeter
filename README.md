# Dynamic Island for Rainmeter

A macOS-style Dynamic Island for Windows, built with [Rainmeter](https://www.rainmeter.net/). Sits collapsed at the top-center of your screen showing a small clock, and expands smoothly on hover to show what's currently playing.

![Dynamic Island collapsed, showing the clock](screenshot.png)

## Features

- **Idle clock** - a small pill docked top-center showing the time
- **Hover to expand** - smoothly grows to show the current media session (title, artist, progress bar, playback controls) via Windows' native System Media Transport Controls - no Spotify/media-player API keys, no browser extension
- **Playback controls** - previous / play-pause / next, right from the pill
- **Battery swap-in** - on plug/unplug, the clock briefly swaps for the battery percentage in the same small pill, no resizing
- **Low battery warnings** - the percentage swaps in again automatically (in red) if you drop below 20%, and again at a more urgent 10% critical tier
- **Mic / camera privacy dot** - a small colored dot appears on the collapsed pill while the microphone or camera is actively in use
- **App icon** - shows the source app's icon (Spotify, browser, etc.) next to the now-playing info

No credentials, API keys, or browser extensions required anywhere - everything is read from native Windows APIs (SMTC, WMI, and the registry).

## Requirements

- Windows 10/11
- [Rainmeter](https://www.rainmeter.net/) (4.x or newer)
- The **JetBrainsMono Nerd Font** installed - it's what renders the playback/battery icons. Get it from [Nerd Fonts](https://www.nerdfonts.com/font-downloads). Without it, the icons will show as blank boxes (the text will still work fine).

## Installation

1. Download or clone this repository.
2. Copy the `DynamicIsland` folder into your Rainmeter skins folder - typically:
   ```
   Documents\Rainmeter\Skins\DynamicIsland
   ```
3. In Rainmeter, refresh the skin list (right-click the tray icon → Refresh all, or `Manage` → refresh) and load `DynamicIsland.ini`.
4. Make sure JetBrainsMono Nerd Font is installed, then refresh the skin once more if the icons don't show up right away.

The skin polls system state (media session, battery, mic/camera) via a PowerShell script every second - all state files it generates (`NowPlaying.inc`, `EventState.json`, `SourceIcon.png`) are created automatically on first run in `@Resources\`.

## How it works

- `DynamicIsland.ini` is the Rainmeter skin itself - meters, layout, and the hover/event animation logic.
- `@Resources\NowPlaying.ps1` is a small poller script (run periodically via Rainmeter's `RunCommand` plugin) that reads:
  - the current media session via the `Windows.Media.Control` WinRT API
  - battery status via WMI (`Win32_Battery`)
  - microphone/camera activity via the `CapabilityAccessManager` registry keys
  
  ...and writes it all to a plain-text `.inc` file that the skin reads via a `WebParser` measure.

## License

MIT - see [LICENSE](LICENSE).
