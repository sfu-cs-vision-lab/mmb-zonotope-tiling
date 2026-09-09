#!/bin/bash
# tests/hpc/test_determinism.sh  [GPU NODE]  Run-to-run determinism
#
# Run the example twice on the same GPU and toolchain. Compare sorted
# kernel output rows because atomic writes can change their order. Require
# identical vertex sets and byte-identical hull vertices and faces.
#
# Run on a GPU node. Exit 0 = PASS.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
cd "$SCRIPTDIR"

DATASET_ID="1931_2deg_D65_A_10nm_refl50"
WORK=$(mktemp -d "$SCRIPTDIR/.determ.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

. "$SCRIPTDIR/config/cluster.sh"
module load $MMB_MODULES_GPU $MMB_MODULES_MATLAB
make -C cuda NVCC_ARCH="$MMB_GPU_ARCH" >/dev/null

matlab -batch "addpath('src'); prepareGenerators(\"1931_2deg\",\"D65\",\"A\",Spacing=10,Refl=0.5,DataDir=\"data\",OutputDir=\"$WORK\")" >/dev/null

for run in 1 2; do
    mkdir -p "$WORK/r$run"
    ./cuda/mmb_exact --data "$WORK/generators_${DATASET_ID}.txt" \
        --max-verts 200000000 --output "$WORK/r$run/mmb_${DATASET_ID}.txt" >/dev/null
    matlab -batch "addpath('src'); hullMMB(\"$WORK/r$run/mmb_${DATASET_ID}.txt\", OutputDir=\"$WORK/r$run/results\", ExpectDatasetID=\"$DATASET_ID\", Verbose=false)" >/dev/null
done

echo "kernel vertex SET (order-independent)"
for run in 1 2; do
    grep -v '^%' "$WORK/r$run/mmb_${DATASET_ID}.txt" | sort > "$WORK/set$run.txt"
done
if cmp -s "$WORK/set1.txt" "$WORK/set2.txt"; then
    echo "PASS: identical vertex sets ($(wc -l < "$WORK/set1.txt" | tr -d ' ') rows)"
else
    echo "FAIL: kernel vertex sets differ between runs" >&2
    diff "$WORK/set1.txt" "$WORK/set2.txt" | head >&2
    exit 1
fi

echo "hull outputs (byte-identical)"
fail=0
for f in vertices faces; do
    if cmp -s "$WORK/r1/results/mmb_${DATASET_ID}_${f}.csv" "$WORK/r2/results/mmb_${DATASET_ID}_${f}.csv"; then
        echo "PASS: ${f}.csv byte-identical"
    else
        echo "FAIL: ${f}.csv differs between runs" >&2
        fail=1
    fi
done
v1=$(awk '/^Hull volume:/{print $NF}' "$WORK/r1/results/mmb_${DATASET_ID}_summary.txt")
v2=$(awk '/^Hull volume:/{print $NF}' "$WORK/r2/results/mmb_${DATASET_ID}_summary.txt")
if [ "$v1" = "$v2" ]; then
    echo "PASS: volumes identical ($v1)"
else
    echo "FAIL: volumes differ: $v1 vs $v2" >&2
    fail=1
fi
if [ "$fail" -eq 0 ]; then
    echo ""
    echo "DETERMINISM TEST PASS. On this GPU and toolchain:"
    echo "  - two independent kernel runs emit the IDENTICAL vertex set"
    echo "    (compared order-independently, since line order is scheduler-assigned)"
    echo "  - hull outputs are BYTE-identical run-to-run"
    echo "  - the two runs agree on this GPU and toolchain"
    mkdir -p "$SCRIPTDIR/.checks"
    { echo "source_id=$(bash "$SCRIPTDIR/tools/source_id.sh")"; echo "date=$(date -u +%FT%TZ)"; echo "check=determinism"; } \
        > "$SCRIPTDIR/.checks/determinism.PASS"
    echo "Check result written: .checks/determinism.PASS"
fi
exit "$fail"
