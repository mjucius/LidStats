# LidStats

LidStats is a native macOS menu bar app for Apple Silicon MacBooks. It shows CPU, network, chip power, and thermal readings, and can keep a MacBook awake with the lid closed.

## Why I built it

I wanted something like MenuMeters with the stats I actually look at: CPU usage, upload and download speeds, and chip power. I also use my laptop to watch my coding agents from afar. Every so often someone would close the lid without knowing I still needed the machine running. I built LidStats to solve both problems from one spot in the menu bar.

I still prefer leaving the lid open whenever practical because a MacBook doing sustained work can heat up more easily with the lid closed.

## Closed-lid safety

**Keeping your MacBook awake with the lid closed is not advisable. Use LidStats at your own risk.** Leave the lid open when practical, keep the Mac on a hard, ventilated surface, and end the keep-awake session before putting it in a bag or any enclosed space.

LidStats attempts to switch to Low Power Mode when the lid closes and end the keep-awake session if macOS reports critical heat. Ending the session attempts to restore normal sleep. These measures **do not guarantee** that the Mac will cool down, sleep, shut down, or avoid damage. Damage caused by operation outside Apple’s published guidelines may be excluded from warranty coverage. [Apple’s Mac temperature guidance](https://support.apple.com/en-ie/102336) · [Apple’s warranty terms](https://www.apple.com/legal/warranty/)

## Install or build

When a signed release is available, download `LidStats.pkg` from the project’s GitHub Releases. End any active session and quit LidStats before running the installer. The package installs the app in Applications and sets up the helper for the signed-in account.

### Build from source

LidStats targets Apple Silicon MacBooks with macOS 13 or later. Building requires Xcode or the Command Line Tools. Keep-awake sessions require a Mac that reports its lid state and exposes an adapter energy mode.

Run these commands from the project directory:

```sh
./build.sh
open LidStats.app
```

CPU, network, and thermal readings work without the power helper. To use closed-lid keep-awake, chip power, and lid activity history, install the helper separately:

```sh
./setup-helper.sh install --local-development
```

Quit and reopen LidStats after installing the helper if you want it to offer a session on launch. The installer asks for administrator authentication. It installs a root-owned executable in `/Library/PrivilegedHelperTools` and registers a system LaunchDaemon. Local development mode permits requests from processes running as the installing account. See [Security and privacy](SECURITY.md) for what the helper can do and what it stores.

## Menu bar readings

| Stat | What it shows |
| --- | --- |
| **CPU** | Total utilization and a vertical bar. |
| **CHIP** | Estimated power used by the CPU, GPU, and Neural Engine in watts. It excludes the display, peripherals, and battery charging. |
| **↑ / ↓** | Upload and download rates across active Wi-Fi and Ethernet interfaces. |
| **HEAT** | The current macOS thermal pressure. Hover over the stats to read the full state name. |

| HEAT | macOS thermal state | What it means |
| --- | --- | --- |
| **OK** | Nominal | Thermal pressure is within normal limits. |
| **Fair** | Fair | Thermal pressure is slightly elevated. macOS may reduce background work. |
| **High** | Serious | macOS takes steps to cool the system that reduce performance. |
| **Crit** | Critical | Heat is significantly affecting performance. LidStats ends an active session when macOS reports this state. |
| **—** | Unknown | LidStats couldn’t identify the thermal state. |

Thermal pressure describes the system’s response to heat. It doesn’t measure temperature or quantify the slowdown. [Apple’s thermal state documentation](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum)

Open **Settings…** to show, hide, recolor, or reorder each stat. Adjacent network rates stack by default. Turn off **Stack upload and download** to display them side by side.

## Keep-awake sessions

- Every session requires confirmation. With **Ask to Keep Awake on Launch** enabled, LidStats offers an indefinite session when the current helper is ready, the lid is open, and the Mac is plugged in or above the battery cutoff. To start manually, choose **Keep Awake** or **Start With Timer**, then confirm **Start Session**.
- A slow rainbow gradient travels around the stats while a session is active. The moving highlight thickens the outline as it passes. The gradient stays still when macOS Reduce Motion is enabled. A dashed outline means LidStats can’t confirm the session state. If you hide all stats, a filled bolt indicates an active session. Choose **End Session** to restore normal sleep. The helper can keep a session running after you quit the menu bar app.
- After the lid closes, LidStats requests display sleep and switches the active energy profile to Low Power Mode when supported. It attempts to restore the previous profile when you reopen the lid.
- A session also ends on timer expiry, macOS reporting critical heat, or the battery reaching its cutoff while unplugged. The cutoff defaults to 10% and is adjustable from 5% to 100%. At the cutoff, LidStats restores normal sleep and asks macOS to sleep immediately if the lid is closed. On restart, the helper attempts to restore settings from the previous session.
- **Activity History…** shows up to 12 recent lid closures during sessions. It includes observed close and reopen times, available battery readings, interruptions, and display-sleep failures. Its system sleep check covers the interval between the recorded lid observations.

**Start at Login** and **Ask to Keep Awake on Launch** are separate under **Settings…**. You can launch the menu bar stats at login without a session prompt.

Before relying on a closed-lid run, try it with a short workload that writes timestamped output. Read the [closed-lid safety warning](#closed-lid-safety) first.

## Upgrade or remove the helper

End the current session and quit the app before upgrading or uninstalling. For a local build, run:

```sh
./build.sh
./setup-helper.sh upgrade --local-development
open LidStats.app
```

The upgrade preserves the recovery journal. If an upgrade is interrupted, rerun the setup command so it can recover the previous installation before retrying.

To upgrade a packaged installation, quit the app and run the newer `.pkg`. To uninstall the helper from a packaged installation, run:

```sh
/Applications/LidStats.app/Contents/Resources/setup-helper.sh uninstall
```

From a source checkout, use `./setup-helper.sh uninstall`. This keeps the saved battery cutoff and activity history for a future install. Add `--purge-data` to delete helper data after normal sleep settings have been restored. Turn off **Start at Login** in Settings if you also want to remove the app from your login items.

If LidStats offers **Restore Normal Sleep…**, use it to re-enable sleep when the helper can’t read its recovery journal. Check your energy mode afterward because the damaged journal may no longer contain the previous setting.

## Contributing and license

See [Contributing](CONTRIBUTING.md) for the code layout, verification steps, and Developer ID builds. See [Security and privacy](SECURITY.md) for reporting sensitive issues.

LidStats is available under the [MIT License](LICENSE).
