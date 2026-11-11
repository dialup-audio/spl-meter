# SPL Bar

A live SPL reading from [Room EQ Wizard](https://www.roomeqwizard.com/) in your macOS menubar.

<!-- screenshot: menubar item -->

Free tools by [dialup.audio](https://dialup.audio).

## What it does

- Shows the current SPL from REW's SPL meter (`85 dBC`), updated 4 times a second. Weighting (A, C or Z) and averaging (Fast or Slow) are set from the menu and take effect immediately. Defaults are C and Slow. **SPL offset…** adds a fixed number of dB (for example `-3.2`) to every reading, for calibrating the display to a reference level.
- Launches REW with the API enabled if it isn't already running that way.
- Configures and starts REW's SPL meter for you. REW runs headless, so there's no window to get in the way.
- **Input device:** the menu shows which mic REW is using, and **Input device** lets you pick another from REW's own list.
- **Unplug and replug:** if the mic is disconnected, the menubar shows `NO MIC` (REW itself keeps showing stale readings). When it's plugged back in, the app sets the input device and restarts the meter automatically.

## Requirements

- macOS
- **REW 5.40 beta or newer.** The REST API and headless mode (`-api`, `-nogui`) are recent additions that are still changing quickly, so this app only supports current 5.40 betas. Last tested against V5.40 Beta 140. On an older REW, it won't start with those flags and the menubar will show `REWAPI?`.
- A measurement mic. The app adopts whichever input REW is already using, and you can change it from the menu.

## How it works

1. On launch, checks whether REW's API answers (port 4735 by default).
   - **It answers:** the app uses it.
   - **REW isn't running:** the app starts it with the API on (`open -na REW.app --args -api -nogui`) and waits for it to come up.
   - **REW is running without its API:** the menubar shows `NO API` and a dialog offers to quit REW and restart it with the API on. REW is asked to quit normally, so it prompts about anything unsaved, and the app waits for it to exit (up to 90 seconds) before relaunching. To avoid this entirely, turn on **Settings → API → Start the API when REW starts** in REW. The app keeps watching and connects as soon as the API is available.
2. Talks to REW's local API: sets your input device, configures the SPL meter (your weighting and averaging choices, no high-pass), and starts it.
3. Polls the meter and shows the level.

If the app started REW headless, quitting the app also shuts that REW down. A REW that was already running is left alone.

Nothing leaves your machine except the update check, which you can turn off (see below).

## Settings

The **REW** submenu has the connection settings:
- **Run REW headless** (on by default): when this app starts REW, it passes `-nogui` so no window appears. Turn it off if you want to use REW's interface alongside the menubar meter. It applies the next time the app starts REW; an already-running REW keeps its mode.
- **API port…** (default 4735): must match **Settings → API** in REW.
- **Reconnect to REW**: re-checks the connection.

Settings are stored in the app's standard macOS preferences:

```bash
defaults read audio.dialup.spl-bar   # inputDevice, weighting, averaging, splOffset, apiPort, headless
defaults delete audio.dialup.spl-bar # reset
```

On first launch, the app adopts whichever input REW is already using.

## Permissions

None. The app talks to REW over localhost and to Core Audio for device changes, and doesn't ask for Accessibility or any other permission.

## Install

Download the latest zip from [Releases](https://github.com/dialup-audio/spl-bar/releases), unzip, and drag the app to Applications. To start it at login, add it under System Settings → General → Login Items.

## Build from source

Needs Xcode command line tools, CMake and Ninja.

```bash
make        # builds into build/
make run
```

## Updates

Once a launch, the app asks GitHub whether a newer release exists and only speaks up if there is one; turn this off with **Check for Updates on Startup** in the app's menu, and the app makes no network requests at all. **Check for Updates Now** does the same on demand and always tells you the result. Nothing is downloaded or installed automatically: the Download button opens the product page on dialup.audio. REW is talked to over localhost, so these checks are the only requests the app makes outside your machine. The same menu has **Help** and **Report an Issue**, which open the project pages on dialup.audio.
