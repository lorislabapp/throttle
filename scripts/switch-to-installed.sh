#!/usr/bin/env bash
# Move off a Throttle running from a build directory and onto /Applications.
#
# Why this needs a script rather than two commands: the cockpit's terminals are
# children of Throttle, so this is almost always run from inside the very app it
# is about to kill. When Throttle dies the PTY master closes and every shell
# under it takes SIGHUP — including this one, mid-script, before the relaunch.
# The kill and the relaunch therefore run in a detached, SIGHUP-immune child.
#
# Usage: bash scripts/switch-to-installed.sh [--yes]
set -Eeuo pipefail

INSTALLED="/Applications/Throttle.app"
AUTO_YES=false
[ "${1:-}" = "--yes" ] && AUTO_YES=true

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
# Build number as a plain integer, 0 when unreadable. A build-directory bundle is
# routinely DELETED out from under its own running process by the next
# `xcodebuild` — the running app then has no Info.plist at all, and PlistBuddy
# prints prose to stdout instead of failing. Treating that as 0 is right: an app
# whose bundle no longer exists can only be older than the one on disk.
buildnum() { local n; n=$(plist "$1" CFBundleVersion | tr -dc '0-9' | head -c 9); echo "${n:-0}"; }

# --- What is actually running -------------------------------------------------
# Match on the executable path, not the process name: the whole point is telling
# two apps with the same name apart.
RUNNING_PID=$(ps -Ao pid=,comm= | awk '$2 ~ /Throttle\.app\/Contents\/MacOS\/Throttle$/ {print $1}' | head -1)
if [ -z "$RUNNING_PID" ]; then
    echo "Nothing to switch: no Throttle is running."
    echo "Just open $INSTALLED."
    exit 0
fi
RUNNING_PATH=$(ps -p "$RUNNING_PID" -o comm= | sed 's|/Contents/MacOS/Throttle$||')

if [ "$RUNNING_PATH" = "$INSTALLED" ]; then
    echo "Already running from $INSTALLED — nothing to do."
    exit 0
fi

# --- Refuse to downgrade ------------------------------------------------------
[ -d "$INSTALLED" ] || { echo "✘ $INSTALLED is missing. Install the DMG first." >&2; exit 66; }
RUNNING_BUILD=$(buildnum "$RUNNING_PATH")
INSTALLED_BUILD=$(buildnum "$INSTALLED")
if [ "$RUNNING_BUILD" -eq 0 ]; then
    echo "  note: the running app's bundle is gone from disk — switching is the only way back to a supported build."
fi
if [ "$INSTALLED_BUILD" -lt "$RUNNING_BUILD" ]; then
    echo "✘ $INSTALLED is build $INSTALLED_BUILD, older than the running build $RUNNING_BUILD." >&2
    echo "  Switching would be a downgrade. Install the newer DMG first." >&2
    exit 65
fi

echo "  running   : $RUNNING_PATH (build ${RUNNING_BUILD})"
echo "  switching to: $INSTALLED ($(plist "$INSTALLED" CFBundleShortVersionString) / $INSTALLED_BUILD)"

# --- Save the resume ids BEFORE anything dies ---------------------------------
# Every cockpit session is a `claude --resume <id>` grandchild. Losing the list
# means losing the conversations, so this is written first and unconditionally.
LEDGER="$HOME/Desktop/throttle-sessions-$(date +%Y%m%d-%H%M%S).txt"
ps -Ao pid=,ppid=,args= \
    | awk -v t="$RUNNING_PID" '
        {pid[$1]=$2; line[$1]=$0}
        END { for (p in pid) if (pid[pid[p]] == t && line[p] ~ /--resume/) print line[p] }' \
    | sed 's/^ *//' > "$LEDGER" || true
COUNT=$(wc -l < "$LEDGER" | tr -d ' ')
if [ "$COUNT" -gt 0 ]; then
    echo "  $COUNT resumable session(s) saved to $LEDGER"
    sed 's/^/    /' "$LEDGER"
else
    echo "  no resumable sessions found (nothing with --resume under this Throttle)"
    rm -f "$LEDGER"
fi

if ! $AUTO_YES; then
    # No TTY — a `claude !` shell, a hook, CI. `read` would take EOF and the
    # script would exit silently under `set -e`, looking like it had simply done
    # nothing. Say what happened and how to proceed instead.
    if [ ! -t 0 ]; then
        echo
        echo "✘ No interactive terminal, so the confirmation cannot be answered." >&2
        echo "  Nothing was killed. Re-run with --yes to proceed:" >&2
        echo "    bash $0 --yes" >&2
        exit 64
    fi
    printf "\nThis kills every cockpit session. Continue? [y/N] "
    read -r reply
    case "$reply" in [yY]*) ;; *) echo "Aborted — nothing killed."; exit 0 ;; esac
fi

# --- Hand off to a detached child --------------------------------------------
# nohup makes it immune to the SIGHUP that arrives when Throttle's PTY master
# closes; the subshell backgrounds it so this script can exit cleanly even as its
# own terminal is being torn down.
nohup bash -c "
    sleep 1
    kill $RUNNING_PID 2>/dev/null || true
    # Give it two seconds to quit on its own before insisting.
    for _ in 1 2 3 4; do kill -0 $RUNNING_PID 2>/dev/null || break; sleep 0.5; done
    kill -9 $RUNNING_PID 2>/dev/null || true
    sleep 1
    open '$INSTALLED'
" >/dev/null 2>&1 &

echo
echo "Switching in 1s. This terminal is about to close with it."
echo "Reopen your work with the commands in ${LEDGER:-the ledger above}."
