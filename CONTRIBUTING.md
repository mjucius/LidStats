# Contributing to LidStats

Bug reports and focused pull requests are welcome. For a larger change, open an issue first so we can discuss the behavior and the tradeoffs. Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Build locally

Use an Apple Silicon Mac with macOS 13 or later and Xcode or the Command Line Tools. Run `./build.sh` to build `LidStats.app`. For work on menu bar readings or Settings, you can launch the app without installing the helper. See the [README](README.md) for helper setup and removal.

## Code layout

- `Sources/App.swift` handles the menu, helper requests, login items, and history window.
- `Sources/MenuStats.swift` and `Sources/MenuStatsSettings.swift` handle readings, drawing, and display preferences.
- `Sources/Wire.swift` defines the local socket protocol.
- `Sources/Daemon.swift` handles helper startup and client authentication.
- `Sources/Power.swift` manages keep-awake sessions and the recovery journal. `Sources/MacPower.swift` wraps macOS power settings. `Sources/PowerSafety.swift` contains the watchdog and retry policies.
- `Sources/ChipPower.swift` samples and parses Apple Silicon power estimates.
- `build.sh` builds and signs the bundle. `setup-helper.sh` installs, upgrades, and removes the helper.

## Verify changes

From the project directory, run:

```sh
/bin/zsh -n build.sh
/bin/zsh -n setup-helper.sh
./build.sh
codesign --verify --deep --strict LidStats.app
```

For power or helper changes, say which cases you tested on a physical MacBook. Depending on the change, cover starting and stopping a session, closing and reopening the lid, switching between battery and AC, and restoring settings after the helper restarts. For installer changes, cover fresh install, upgrade, and uninstall. If a case was only simulated, say so in the pull request.

For bug reports, include the macOS version, Mac model, whether the Mac was on battery or AC, and what you expected to happen. You can inspect recent helper logs with:

```sh
log show --last 15m --style compact --predicate 'subsystem == "com.lidshift.power"'
```

Share only relevant, redacted log excerpts. Leave generated builds, signing credentials, and local data out of commits. Contributions are licensed under the [MIT License](LICENSE).

## Developer ID builds

For a direct-distribution build, set `LIDSTATS_SIGN_IDENTITY` to your **Developer ID Application** identity before running `./build.sh`. The build signs the helper and app with Hardened Runtime and secure timestamps. Use `./setup-helper.sh install --team-id TEAMID` or `upgrade --team-id TEAMID` with the expected developer team ID. This mode checks the publisher at installation and verifies the signed app when it connects to the helper.

See [Building the macOS installer](Packaging/README.md) for local packaging and the GitHub Actions signing, notarization, and release workflow. Read the [closed-lid safety warning](README.md#closed-lid-safety) before testing on hardware.
