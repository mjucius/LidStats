#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd -- "${0:A:h}"

label=com.lidshift.power
plist="/Library/LaunchDaemons/$label.plist"
helper="/Library/PrivilegedHelperTools/$label"
journal="/var/db/$label"
app="$PWD/LidStats.app"
owner_uid=$(/usr/bin/id -u)
package_install=false
expected_digest=""
operation="${1:-}"
if [[ "${1:-}" == --package-install ]]; then
    if (( EUID != 0 )); then
        print -u2 'Package installation must run through macOS Installer.'
        exit 1
    fi
    package_install=true
    shift
    expected_digest="${1:-}"
    if [[ ! "$expected_digest" =~ '^[a-f0-9]{64}$' ]]; then
        print -u2 'The package must specify the expected helper digest.'
        exit 2
    fi
    shift
    app="/Applications/LidStats.app"
    owner_uid=$(/usr/bin/stat -f '%u' /dev/console)
    if (( owner_uid < 501 || owner_uid >= 4294967295 )); then
        print -u2 'Sign in to a regular macOS account before installing LidStats.'
        exit 1
    fi
    operation=install-or-upgrade
elif (( EUID == 0 )); then
    print -u2 'Run this from your regular account. The script invokes sudo for privileged steps.'
    exit 1
fi
source_helper="$app/Contents/Resources/lidshift-power"

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        /usr/bin/sudo "$@"
    fi
}

probe_helper() {
    if [[ "$package_install" == true ]]; then
        /usr/bin/sudo -H -u "#$owner_uid" -- "$app/Contents/MacOS/LidStats" "$@"
    else
        "$app/Contents/MacOS/LidStats" "$@"
    fi
}

if [[ "$package_install" != true ]]; then
    if [[ "$operation" == install-or-upgrade ]]; then exit 2; fi
    if (( $# > 0 )); then shift; fi
fi
case "$operation" in
    install|upgrade|install-or-upgrade)
        verify_options=()
        if [[ $# == 1 && "${1:-}" == --local-development ]]; then
            client_policy=local-development
            print -u2 'Installing a local development helper. Only install a build you trust.'
        elif [[ $# == 2 && "${1:-}" == --team-id && "$2" =~ '^[A-Z0-9]{10}$' ]]; then
            publisher="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$2\""
            client_policy="identifier \"com.lidshift.app\" and $publisher"
            verify_options=(-R "=identifier \"$label\" and $publisher")
            /usr/bin/codesign --verify --strict -R "=$client_policy" "$app"
        else
            print -u2 'Usage: ./setup-helper.sh (install|upgrade) (--team-id TEAMID | --local-development)'
            exit 2
        fi
        [[ -x "$source_helper" ]] || { print -u2 'Run ./build.sh first.'; exit 1; }
        /usr/bin/codesign --verify --deep --strict "$app"
        if [[ "$package_install" != true ]]; then
            expected_digest=$(/usr/bin/shasum -a 256 < "$source_helper" | /usr/bin/cut -d ' ' -f 1)
        fi
        ;;
    uninstall)
        if [[ $# != 0 && ( $# != 1 || "${1:-}" != --purge-data ) ]]; then
            print -u2 'Usage: ./setup-helper.sh uninstall [--purge-data]'
            exit 2
        fi
        ;;
    *)
        print -u2 'Usage: ./setup-helper.sh (install|upgrade) (--local-development | --team-id TEAMID) | uninstall [--purge-data]'
        exit 2
        ;;
esac

helper_is_loaded() {
    as_root /bin/launchctl print "system/$label" >/dev/null 2>&1
}

lock="/var/run/$label.installer.lock"
stage="/Library/PrivilegedHelperTools/.$label.transaction"
as_root /usr/bin/touch "$lock"
as_root /usr/sbin/chown root:admin "$lock"
as_root /bin/chmod 0640 "$lock"
exec {installer_lock}< "$lock"
if ! /usr/bin/lockf -t 0 "$installer_lock"; then
    print -u2 'Another LidStats helper operation is in progress.'
    exit 1
fi

record_phase() {
    as_root /usr/bin/tee "$stage/phase-new" >/dev/null <<< "$1" || return 1
    as_root /bin/mv -f -- "$stage/phase-new" "$stage/phase" || return 1
    /bin/sync
}

replace_file() {
    as_root /usr/bin/install -o root -g wheel -m "$1" "$2" "$stage/replacement" || return 1
    as_root /bin/mv -f -- "$stage/replacement" "$3"
}

recover_transaction() {
    if ! as_root /bin/test -d "$stage"; then return 0; fi
    local phase=staging
    if as_root /bin/test -f "$stage/phase"; then
        phase=$(as_root /bin/cat "$stage/phase") || return 1
    fi
    case "$phase" in
        fresh|rollback-running|rollback-stopped)
            if helper_is_loaded; then
                as_root /bin/launchctl bootout "system/$label" || return 1
            fi
            if [[ "$phase" == fresh ]]; then
                if [[ -f "$helper" && -f "$plist" ]] && as_root /bin/test -e "$journal/recovery.json"; then
                    as_root /bin/launchctl bootstrap system "$plist" || return 1
                    print -u2 'Kept the helper installed so it can recover power settings.'
                else
                    as_root /bin/rm -f -- "$plist" "$helper" "/var/run/$label.sock" || return 1
                fi
            else
                replace_file 0644 "$stage/previous.plist" "$plist" || return 1
                replace_file 0755 "$stage/previous-helper" "$helper" || return 1
                if [[ "$phase" == rollback-running ]]; then
                    as_root /bin/launchctl bootstrap system "$plist" || return 1
                fi
                print -u2 'The previous helper installation was restored.'
            fi
            record_phase committed || return 1
            ;;
        staging|committed) ;;
        *)
            print -u2 "Unknown helper transaction phase: $phase"
            return 1
            ;;
    esac
    as_root /bin/rm -f -- "$stage/helper" "$stage/service.plist" "$stage/previous-helper" \
        "$stage/previous.plist" "$stage/phase" "$stage/phase-new" "$stage/replacement" || return 1
    as_root /bin/rmdir -- "$stage"
}

if ! recover_transaction; then
    print -u2 "Could not finish the interrupted helper operation. Recovery files remain in $stage."
    exit 1
fi

if [[ "$operation" == install-or-upgrade ]]; then
    if [[ -e "$plist" || -e "$helper" ]]; then
        operation=upgrade
    else
        operation=install
    fi
fi

case "$operation" in
    install|upgrade)
        previous_running=false
        if helper_is_loaded; then previous_running=true; fi
        if [[ "$operation" == install && ( -e "$plist" || -e "$helper" || "$previous_running" == true ) ]]; then
            print -u2 'The power helper is already installed. Use upgrade to replace it.'
            exit 1
        fi
        if [[ "$operation" == upgrade && ( ! -f "$plist" || ! -f "$helper" ) ]]; then
            print -u2 'There is no complete helper installation to upgrade. Use install for a fresh setup.'
            exit 1
        fi

        if [[ "$operation" == upgrade ]]; then
            installed_uid=$(as_root /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist")
            if [[ ! "$installed_uid" =~ '^[0-9]{1,10}$' ]] ||
                (( installed_uid < 501 || installed_uid >= 4294967295 )) ||
                ! /usr/bin/id -nu "$installed_uid" >/dev/null; then
                print -u2 'The existing helper has no valid authorized account.'
                exit 1
            fi
            if [[ "$package_install" != true && "$owner_uid" != "$installed_uid" ]]; then
                print -u2 'Run the upgrade from the account that owns the existing helper.'
                exit 1
            fi
            owner_uid=$installed_uid
        fi

        as_root /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
        as_root /usr/bin/install -d -o root -g wheel -m 0700 "$stage"
        cleanup() {
            local result=$1
            trap - EXIT INT TERM
            if ! recover_transaction; then
                print -u2 "Could not finish the helper operation. Recovery files remain in $stage."
                return 1
            fi
            return "$result"
        }
        trap 'cleanup "$?"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        as_root /usr/bin/install -o root -g wheel -m 0755 "$source_helper" "$stage/helper"
        staged_digest=$(as_root /bin/cat "$stage/helper" | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1)
        [[ "$expected_digest" == "$staged_digest" ]] || { print -u2 'The staged helper does not match the expected digest.'; exit 1; }
        as_root /usr/bin/codesign --verify --strict "${verify_options[@]}" "$stage/helper"
        as_root /usr/bin/tee "$stage/service.plist" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$helper</string><string>$owner_uid</string><string>$client_policy</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
</dict>
</plist>
PLIST
        as_root /usr/bin/plutil -lint "$stage/service.plist"
        as_root /usr/bin/install -d -o root -g wheel -m 0700 "$journal"
        if [[ "$operation" == upgrade ]]; then
            as_root /usr/bin/install -o root -g wheel -m 0755 "$helper" "$stage/previous-helper"
            as_root /usr/bin/install -o root -g wheel -m 0644 "$plist" "$stage/previous.plist"
            if [[ "$previous_running" == true ]]; then
                record_phase rollback-running
                as_root /bin/launchctl bootout "system/$label"
            else
                record_phase rollback-stopped
            fi
        else
            record_phase fresh
        fi
        replace_file 0755 "$stage/helper" "$helper"
        replace_file 0644 "$stage/service.plist" "$plist"
        if ! as_root /bin/launchctl bootstrap system "$plist"; then
            print -u2 'macOS could not start the replacement power helper.'
            exit 1
        fi
        probe_args=(--probe-helper)
        if [[ "$operation" == upgrade ]] || as_root /bin/test -e "$journal/recovery.json"; then
            probe_args+=(--allow-recovery)
        fi
        ready=false
        for probe_attempt in {1..8}; do
            if probe_error=$(probe_helper "${probe_args[@]}" 2>&1); then
                ready=true
                break
            fi
            /bin/sleep 0.25
        done
        if [[ "$ready" != true ]]; then
            print -u2 "The installed helper did not answer a status request: $probe_error"
            exit 1
        fi
        record_phase committed
        print 'Power helper ready. Open LidStats to check its status.'
        ;;
    uninstall)
        if helper_is_loaded; then
            as_root /bin/launchctl bootout "system/$label"
        fi
        if as_root /bin/test -e "$journal/recovery.json"; then
            print -u2 'Power settings recovery is pending. Restarting the helper so it can retry.'
            as_root /bin/launchctl bootstrap system "$plist"
            exit 1
        fi
        as_root /bin/rm -f -- "$plist" "$helper" "/var/run/$label.sock"
        if [[ "${1:-}" == --purge-data ]]; then
            as_root /bin/rm -f -- "$journal/battery-cutoff" "$journal/lid-history.json" "$journal/cutoff-sleep.json"
            as_root /usr/bin/find "$journal" -maxdepth 1 -type f -name 'recovery-damaged-*.json' -delete 2>/dev/null || true
        fi
        if as_root /bin/test -d "$journal"; then
            if ! as_root /bin/rmdir "$journal" 2>/dev/null; then
                print "Local helper data remains in $journal."
            fi
        fi
        print 'Power helper uninstalled.'
        ;;
esac
