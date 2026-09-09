#!/bin/bash
# Check that input comparisons use an explicit, complete reference directory.
set -euo pipefail
SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_reference_test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
WORK="$TMP/repo"
mkdir -p "$WORK/tools" "$WORK/config" "$WORK/runs" "$TMP/bin" "$TMP/reference"
cp "$SCRIPTDIR/tools/"{regenerate_datasets,source_id,slurm_jobs}.sh "$WORK/tools/"
cp "$SCRIPTDIR/config/cluster.sh" "$WORK/config/"
printf 'datasetA\ndatasetB\n' > "$WORK/runs/dataset_ids.txt"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/module"
printf '#!/bin/bash\nprintf "%%s\\n" "$*"\nexit "${MATLAB_STATUS:-0}"\n' > "$TMP/bin/matlab"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
# An environment module system reaches these tests two ways. It exports
# `module` as a shell function, and BASH_ENV makes every non-interactive
# shell re-define it. A function takes precedence over the stub on PATH.
# Close both so the stubbed command is used on a cluster login node too.
unset -f module 2>/dev/null || true
unset BASH_ENV
unset STORED_ROOT
run_check() { bash "$WORK/tools/regenerate_datasets.sh" check-inputs; }
if out=$(run_check 2>&1); then echo "FAIL: missing STORED_ROOT accepted"; exit 1; fi
echo "$out" | grep -q 'set STORED_ROOT'
export STORED_ROOT="$TMP/reference"
mkdir -p "$STORED_ROOT/datasetA"
touch "$STORED_ROOT/datasetA/generators_datasetA.txt"
if out=$(run_check 2>&1); then echo "FAIL: partial reference accepted"; exit 1; fi
echo "$out" | grep -q '1/2 datasets'
mkdir -p "$STORED_ROOT/datasetB"
touch "$STORED_ROOT/datasetB/generators_datasetB.txt"
out=$(run_check)
echo "$out" | grep -Fq "$STORED_ROOT"
grep -Fxq "reference=$STORED_ROOT" "$WORK/.checks/check-inputs.PASS"
rm "$WORK/.checks/check-inputs.PASS"
if MATLAB_STATUS=1 run_check; then echo "FAIL: MATLAB failure accepted"; exit 1; fi
[ ! -f "$WORK/.checks/check-inputs.PASS" ]
echo "PASS: reference directory, coverage, saved record and comparison failure"
