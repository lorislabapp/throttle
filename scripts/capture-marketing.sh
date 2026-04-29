#!/usr/bin/env bash
# Marketing screenshot helper.
# Usage:
#   bash scripts/capture-marketing.sh dropdown      # menu bar popover
#   bash scripts/capture-marketing.sh stats         # Stats view
#   bash scripts/capture-marketing.sh settings      # Settings → Throttle Pro section
#   bash scripts/capture-marketing.sh full          # whole desktop
#
# Each shot has a 6-second countdown — open the relevant view in Throttle
# during the countdown, then keep your hands off until "captured" prints.

set -euo pipefail

OUT_DIR="${OUT_DIR:-$HOME/GitHub/Throttle/audit-output/screenshots}"
mkdir -p "$OUT_DIR"

DELAY="${DELAY:-6}"

shot() {
    local name="$1"
    local target="$OUT_DIR/${name}-$(date +%Y%m%d_%H%M%S).png"
    echo "→ Capturing '$name' in $DELAY seconds. Open the right view now."
    for ((i=DELAY; i>0; i--)); do printf "  %d… " "$i"; sleep 1; done
    echo
    # -x silent, -o no shadow, -T 0 (we did our own countdown)
    screencapture -x -o -T 0 "$target"
    echo "→ captured: $target"
}

case "${1:-dropdown}" in
    dropdown)  echo "Click the Throttle menu bar pill to open the meter."; shot "01-dropdown-meter" ;;
    stats)     echo "Click the Throttle pill → Stats…"; shot "02-stats" ;;
    settings)  echo "Click pill → Settings… → General. Scroll to Throttle Pro section."; shot "03-settings-pro" ;;
    trial)     echo "Open the dropdown showing the trial banner + 'tokens saved' hero card."; shot "04-trial-and-hero" ;;
    full)      shot "00-full-desktop" ;;
    *)         echo "Unknown shot: $1. Use: dropdown | stats | settings | trial | full"; exit 1 ;;
esac
