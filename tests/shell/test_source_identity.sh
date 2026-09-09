#!/bin/bash
# tests/shell/test_source_identity.sh
# Test the source identifier and the driver's Git check in a checkout, through
# a symlink to it, in an extracted archive and in an extraction that sits
# inside an unrelated repository.
#
# Usage: bash tests/shell/test_source_identity.sh
# Exit: 0 = all tests pass

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_srcid.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; failed=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failed=$((failed+1)); echo "  FAIL: $1"; }

# Enough of the tree for source_id.sh and the driver to run.
make_tree() {
    local d=$1
    mkdir -p "$d/tools" "$d/config" "$d/src" "$d/.checks" "$d/runs"
    cp "$SCRIPTDIR/tools/source_id.sh" "$SCRIPTDIR/tools/regenerate_datasets.sh" \
       "$SCRIPTDIR/tools/slurm_jobs.sh" "$d/tools/"
    cp "$SCRIPTDIR/config/cluster.sh" "$d/config/"
    printf 'datasetA\n' > "$d/runs/dataset_ids.txt"
    printf '%% input generation\n' > "$d/src/prepareGenerators.m"
}

make_repo() {
    local d=$1
    git -C "$d" init -q
    git -C "$d" config user.email test@example.invalid
    git -C "$d" config user.name test
    git -C "$d" add -A
    git -C "$d" commit -qm "source"
}

pack() {  # give a tree the packaged identity an extracted archive carries
    local d=$1
    (cd "$d" && find . -type f ! -name SHA256SUMS.txt | LC_ALL=C sort |
        while IFS= read -r f; do
            printf '%s  %s\n' "$(hash_of "$f")" "${f#./}"
        done) > "$d/SHA256SUMS.txt"
}

# Same hashing convention as the rest of the tree, GNU first and BSD second.
if command -v sha256sum >/dev/null 2>&1; then H="sha256sum"; else H="shasum -a 256"; fi
hash_of() { $H < "$1" | awk '{print $1}'; }

sid() { (cd "$1" && bash tools/source_id.sh); }
restamp() { (cd "$1" && bash tools/regenerate_datasets.sh restamp 2>&1); }
archive_id() { echo "archive:$(hash_of "$1/SHA256SUMS.txt")"; }

# 1. A checkout is identified by its commit.
CHECKOUT="$TMP/checkout"
make_tree "$CHECKOUT"
make_repo "$CHECKOUT"
COMMIT=$(git -C "$CHECKOUT" rev-parse HEAD)
[ "$(sid "$CHECKOUT")" = "git:$COMMIT" ] && ok "a checkout reports its commit" || \
    { bad "a checkout reports its commit"; echo "      got: $(sid "$CHECKOUT")"; }

# 2. The same checkout reached through a symlink reports the same commit.
ln -s "$CHECKOUT" "$TMP/link"
[ "$(sid "$TMP/link")" = "git:$COMMIT" ] && ok "a symlink to the checkout reports the same commit" || \
    { bad "a symlink to the checkout reports the same commit"; echo "      got: $(sid "$TMP/link")"; }

# 3. A modified tracked file is reported.
echo "% edited" >> "$CHECKOUT/src/prepareGenerators.m"
[ "$(sid "$CHECKOUT")" = "git:$COMMIT+dirty" ] && ok "a modified checkout is marked dirty" || \
    { bad "a modified checkout is marked dirty"; echo "      got: $(sid "$CHECKOUT")"; }
git -C "$CHECKOUT" checkout -q -- src/prepareGenerators.m

# 4. A plain extraction uses its packaged source record.
EXTRACT="$TMP/extract"
make_tree "$EXTRACT"
pack "$EXTRACT"
[ "$(sid "$EXTRACT")" = "$(archive_id "$EXTRACT")" ] && ok "an extraction reports its packaged record" || \
    { bad "an extraction reports its packaged record"; echo "      got: $(sid "$EXTRACT")"; }

# 5. An extraction inside an unrelated repository keeps its packaged identity
#    instead of borrowing the enclosing commit.
OUTER="$TMP/outer"
mkdir -p "$OUTER"
printf 'unrelated project\n' > "$OUTER/notes.txt"
make_repo "$OUTER"
OUTER_COMMIT=$(git -C "$OUTER" rev-parse HEAD)
NESTED="$OUTER/mmb-code"
make_tree "$NESTED"
pack "$NESTED"
got=$(sid "$NESTED")
[ "$got" = "$(archive_id "$NESTED")" ] && ok "a nested extraction reports its packaged record" || \
    { bad "a nested extraction reports its packaged record"; echo "      got: $got"; }
[ "$got" != "git:$OUTER_COMMIT" ] && ok "a nested extraction does not borrow the enclosing commit" || \
    bad "a nested extraction does not borrow the enclosing commit"

# 6. A tree with neither Git metadata nor a packaged record is hashed directly.
BARE="$TMP/bare"
make_tree "$BARE"
case "$(sid "$BARE")" in
    tree:*) ok "a tree with no record is hashed directly" ;;
    *)      bad "a tree with no record is hashed directly"; echo "      got: $(sid "$BARE")" ;;
esac

# 7. The driver's Git check follows the same rule. restamp compares commits,
#    so it runs in a checkout and in a symlink to one, and refuses in an
#    extraction even when an unrelated repository encloses it.
out=$(restamp "$CHECKOUT")
echo "$out" | grep -q "not a Git checkout" && bad "restamp runs in a checkout" || ok "restamp runs in a checkout"
out=$(restamp "$TMP/link")
echo "$out" | grep -q "not a Git checkout" && bad "restamp runs through a symlink" || ok "restamp runs through a symlink"

restamp "$EXTRACT" > /dev/null 2>&1 && bad "restamp refuses in an extraction" || ok "restamp refuses in an extraction"
out=$(restamp "$NESTED")
echo "$out" | grep -q "not a Git checkout" && ok "restamp refuses in a nested extraction" || \
    { bad "restamp refuses in a nested extraction"; echo "$out" | head -3; }

echo ""
# The direct source hash includes HPC checks in their own directory.
mkdir -p "$BARE/tests/hpc"
printf '# first test\n' > "$BARE/tests/hpc/test_example.sh"
before_check=$(sid "$BARE")
printf '# changed test\n' >> "$BARE/tests/hpc/test_example.sh"
[ "$(sid "$BARE")" != "$before_check" ] && ok "source hash includes HPC tests" || \
    bad "source hash includes HPC tests"

echo "source identity: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
