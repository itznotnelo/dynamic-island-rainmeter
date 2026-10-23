# Dynamic Island for Rainmeter

A notch-style Dynamic Island for Windows, built with [Rainmeter](https://www.rainmeter.net/). It hangs
from the top edge of the screen, shows the time, and comes alive when music plays or Claude Code is
working. The look and the motion follow [Bloom](https://github.com/SehajveerSingh2005/bloom) by
Sehajveer Singh: the same sizes, colours, font and spring physics, rebuilt from scratch for Rainmeter.

![The island showing the time](screenshot.png)

## What it does

| | |
|---|---|
| ![Black notch with the time](screenshot.png) | **Idle.** A 124x36 black notch with the clock, curving into the screen edge. Hovering darkens it a little. |
| ![Notch with visualizer, time and album cover](screenshot-now-playing.png) | **Music.** A 5-bar visualizer that reacts to what you hear, and the album cover with a soft glow. Five seconds after you pause, it goes back to the clock. |
| | **Calendar and focus timer.** Click the notch (or scroll on it) to open this month's calendar next to a focus timer: presets of 5, 15, 25 and 50 minutes, Start / Pause / Resume and reset. While it runs, the notch shows the time left, and when it ends you hear a chime and see "Time's up". |
| ![Expanded player with cover, title, controls and volume](screenshot-player.png) | **Player.** Click the album cover (or scroll while the calendar is open) for the player: cover, title (it scrolls when it's too long), artist, previous / play-pause / next and the system volume (click the bar to set it). After that, a click on the notch brings back whichever view you used last. Moving the mouse away closes it. |
| ![Claude bubble beside the notch](screenshot-claude.png) | **Claude Code.** While a session runs, a bubble slides out beside the notch. Its spark twinkles while Claude works, blinks when it needs you and dims when it's done, in the colour of the permission mode. |
| ![Notch saying needs you](screenshot-claude-needs-you.png) | **Pulses.** For a few seconds the notch widens and says what happened: "needs you", "done", a mode switch, or a battery change. |

Width, height and the bubble move on springs with Bloom's constants (width 400/31, height 450/29),
the old content fades out before the new one fades in, and it all runs at 60 frames a second. When
nothing moves, the skin does almost no work.

## Requirements

- Windows 10/11 and [Rainmeter](https://www.rainmeter.net/) 4.5 or newer. It uses the Lua, AudioLevel
  and Win7Audio plugins that come with Rainmeter.
- The Inter font is included in `@Resources\Fonts` (SIL Open Font License), so there's nothing to install.
- Album covers need Python 3 with
  `pip install winrt-runtime winrt-Windows.Media.Control winrt-Windows.Storage.Streams winrt-Windows.Foundation pillow`.
  Without it the island shows an empty tile where the cover would be.

## Installation

1. Download or clone this repository.
2. Copy the folder into your Rainmeter skins folder, typically `Documents\Rainmeter\Skins\DynamicIsland`.
3. In Rainmeter, refresh the skin list and load `DynamicIsland.ini`. It centres itself at the top of
   the screen and stays on top.

## Claude Code

If you use [Claude Code](https://claude.com/claude-code), the island shows what it's doing:

| Spark in the bubble | Meaning |
|---|---|
| twinkling | Claude is working |
| blinking | Claude needs you (a permission prompt or a question) |
| still and dimmed | Claude is done and it's your turn (the bubble leaves after 10 minutes) |

The spark's colour is the permission mode, as in the Claude Code footer: orange for manual, teal for
plan, purple for accept edits, yellow for auto, pink for bypass. With several sessions open, the
island follows the most urgent one and doesn't jump between sessions that are equally busy.

Setup:

1. Copy `claude-code/claude-modes.py` to `~/.claude/hooks/` (Python 3 on your PATH).
2. Merge the `hooks` block from `claude-code/hooks.json` into `~/.claude/settings.json`, then open
   `/hooks` once in Claude Code (or restart it) so it picks them up.

The hook writes `~/.claude/claude-modes/status.json`, which `NowPlaying.ps1` reads every second. The
hooks run in the background, so Claude never waits for them. Without the hook the bubble stays hidden.

## How it works

- `DynamicIsland.ini`: the measures and meters. Everything inside the notch is clipped to its shape.
- `@Resources\Island.lua`: the springs, fades, title marquee and visualizer smoothing. It hands its
  results to the meters as variables and redraws only when something changed.
- `@Resources\NowPlaying.ps1`: once a second reads the media session (SMTC), battery (WMI), microphone
  and camera use (registry) and the Claude Code status, and writes `NowPlaying.inc` for the skin.
- `@Resources\cover.py`: on each new track reads the cover from the media session (WinRT) and renders
  the rounded tiles and the blurred glow behind the player (Pillow).

## Credits

Design and motion after [Bloom](https://github.com/SehajveerSingh2005/bloom) by Sehajveer Singh
(GPL-3.0). No Bloom code or images are used here: the sizes, colours and spring values were taken
from it and implemented again for Rainmeter. Font: [Inter](https://rsms.me/inter/) by Rasmus
Andersson (SIL Open Font License, see `@Resources\Fonts\OFL.txt`).

## License

MIT, see [LICENSE](LICENSE).
