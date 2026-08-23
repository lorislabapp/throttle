#!/usr/bin/env bash
#
# throttle-sync — keep one repo consistent across the Mac and the remote box
# without a shared filesystem, and without ever losing uncommitted work.
#
# WHY NOT A SHARED FILESYSTEM
# Three independent findings, all measured or cited on 2026-08-22:
#   • Claude Code's own CHANGELOG documents truncated / zero-length files when
#     agents write into network drives or cloud-synced directories.
#   • Syncthing's maintainers and community say plainly not to sync a git
#     working tree; concurrent git on both ends corrupts `.git`.
#   • Conductor Cloud, a commercial product solving exactly this, makes its
#     local↔remote sync STRICTLY one-way (cloud → laptop) and overwrites local
#     edits rather than attempt a merge.
# Mutagen is the right design but its last release is v0.18.1 (Feb 2025), so it
# is not a dependency to put on a critical path. Git is.
#
# THE GUARANTEE
# Uncommitted work is what actually gets lost when you switch machines. This
# script snapshots the *entire* working tree — tracked, staged, and untracked,
# minus what .gitignore excludes — into a real commit object, and pushes it to
#
#     refs/wip/<machine>/<branch>
#
# The namespace is per-machine, so two machines can never overwrite each other:
# whatever order you work in, both snapshots survive and are inspectable. The
# script NEVER merges, rebases, checks out, or stashes on your behalf; it moves
# work where you can see it and leaves every decision to you.
#
# The snapshot uses a throwaway index (GIT_INDEX_FILE), so your real index,
# your staged changes, and your stash list are untouched. `git stash create -u`
# was measured on 2026-08-21 NOT to include untracked files, which is why this
# builds the tree by hand instead.
#
# USAGE
#   throttle-sync.sh push [repo]     snapshot + push branch and WIP ref
#   throttle-sync.sh fetch [repo]    fetch everything, show what the other side has
#   throttle-sync.sh status [repo]   what exists where, no network writes
#   throttle-sync.sh diff <machine> [repo]   your tree vs that machine's snapshot
#   throttle-sync.sh merge <machine> [repo]  reconcile the other machine's snapshot
#                                            into yours, in a scratch worktree
#
# CONFIG (env)
#   THROTTLE_SYNC_HOST    ssh destination holding the bare mirrors
#   THROTTLE_SYNC_ROOT    directory of the bare mirrors on that host
#   THROTTLE_SYNC_KEY     ssh identity file (optional)
#   THROTTLE_SYNC_MACHINE stable label for this machine (default: hostname)
#   THROTTLE_SYNC_HOST_ALT second address to try when the first does not answer
set -euo pipefail

SYNC_HOST="${THROTTLE_SYNC_HOST-git@100.123.83.107}"   # no colon: an explicitly empty value means "local path"
SYNC_ROOT="${THROTTLE_SYNC_ROOT:-/datapool/git/repos}"
SYNC_KEY="${THROTTLE_SYNC_KEY:-$HOME/.ssh/proxmox_nopass}"
# Fallback path. Measured 2026-08-22: with the Proxmox host at load average 16
# (transcoding + a runaway sensor), tailscaled starves and the tailnet address
# stops answering ICMP and SSH entirely while the LAN address stays healthy —
# a large push then dies mid-transfer. Losing work because the box was busy is
# exactly what this tool exists to prevent, so it tries the second address
# rather than failing.
SYNC_HOST_ALT="${THROTTLE_SYNC_HOST_ALT-git@10.9.8.88}"

die() { printf 'throttle-sync: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

# Short, stable machine label. `hostname -s` is the Mac spelling; plain
# `hostname` is the Linux one. Lowercased and stripped of anything that would
# be illegal inside a ref name.
machine_id() {
    local h
    # An explicit label wins: the hostname can change, and the ref namespace
    # must not move under work that is already stored there.
    h="${THROTTLE_SYNC_MACHINE:-$(hostname -s 2>/dev/null || hostname)}"
    printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//'
}

# The mirror's basename. Deriving it from the directory name looks obvious and
# is a trap: `iconv -t ASCII//TRANSLIT` on "Éclair" yields "'Eclair" on macOS and
# "?clair" on Linux, so the two machines would address two different mirrors and
# each would think the other had pushed nothing. The name is therefore read from
# git config `throttle-sync.mirror`, which lives in the repo and reads the same
# everywhere. A non-ASCII directory name without that key is refused, not guessed.
mirror_name() {
    local repo="$1" name
    name=$(git -C "$repo" config --get throttle-sync.mirror 2>/dev/null) && [ -n "$name" ] && {
        printf '%s' "$name"; return 0; }
    name=$(basename "$repo")
    case "$name" in
        *[!A-Za-z0-9._-]*)
            die "repo directory '$name' is not plain ASCII — pick the mirror name explicitly:
    git -C '$repo' config throttle-sync.mirror <name>" ;;
    esac
    printf '%s' "$name"
}

repo_root() {
    local start="${1:-$PWD}"
    git -C "$start" rev-parse --show-toplevel 2>/dev/null \
        || die "not a git repository: $start"
}

current_branch() {
    # Detached HEAD has no branch; name the ref after the commit so the
    # snapshot is still addressable instead of silently skipped.
    git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null \
        || printf 'detached-%s' "$(git -C "$1" rev-parse --short HEAD)"
}

# An empty THROTTLE_SYNC_HOST means the mirrors are on a local path — used by
# the test harness, and valid for an attached disk.
url_for() {
    local host="$1" name="$2"
    if [ -z "$host" ]; then printf '%s/%s.git' "$SYNC_ROOT" "$name"
    else printf 'ssh://%s%s/%s.git' "$host" "$SYNC_ROOT" "$name"; fi
}

# Pick the first address whose mirror actually answers, and say which one when
# it is not the primary — a silent fallback hides a degraded box.
remote_url() {
    local name="$1" repo="${2:-$PWD}" url
    url=$(url_for "$SYNC_HOST" "$name")
    GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" ls-remote "$url" >/dev/null 2>&1 && { printf '%s' "$url"; return 0; }
    if [ -n "$SYNC_HOST_ALT" ] && [ "$SYNC_HOST_ALT" != "$SYNC_HOST" ]; then
        url=$(url_for "$SYNC_HOST_ALT" "$name")
        if GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" ls-remote "$url" >/dev/null 2>&1; then
            note "primary host unreachable — using $SYNC_HOST_ALT" >&2   # stdout is the URL
            printf '%s' "$url"; return 0
        fi
    fi
    return 1
}

# ServerAlive keepalives matter here: a first push of a large repo can spend
# minutes uploading one sideband packet, and without them the link is torn down
# mid-transfer ("unexpected disconnect while reading sideband packet") — measured
# on Eclair, 464 MB of history over the tailnet.
git_ssh() {
    printf 'ssh -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -i %s' "$SYNC_KEY"
}

# Build a commit containing the working tree exactly as it stands right now.
# Prints the new commit sha, or nothing when the tree matches HEAD (no work to
# preserve — saying so is more useful than pushing an empty snapshot).
snapshot_wip() {
    local repo="$1" branch="$2" idx sha tree head
    idx=$(mktemp "${TMPDIR:-/tmp}/throttle-sync-index.XXXXXX")
    trap 'rm -f "$idx"' RETURN

    head=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || die "repository has no commits yet"

    GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$head"
    # `add -A` honours .gitignore, so 105 GB of DerivedData and node_modules
    # stay where they belong: on the machine that built them.
    GIT_INDEX_FILE="$idx" git -C "$repo" add -A . 2>/dev/null || true
    tree=$(GIT_INDEX_FILE="$idx" git -C "$repo" write-tree)

    [ "$tree" = "$(git -C "$repo" rev-parse "$head^{tree}")" ] && return 0

    sha=$(git -C "$repo" commit-tree "$tree" -p "$head" \
        -m "wip($(machine_id)): $branch @ $(date -u '+%Y-%m-%dT%H:%M:%SZ')")
    printf '%s' "$sha"
}

cmd_push() {
    local repo name branch url wip me
    repo=$(repo_root "${1:-$PWD}")
    name=$(mirror_name "$repo")
    branch=$(current_branch "$repo")
    me=$(machine_id)
    echo "push  $name  [$branch]  from $me"
    url=$(remote_url "$name" "$repo") \
        || die "no mirror reachable for $name (tried $SYNC_HOST${SYNC_HOST_ALT:+ and $SYNC_HOST_ALT}) — create it with: git init --bare --initial-branch=main $SYNC_ROOT/$name.git"

    # Committed history first: it is the part both machines agree on.
    if GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" push --quiet "$url" \
        "refs/heads/$branch:refs/heads/$branch" 2>/dev/null; then
        note "branch $branch pushed"
    else
        # A rejected branch push is not a failure to report as success: the
        # remote has commits this machine has not seen.
        note "branch $branch REFUSED — the mirror has commits you don't have; run 'fetch' first"
    fi

    wip=$(snapshot_wip "$repo" "$branch")
    if [ -z "$wip" ]; then
        note "working tree is clean — nothing uncommitted to preserve"
        return 0
    fi
    GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" push --quiet --force \
        "$url" "$wip:refs/wip/$me/$branch"
    note "uncommitted work saved as refs/wip/$me/$branch ($(git -C "$repo" rev-parse --short "$wip"))"
    note "$(git -C "$repo" diff --shortstat "$(git -C "$repo" rev-parse HEAD)" "$wip" || true)"
}

cmd_fetch() {
    local repo name url me
    repo=$(repo_root "${1:-$PWD}")
    name=$(mirror_name "$repo")
    me=$(machine_id)
    echo "fetch $name  into $me"
    url=$(remote_url "$name" "$repo") || die "no mirror reachable for $name"
    # Every ref, including other machines' WIP. Nothing is merged or checked
    # out — this only makes the other side's work visible and local.
    GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" fetch --quiet --prune "$url" \
        '+refs/heads/*:refs/remotes/box/*' '+refs/wip/*:refs/wip/*'

    local found=0
    while read -r sha ref; do
        [ -z "$ref" ] && continue
        local who="${ref#refs/wip/}"
        [ "${who%%/*}" = "$me" ] && continue          # our own snapshot
        found=1
        note "$who → $(git -C "$repo" log -1 --format='%cr, %s' "$sha")"
    done < <(git -C "$repo" for-each-ref --format='%(objectname) %(refname)' refs/wip/)

    [ "$found" -eq 0 ] && note "no snapshots from other machines"
    echo
    echo "  nothing was merged. to look at another machine's work:"
    echo "    git diff HEAD refs/wip/<machine>/<branch>"
    echo "    git checkout refs/wip/<machine>/<branch> -- <path>"
    return 0
}

cmd_status() {
    local repo name url me
    repo=$(repo_root "${1:-$PWD}")
    name=$(mirror_name "$repo")
    me=$(machine_id)
    url=$(remote_url "$name" "$repo") || url=""

    echo "$name  on $me  [$(current_branch "$repo")]"
    local dirty
    dirty=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')
    note "$dirty uncommitted path(s) locally"

    if [ -n "$url" ]; then
        note "mirror reachable at $url"
        GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" ls-remote "$url" 'refs/wip/*' \
            | while read -r _ ref; do note "remote snapshot: ${ref#refs/wip/}"; done
    else
        note "mirror NOT reachable (tried $SYNC_HOST${SYNC_HOST_ALT:+ and $SYNC_HOST_ALT})"
    fi
}

cmd_diff() {
    local who="${1:?usage: diff <machine> [repo]}" repo branch
    repo=$(repo_root "${2:-$PWD}")
    branch=$(current_branch "$repo")
    git -C "$repo" diff "HEAD" "refs/wip/$who/$branch"
}


# MARK: - Reconciliation

# Bring another machine's snapshot into yours and report what needs a human.
#
# Measured on Eclair, 2026-08-22, Mac against box134: 468 files merged with no
# help at all, 53 files conflicted across 96 hunks. Of those hunks only 7 were
# two agents phrasing one idea differently; 89 were genuinely different
# decisions. That ratio is why this command refuses to "just merge": resolving
# 89 real disagreements by picking a side is discarding work silently, which is
# the exact failure this tool exists to prevent.
#
# So the split is by evidence, not by hope:
#   • files only one side touched      → taken, silently
#   • hunks whose code skeleton matches → resolved, they differ only in strings
#                                          and comments
#   • everything else                   → left conflicted, listed, yours to decide
#
# Nothing happens in your working tree. The merge runs in a scratch worktree, so
# a session editing the repo right now is undisturbed and you can walk away from
# the result without cleaning anything up.
cmd_merge() {
    local who="${1:?usage: merge <machine> [repo]}" repo branch me url ref work
    repo=$(repo_root "${2:-$PWD}")
    branch=$(current_branch "$repo")
    me=$(machine_id)
    ref="refs/wip/$who/$branch"

    echo "merge $(mirror_name "$repo")  [$branch]  ← $who"
    url=$(remote_url "$(mirror_name "$repo")" "$repo") || die "no mirror reachable"
    GIT_SSH_COMMAND=$(git_ssh) git -C "$repo" fetch --quiet "$url" '+refs/wip/*:refs/wip/*'
    git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null \
        || die "no snapshot at $ref — has $who run 'push'?"

    local ours
    ours=$(snapshot_wip "$repo" "$branch")
    [ -z "$ours" ] && ours=$(git -C "$repo" rev-parse HEAD)

    work="${TMPDIR:-/tmp}/throttle-merge-$(basename "$repo")-$$"
    rm -rf "$work"
    git -C "$repo" worktree add --quiet --detach "$work" "$ours" 2>/dev/null \
        || die "could not create the scratch worktree at $work"

    local merged=0 conflicted=0
    if git -C "$work" merge --no-commit --no-ff "$ref" >/dev/null 2>&1; then
        merged=$(git -C "$work" diff --cached --name-only | wc -l | tr -d ' ')
        note "$merged file(s) merged cleanly — nothing needs you"
        note "result is in $work (not committed, your tree untouched)"
        return 0
    fi
    merged=$(git -C "$work" diff --cached --name-only | wc -l | tr -d ' ')
    conflicted=$(git -C "$work" diff --name-only --diff-filter=U | wc -l | tr -d ' ')
    note "$merged file(s) merged with no help"
    note "$conflicted file(s) still conflict — classifying the hunks"

    git -C "$work" diff --name-only --diff-filter=U > "$work/.throttle-conflicts"
    resolve_cosmetic "$work"

    echo
    echo "  scratch worktree : $work"
    echo "  decisions listed : $work/.throttle-decisions.md"
    echo "  nothing was committed, and $repo was never touched."
    echo "  when done:  git -C \"$work\" diff --cached   then push from there"
    echo "  to discard: git -C \"$repo\" worktree remove --force \"$work\""
}

# Auto-resolve only the hunks that are provably the same code, and write every
# remaining decision to a report with both sides side by side.
resolve_cosmetic() {
    local work="$1"
    python3 - "$work" <<'PYEOF'
import re, os, sys

work = sys.argv[1]
skeleton = lambda s: re.sub(r'\s+', ' ', re.sub(r'//.*', '', re.sub(r'"[^"]*"', '""', s))).strip()

cosmetic = 0
decisions = []
for path in open(os.path.join(work, '.throttle-conflicts'), encoding='utf-8'):
    path = path.strip()
    full = os.path.join(work, path)
    if not path or not os.path.exists(full):
        continue
    try:
        lines = open(full, encoding='utf-8', errors='replace').read().split('\n')
    except Exception:
        continue

    out, i, changed = [], 0, False
    while i < len(lines):
        if not lines[i].startswith('<<<<<<<'):
            out.append(lines[i]); i += 1; continue
        j = i + 1
        ours = []
        while j < len(lines) and not lines[j].startswith('======='):
            ours.append(lines[j]); j += 1
        j += 1
        theirs = []
        while j < len(lines) and not lines[j].startswith('>>>>>>>'):
            theirs.append(lines[j]); j += 1
        a = [x for x in map(skeleton, ours) if x]
        b = [x for x in map(skeleton, theirs) if x]
        if a == b:
            # Same code, different wording. Keep this machine's text: either is
            # correct, and keeping ours minimises churn in the diff you review.
            out.extend(ours); cosmetic += 1; changed = True
        else:
            out.extend(lines[i:j + 1])
            decisions.append((path, ours, theirs))
        i = j + 1

    if changed:
        open(full, 'w', encoding='utf-8').write('\n'.join(out))

report = [
    "# Réconciliation — décisions qui te reviennent", "",
    f"{cosmetic} bloc(s) résolus automatiquement : même code, formulation différente.",
    f"{len(decisions)} bloc(s) demandent une vraie décision.", "",
    "Aucun n'a été tranché à ta place : ce sont deux agents qui ont choisi",
    "différemment, et prendre un côté au hasard jetterait du travail en silence.", "",
]
for n, (path, ours, theirs) in enumerate(decisions, 1):
    report += [f"## {n}. `{path}`", "", "**ici :**", "```", *ours[:40], "```", "",
               "**là-bas :**", "```", *theirs[:40], "```", ""]
open(os.path.join(work, '.throttle-decisions.md'), 'w', encoding='utf-8').write('\n'.join(report))

print(f"  {cosmetic} hunk(s) resolved automatically (same code, different words)")
print(f"  {len(decisions)} hunk(s) need a real decision")
PYEOF
    rm -f "$work/.throttle-conflicts"
}

case "${1:-}" in
    merge)  shift; cmd_merge "$@" ;;
    push)   shift; cmd_push "$@" ;;
    fetch)  shift; cmd_fetch "$@" ;;
    status) shift; cmd_status "$@" ;;
    diff)   shift; cmd_diff "$@" ;;
    *) sed -n '/^# USAGE/,/^set -euo/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//;$d' ;;
esac
