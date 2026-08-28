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

for required_path in \
    "$main_binary" \
    "$launch_agent_plist" \
    "$agent_binary" \
    "$sqlcipher_binary"
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

    main_identifier="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Identifier=//p')"
    agent_identifier="$(codesign -dvv "$agent_app" 2>&1 | sed -n 's/^Identifier=//p')"
    main_team="$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    agent_team="$(codesign -dvv "$agent_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

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
fi

echo "{\"status\":\"pass\",\"scenario\":\"research-vault-bundle\",\"signed\":$require_signed}"
