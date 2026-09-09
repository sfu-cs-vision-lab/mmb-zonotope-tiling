#!/bin/bash
# Test copying supplied inputs without replacing results or existing directories.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_copy_inputs.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
WORK="$TMP/source tree"
SOURCE="$TMP/supplied data"
mkdir -p "$WORK/tools" "$WORK/runs" "$SOURCE/datasetA/results" "$SOURCE/datasetB" "$TMP/elsewhere"
cp "$SCRIPTDIR/tools/copy_generators.sh" "$WORK/tools/"
printf 'datasetA\ndatasetB\n' > "$WORK/runs/dataset_ids.txt"
printf '%% payload_sha256=example\n40\n1 2 3\n' > "$SOURCE/datasetA/generators_datasetA.txt"
printf '%% payload_sha256=example\n40\n4 5 6\n' > "$SOURCE/datasetB/generators_datasetB.txt"
printf 'archived result\n' > "$SOURCE/datasetA/results/vertices.csv"
cp "$SOURCE/datasetA/generators_datasetA.txt" "$TMP/inputA"
cp "$SOURCE/datasetB/generators_datasetB.txt" "$TMP/inputB"

pass=0
ok() { pass=$((pass + 1)); echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }
copy_inputs() { bash "$WORK/tools/copy_generators.sh" "$SOURCE" "$@"; }
must_refuse() {
    if copy_inputs "$1" > "$TMP/error" 2>&1; then
        fail "$2"
    fi
    ok "$2"
}

# The command finds its dataset list from any working directory.
output=$(cd "$TMP/elsewhere" && copy_inputs "new parent/output")
TARGET="$TMP/elsewhere/new parent/output"
cmp "$TMP/inputA" "$TARGET/datasetA/generators_datasetA.txt"
cmp "$TMP/inputB" "$TARGET/datasetB/generators_datasetB.txt"
echo "$output" | grep -q 'Copied 2 generator files'
ok "copies both inputs exactly with spaces in paths and a relative destination"
[ ! -e "$TARGET/datasetA/results" ] || fail "copied archived results"
ok "does not copy archived results"
cmp "$TMP/inputA" "$SOURCE/datasetA/generators_datasetA.txt"
cmp "$TMP/inputB" "$SOURCE/datasetB/generators_datasetB.txt"
ok "source files are unchanged"

printf 'keep\n' > "$TARGET/keep.txt"
must_refuse "$TARGET" "refuses an existing output directory"
grep -qx keep "$TARGET/keep.txt"
cmp "$TMP/inputA" "$TARGET/datasetA/generators_datasetA.txt"
ok "existing outputs remain unchanged"
mkdir "$TMP/empty"
must_refuse "$TMP/empty" "refuses an existing empty directory"
touch "$TMP/file"
must_refuse "$TMP/file" "refuses an existing file"
ln -s "$TARGET" "$TMP/link"
must_refuse "$TMP/link" "refuses a symlink to existing output"
ln -s "$TMP/absent" "$TMP/dangling"
must_refuse "$TMP/dangling" "refuses a dangling output symlink"

rm "$SOURCE/datasetB/generators_datasetB.txt"
must_refuse "$TMP/missing parent/output" "refuses a missing input"
[ ! -e "$TMP/missing parent" ] || fail "created output before finding missing input"
ok "checks the complete input set before creating output directories"
cp "$TMP/inputB" "$SOURCE/datasetB/generators_datasetB.txt"
printf '40\n4 5 6\n' > "$SOURCE/datasetB/generators_datasetB.txt"
must_refuse "$TMP/no hash" "refuses input without a payload hash"
[ ! -e "$TMP/no hash" ] || fail "created output for an input with no hash"
cp "$TMP/inputB" "$SOURCE/datasetB/generators_datasetB.txt"

printf 'datasetA\ndatasetA\n' > "$WORK/runs/dataset_ids.txt"
must_refuse "$TMP/repeated" "refuses repeated dataset IDs before copying"
[ ! -e "$TMP/repeated" ] || fail "created output for repeated IDs"
printf '../datasetA\n' > "$WORK/runs/dataset_ids.txt"
must_refuse "$TMP/invalid" "refuses paths in the dataset list"
printf '\n' > "$WORK/runs/dataset_ids.txt"
must_refuse "$TMP/no datasets" "refuses an empty dataset list"
printf ' datasetA\r\n\ndatasetB' > "$WORK/runs/dataset_ids.txt"
copy_inputs "$TMP/line endings" > /dev/null
cmp "$TMP/inputB" "$TMP/line endings/datasetB/generators_datasetB.txt"
ok "accepts whitespace, CRLF and a final line without a newline"
if bash "$WORK/tools/copy_generators.sh" > "$TMP/error" 2>&1; then
    fail "accepted missing arguments"
fi
ok "reports missing arguments"
bash "$WORK/tools/copy_generators.sh" --help | grep -q '^Usage:'
ok "provides command help"

echo "copy generators: $pass passed, 0 failed"
