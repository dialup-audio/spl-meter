# REW SPL Meter

A live SPL reading from [Room EQ Wizard](https://www.roomeqwizard.com/) in your macOS menubar.

<!-- screenshot: menubar item -->

Free tools by [dialup.audio](https://dialup.audio).

## What it does

- Shows the current C-weighted, slow SPL from REW's SPL meter (`85 dBC`), updated 4 times a second.
- Launches REW with the API enabled if it isn't already running that way.
- Opens and starts REW's SPL meter for you, then minimizes REW so it's out of the way.
- **Input device:** the menu shows which mic REW is using, and **Input device** lets you pick another from REW's own list.
- **Unplug and replug:** if the mic is disconnected, the menubar shows `NO MIC` (REW itself keeps showing stale readings). When it's plugged back in, the app sets the input device and reopens and restarts the meter automatically.

## Requirements

- macOS
- **A REW beta that supports the `-api` flag.** The REST API lives in REW's beta builds. On a release without it, REW won't start with `-api`, and the menubar will show `REWAPI?`.
- A measurement mic set up in REW as usual (this app doesn't touch your input device).

## How it works

1. On launch, checks whether REW is running with `-api`. If it isn't running, or is running without it, the app starts a REW instance with `-api` (`open -na REW.app --args -api`). A second REW window is harmless.
2. Talks to REW's local API at `127.0.0.1:4735`: opens the SPL meter, configures it (C-weighting, slow filter, no high-pass), and starts it.
3. Polls the meter and shows the level.
4. Minimizes REW's windows.

Nothing leaves your machine unless you click Check for Updates (see below).

## Settings

The chosen mic is stored in the app's standard macOS preferences:

```bash
defaults read audio.dialup.rew-spl-meter inputDevice
defaults delete audio.dialup.rew-spl-meter          # reset
```

On first launch, the app adopts whichever input REW is already using.

## Permissions

To minimize REW's windows, the app needs **Accessibility** access: System Settings → Privacy & Security → Accessibility. macOS will prompt on first launch. Without it, everything else works; REW just stays on screen.

## Install

Download the latest zip from [Releases](https://github.com/dialup-audio/rew-spl-meter/releases), unzip, and drag the app to Applications. To start it at login, add it under System Settings → General → Login Items.

## Build from source

Needs Xcode command line tools, CMake and Ninja.

```bash
make        # builds into build/
make run
```

## Updates

The app never touches the internet on its own. **Check for Updates…** asks GitHub whether a newer release exists and, if so, offers to open the release page. Nothing is downloaded or installed automatically. That click is the only request the app ever makes outside your machine (REW is talked to over localhost).
