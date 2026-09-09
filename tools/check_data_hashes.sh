#!/bin/bash
# tools/check_data_hashes.sh  Verify CIE input files match the pinned hashes.
#
# The collection is only reproducible if the CIE inputs are byte-identical to
# the ones the pipeline was validated with. This checks data/*.csv and
# data/*.json against data/CIE_HASHES.sha256 and fails on any change.
#
# Usage: bash tools/check_data_hashes.sh        (from the repo root)
# Exit:  0 = all inputs match, 1 = mismatch/missing file (details on stderr)
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")/.." && pwd)
HASHFILE=$SCRIPTDIR/data/CIE_HASHES.sha256

if [ ! -f "$HASHFILE" ]; then
    echo "ERROR: pinned hash file not found: $HASHFILE" >&2
    exit 1
fi

# shasum on macOS, sha256sum on Linux clusters
if command -v sha256sum >/dev/null 2>&1; then
    HASHER="sha256sum"
else
    HASHER="shasum -a 256"
fi

fail=0
while read -r want fname; do
    [ -n "$fname" ] || continue
    path=$SCRIPTDIR/data/$fname
    if [ ! -f "$path" ]; then
        echo "MISSING: data/$fname" >&2
        fail=1
        continue
    fi
    got=$($HASHER "$path" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
        echo "HASH MISMATCH: data/$fname" >&2
        echo "  pinned: $want" >&2
        echo "  actual: $got" >&2
        fail=1
    fi
done < "$HASHFILE"

# Also fail if a data file exists that is not pinned (a change by addition)
for f in "$SCRIPTDIR"/data/*.csv "$SCRIPTDIR"/data/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    if ! grep -q "  ${base}$" "$HASHFILE"; then
        echo "UNPINNED DATA FILE: data/$base (add to CIE_HASHES.sha256 deliberately)" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "CIE input verification FAILED" >&2
    exit 1
fi
echo "CIE inputs verified: all files match pinned hashes."
