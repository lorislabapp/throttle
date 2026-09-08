#!/bin/sh
set -eu

usage() {
    echo "usage: $0 [--require-signed] /path/to/Throttle.app" >&2
    exit 64
}

require_signed=0
if [ "${1:-}" = "--require-signed" ]; then
    require_signed=1
    shift
fi
[ "$#" -eq 1 ] || usage

app="$1"
main_binary="$app/Contents/MacOS/Throttle"
launch_agent_plist="$app/Contents/Library/LaunchAgents/com.lorislab.throttle.research-vault-agent.plist"
agent_app="$app/Contents/Library/LoginItems/ResearchVaultAgent.app"
agent_binary="$agent_app/Contents/MacOS/ResearchVaultAgent"
sqlcipher_binary="$agent_app/Contents/Frameworks/SQLCipher.framework/Versions/A/SQLCipher"
sparkle_root="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sparkle_updater="$sparkle_root/Updater.app"
sparkle_autoupdate="$sparkle_root/Autoupdate"
sparkle_downloader="$sparkle_root/XPCServices/Downloader.xpc"
sparkle_installer="$sparkle_root/XPCServices/Installer.xpc"

for required_path in \
    "$main_binary" \
    "$launch_agent_plist" \
    "$agent_binary" \
    "$sqlcipher_binary" \
    "$sparkle_updater" \
    "$sparkle_autoupdate" \
    "$sparkle_downloader" \
    "$sparkle_installer"
do
    if [ ! -e "$required_path" ]; then
        echo "missing required bundle artifact: $required_path" >&2
        exit 1
    fi
done

plutil -lint "$launch_agent_plist" > /dev/null

label="$(plutil -extract Label raw "$launch_agent_plist")"
bundle_program="$(plutil -extract BundleProgram raw "$launch_agent_plist")"
[ "$label" = "com.lorislab.throttle.research-vault-agent" ] || {
    echo "unexpected LaunchAgent label: $label" >&2
    exit 1
}
[ "$bundle_program" = "Contents/Library/LoginItems/ResearchVaultAgent.app/Contents/MacOS/ResearchVaultAgent" ] || {
    echo "unexpected BundleProgram: $bundle_program" >&2
    exit 1
}
for service_name in \
    com.lorislab.throttle.research-vault.query.cheatcode \
    com.lorislab.throttle.research-vault.query.throttle \
    com.lorislab.throttle.research-vault.owner.throttle
do
    mach_service="$(/usr/libexec/PlistBuddy -c "Print :MachServices:$service_name" "$launch_agent_plist")"
    [ "$mach_service" = "true" ] || {
        echo "Research Vault Mach service is not enabled: $service_name" >&2
        exit 1
    }
done
[ -x "$app/$bundle_program" ] || {
    echo "BundleProgram does not resolve to an executable" >&2
    exit 1
}

main_links="$(otool -L "$main_binary")"
agent_links="$(otool -L "$agent_binary")"

if printf '%s\n' "$main_links" | grep -q 'SQLCipher.framework'; then
    echo "Throttle unexpectedly links SQLCipher in its own process" >&2
    exit 1
fi
printf '%s\n' "$agent_links" | grep -q '@rpath/SQLCipher.framework/' || {
    echo "ResearchVaultAgent does not link the bundled SQLCipher framework" >&2
    exit 1
}
if printf '%s\n' "$agent_links" | grep -q '/usr/lib/libsqlite3'; then
    echo "ResearchVaultAgent unexpectedly links system libsqlite3" >&2
    exit 1
fi

if [ "$require_signed" -eq 1 ]; then
    codesign --verify --deep --strict --verbose=2 "$app"

    read_codesign() {
        # Never parse partial output from a failed signature observation. In a
        # pipeline, sed/grep previously hid codesign's failure status.
        if signing_details=$(codesign "$@" 2>&1); then
            printf '%s\n' "$signing_details"
        else
            echo "codesign inspection failed; bundle signature qualification refused" >&2
            return 1
        fi
    }

    main_details="$(read_codesign -dvv "$app")"
    agent_details="$(read_codesign -dvv "$agent_app")"
    main_identifier="$(printf '%s\n' "$main_details" | sed -n 's/^Identifier=//p')"
    agent_identifier="$(printf '%s\n' "$agent_details" | sed -n 's/^Identifier=//p')"
    main_team="$(printf '%s\n' "$main_details" | sed -n 's/^TeamIdentifier=//p')"
    agent_team="$(printf '%s\n' "$agent_details" | sed -n 's/^TeamIdentifier=//p')"

    [ "$main_identifier" = "com.lorislab.throttle" ] || {
        echo "unexpected Throttle signing identifier: $main_identifier" >&2
        exit 1
    }
    [ "$agent_identifier" = "com.lorislab.throttle.research-vault-agent" ] || {
        echo "unexpected agent signing identifier: $agent_identifier" >&2
        exit 1
    }
    [ "$main_team" = "TDV6D5L785" ] || {
        echo "unexpected Throttle Team ID: $main_team" >&2
        exit 1
    }
    [ "$agent_team" = "TDV6D5L785" ] || {
        echo "unexpected agent Team ID: $agent_team" >&2
        exit 1
    }

    agent_entitlements="$(read_codesign -d --entitlements - "$agent_app")"
    case "$agent_entitlements" in
        *'com.apple.security.get-task-allow'*)
            echo "ResearchVaultAgent requests forbidden get-task-allow entitlement" >&2
            exit 1 ;;
    esac

    for distribution_code in \
        "$sparkle_updater" \
        "$sparkle_autoupdate" \
        "$sparkle_downloader" \
        "$sparkle_installer"
    do
        distribution_details="$(read_codesign -dvvv "$distribution_code")"
        distribution_team="$(printf '%s\n' "$distribution_details" | sed -n 's/^TeamIdentifier=//p')"
        [ "$distribution_team" = "TDV6D5L785" ] || {
            echo "unexpected nested Team ID for $distribution_code: ${distribution_team:-missing}" >&2
            exit 1
        }
        printf '%s\n' "$distribution_details" | grep -q '^Timestamp=' || {
            echo "missing secure timestamp for $distribution_code" >&2
            exit 1
        }
    done
fi

echo "{\"status\":\"pass\",\"scenario\":\"research-vault-bundle\",\"signed\":$require_signed}"
