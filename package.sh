#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

app="$PWD/LidStats.app"
info="$app/Contents/Info.plist"
team_id="${LIDSTATS_TEAM_ID:-}"
installer_identity="${LIDSTATS_INSTALLER_IDENTITY:-}"
if [[ "${1:-}" == --local-development && $# == 1 ]]; then
    [[ -z "$team_id" && -z "$installer_identity" ]] || { print -u2 'Unset release signing variables for a local package.'; exit 2; }
    output="$PWD/dist/LidStats-local.pkg"
elif [[ $# == 0 && "$team_id" =~ '^[A-Z0-9]{10}$' && "$installer_identity" == 'Developer ID Installer: '* ]]; then
    output="$PWD/dist/LidStats.pkg"
else
    print -u2 'Set LIDSTATS_TEAM_ID and LIDSTATS_INSTALLER_IDENTITY, or pass --local-development for an unsigned test package.'
    exit 2
fi

[[ -f "$info" ]] || { print -u2 'Build LidStats.app first with ./build.sh.'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$info")
[[ "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { print -u2 'The app bundle has an invalid version.'; exit 1; }
if [[ -n "$team_id" ]]; then
    requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team_id\""
    /usr/bin/codesign --verify --strict -R "=identifier \"com.lidshift.app\" and $requirement" "$app"
    /usr/bin/codesign --verify --strict -R "=identifier \"com.lidshift.power\" and $requirement" "$app/Contents/Resources/lidshift-power"
fi

mkdir -p .build dist
stage=$(/usr/bin/mktemp -d "$PWD/.build/package.XXXXXXXX")
trap '/bin/rm -rf -- "$stage"' EXIT
mkdir -p "$stage/payload" "$stage/scripts"
/usr/bin/ditto "$app" "$stage/payload/LidStats.app"
/usr/bin/install -m 0755 Packaging/preinstall Packaging/postinstall "$app/Contents/Resources/setup-helper.sh" "$stage/scripts"
print -r -- "$team_id" > "$stage/scripts/team-id"
/usr/bin/shasum -a 256 < "$app/Contents/Resources/lidshift-power" | /usr/bin/cut -d ' ' -f 1 > "$stage/scripts/helper-sha256"

/usr/bin/pkgbuild --root "$stage/payload" --component-plist Packaging/components.plist \
    --scripts "$stage/scripts" --install-location /Applications --ownership recommended \
    --identifier com.lidshift.installer --version "$version" "$stage/component.pkg"
cat > "$stage/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>LidStats</title>
    <welcome file="Welcome.html"/>
    <options customize="never" require-scripts="true" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="lidstats"/></choices-outline>
    <choice id="lidstats" visible="false"><pkg-ref id="com.lidshift.installer"/></choice>
    <pkg-ref id="com.lidshift.installer" version="$version">component.pkg</pkg-ref>
</installer-gui-script>
XML
sign_options=()
if [[ -n "$installer_identity" ]]; then sign_options=(--sign "$installer_identity" --timestamp); fi
/usr/bin/productbuild --distribution "$stage/Distribution.xml" --package-path "$stage" \
    --resources Packaging/resources "${sign_options[@]}" "$stage/LidStats.pkg"
if [[ -n "$installer_identity" ]]; then
    /usr/sbin/pkgutil --check-signature "$stage/LidStats.pkg"
fi
/bin/mv -f -- "$stage/LidStats.pkg" "$output"
print "Built $output"
