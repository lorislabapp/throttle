#!/usr/bin/env bash
# Keep local and release validation on the same SwiftLint rules as CI.
set -euo pipefail
cd "$(dirname "$0")/.."

throttle_swiftlint_bin="${THROTTLE_SWIFTLINT_BIN:-swiftlint}"
throttle_swiftlint_version="$("$throttle_swiftlint_bin" version)"
if [[ "$throttle_swiftlint_version" != "0.63.2" ]]; then
    echo "SwiftLint $throttle_swiftlint_version cannot validate the pinned 0.63.2 gate." >&2
    echo "Set THROTTLE_SWIFTLINT_BIN to the verified SwiftLint 0.63.2 executable." >&2
    exit 78
fi

"$throttle_swiftlint_bin" lint --config .swiftlint.yml --strict --no-cache --quiet --reporter json
