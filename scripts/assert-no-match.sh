#!/bin/sh
# Only grep exit 1 proves absence. A missing tool/file must fail the check.
# Quiet mode prevents matched credentials from being echoed into CI logs.
set -u
grep -q "$@"
status=$?
case "$status" in
    1) exit 0 ;;
    0) echo "Forbidden pattern detected" >&2; exit 1 ;;
    *) echo "Pattern check could not run (grep exit $status)" >&2; exit 2 ;;
esac
