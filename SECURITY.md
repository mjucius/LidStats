# Security and privacy

## Report a security issue

On GitHub, use **Security → Report a vulnerability** if private reporting is enabled. If that option is unavailable, ask the maintainer for a private contact channel before sharing details. Use public issues for ordinary bugs.

Include the LidStats version or commit, macOS version, whether the helper was installed in local-development or Developer ID mode, and the impact you observed. Share only the logs needed to explain the issue and remove credentials, usernames, or private paths where possible.

## What the helper can do

The optional power helper runs as root so it can change system sleep and energy settings with `pmset` and read chip power through `powermetrics`. The app communicates with the helper over a local Unix socket. The helper restricts connections to its original installing account. An upgrade preserves that account. In Developer ID mode it also checks the connecting app’s signing identity. Local-development mode relies on the account check, so another process under the same account can request helper actions.

The helper can keep the Mac awake after the app quits. Use **End Session** first if you want the Mac to return to normal sleep, and confirm that the helper has completed recovery before removing it.

## Closed-lid heat risk

Keeping a laptop awake with the lid closed can make it easier to overheat. LidStats attempts to enable Low Power Mode and ends the keep-awake session on macOS’s critical thermal signal. The safeguards cannot guarantee sleep, shutdown, cooling, or protection from damage. Follow the [closed-lid safety warning](README.md#closed-lid-safety) and use the feature at your own risk.

## Local data

LidStats samples system statistics locally and has no telemetry or remote service. It stores menu bar preferences in macOS user preferences. The helper stores the battery cutoff, recent lid activity, and records needed to restore power settings under `/var/db/com.lidshift.power`. Activity history can include lid timestamps, battery percentages, and interruption reasons. The helper also writes to the macOS system log.

Uninstall retains helper data for a future install. Use `./setup-helper.sh uninstall --purge-data` to remove it after power settings are restored. See the [README](README.md) for the full uninstall procedure.
