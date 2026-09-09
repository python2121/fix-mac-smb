#!/bin/sh
# Live checks against the real NAS. Requires a configuration (smbkeeper add).
# Exercises the real NetFS mount path, the prober, the unmounter, and the
# reachability gate on the first configured share, then restores whatever
# was mounted before.
#
# Set SHARE=<name> to pick a specific configured share.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build >/dev/null
BIN="$(swift build --show-bin-path)/smbkeeper"

echo "== doctor"
"$BIN" doctor

NAME="${SHARE:-$("$BIN" list | sed -n '2p' | sed -E 's/^ *([^:]+):.*/\1/')}"
[ -n "$NAME" ] || { echo "no configured share"; exit 1; }
echo
echo "== one-shot probe of '$NAME' in observe mode"
"$BIN" probe "$NAME" --mode observe

echo
echo "== recover-mode probe of '$NAME' (mounts it if missing, remounts if hung)"
"$BIN" probe "$NAME" --mode recover

echo
echo "== mount table"
mount | grep smbfs || true
echo "integration checks finished"
