#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

architecture="$(/usr/bin/uname -m)"
target="$architecture-apple-macosx13.0"
mkdir -p .build
stage="$(/usr/bin/mktemp -d "$PWD/.build/output.XXXXXXXX")"
trap '/bin/rm -rf -- "$stage"' EXIT

app="$stage/LidStats.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 setup-helper.sh "$app/Contents/Resources/setup-helper.sh"
if [[ -n "${LIDSTATS_VERSION:-}" ]]; then
    [[ "$LIDSTATS_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Use a version like 1.2.3.'; exit 2; }
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $LIDSTATS_VERSION" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleVersion $LIDSTATS_VERSION" "$app/Contents/Info.plist"
fi
/usr/bin/xcrun swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -target "$target" Sources/Wire.swift Sources/MenuStats.swift Sources/MenuStatsSettings.swift Sources/App.swift -o "$app/Contents/MacOS/LidStats"
/usr/bin/xcrun swiftc -O -module-cache-path "$PWD/.build/ModuleCache" -target "$target" Sources/Wire.swift Sources/MacPower.swift Sources/PowerSafety.swift Sources/Power.swift Sources/ChipPower.swift Sources/Daemon.swift -o "$app/Contents/Resources/lidshift-power"
identity="${LIDSTATS_SIGN_IDENTITY:--}"
sign_options=()
if [[ "$identity" != - ]]; then
    sign_options=(--options runtime --timestamp)
fi
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" --identifier com.lidshift.power "$app/Contents/Resources/lidshift-power"
/usr/bin/codesign --force --sign "$identity" "${sign_options[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"

if [[ -e LidStats.app ]]; then
    /bin/mv LidStats.app "$stage/previous.app"
fi
/bin/mv "$app" LidStats.app
print "Built $PWD/LidStats.app"
