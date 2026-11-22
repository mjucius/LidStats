# Building the macOS installer

The native Installer package puts LidStats in `/Applications` and installs or upgrades the privileged helper for the signed-in account. The installer requires administrator authentication and targets the current Apple Silicon startup volume. Upgrades keep the existing authorized account and restore the previous app if helper setup fails. End any session and quit LidStats before upgrading. The helper setup uses the same recovery journal and rollback logic as a source install.

## Local build

```sh
./build.sh
./package.sh --local-development
```

This creates `dist/LidStats-local.pkg` for development. It uses ad hoc application signing and an unsigned installer. Use it only for local testing. The development helper accepts requests from processes running as the installing account. See the [closed-lid safety warning](../README.md#closed-lid-safety) before testing keep-awake sessions.

## GitHub releases

The **Build installer** workflow compiles and packages LidStats on an Apple Silicon runner without signing credentials. It uploads the unsigned package as a workflow artifact for inspection. The **Release installer** workflow runs on a version tag such as `v1.2.0`. It assigns the tag version to the app and installer, signs both, notarizes and staples the installer, and attaches the installer and SHA-256 checksum to a draft GitHub release.

Create a tag ruleset for `v*` that restricts tag creation, updates, and deletion to trusted release maintainers. The release job skips unprotected tags. Create a GitHub environment named `release`, restrict it to release tags, and require a trusted reviewer if your repository plan supports it. Set these protections before adding signing secrets. Add these environment variables and secrets:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | Your Apple Developer team ID |
| Variable | `DEVELOPER_ID_APPLICATION` | The full Developer ID Application identity |
| Variable | `DEVELOPER_ID_INSTALLER` | The full Developer ID Installer identity |
| Variable | `NOTARY_KEY_ID` | The App Store Connect team API key ID |
| Variable | `NOTARY_ISSUER_ID` | The App Store Connect issuer ID |
| Secret | `APPLICATION_P12_BASE64` | Base64 of the Developer ID Application certificate and private key exported as a password-protected `.p12` |
| Secret | `APPLICATION_P12_PASSWORD` | The application export password |
| Secret | `INSTALLER_P12_BASE64` | Base64 of the Developer ID Installer certificate and private key exported as a password-protected `.p12` |
| Secret | `INSTALLER_P12_PASSWORD` | The installer export password |
| Secret | `NOTARY_KEY_BASE64` | Base64 of the App Store Connect team API private key file (`.p8`) |

With the certificates in your own Keychain, you can also build locally by setting `LIDSTATS_SIGN_IDENTITY`, `LIDSTATS_INSTALLER_IDENTITY`, and `LIDSTATS_TEAM_ID`, then running `./build.sh` and `./package.sh`. This creates `dist/LidStats.pkg`. Notarize and staple it before distributing it. [Apple’s packaging guide](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) · [GitHub’s signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

Before publishing the draft, test the downloaded package on an Apple Silicon Mac. Verify a fresh install, an upgrade, helper authentication, ending a keep-awake session, and normal sleep recovery. GitHub’s build runner cannot verify physical lid behavior.
