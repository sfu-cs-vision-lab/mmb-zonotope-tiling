#!/bin/bash
# tests/shell/test_restamp.sh
# Test updates to saved check records after changes to the source.

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_restamp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; failed=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failed=$((failed+1)); echo "  FAIL: $1"; }

WORK="$TMP/repo"
mkdir -p "$WORK/tools" "$WORK/.checks" "$WORK/docs" "$WORK/cuda" "$WORK/config" "$WORK/slurm" "$WORK/runs" "$WORK/tests/hpc"
cp "$SCRIPTDIR/tools/regenerate_datasets.sh" "$SCRIPTDIR/tools/source_id.sh" "$SCRIPTDIR/tools/slurm_jobs.sh" "$WORK/tools/"
cp "$SCRIPTDIR/config/cluster.sh" "$WORK/config/"
printf 'datasetA\n' > "$WORK/runs/dataset_ids.txt"

git -C "$WORK" init -q
git -C "$WORK" config user.email t@t && git -C "$WORK" config user.name t
git -C "$WORK" add -A && git -C "$WORK" commit -qm base
BASE=$(git -C "$WORK" rev-parse HEAD)

stamp_all() {
    for g in example determinism interruption check-inputs; do
        { echo "source_id=git:$1"; echo "date=x"; echo "check=$g"; } > "$WORK/.checks/$g.PASS"
    done
}
run_restamp() { (cd "$WORK" && bash tools/regenerate_datasets.sh restamp "$@" 2>&1); }

# 1. Docs-only commit -> all four restamp automatically, trail records the TRUE base
stamp_all "$BASE"
echo x > "$WORK/docs/note.md"
git -C "$WORK" add -A && git -C "$WORK" commit -qm docs
HEAD1=$(git -C "$WORK" rev-parse HEAD)
out=$(run_restamp)
[ "$(echo "$out" | grep -c RESTAMP)" -eq 4 ] && ok "docs-only diff restamps all four" || { bad "docs-only restamps all four"; echo "$out"; }
grep -q "source_id=git:$HEAD1" "$WORK/.checks/example.PASS" && ok "stamp re-pinned to HEAD" || bad "stamp re-pinned"
grep -q "from=$BASE" "$WORK/.checks/example.PASS" && ok "trail records the stamp's own base" || bad "trail base"

# 2. Kernel commit -> example/determinism/interruption refuse, check-inputs restamps
stamp_all "$HEAD1"
echo y > "$WORK/cuda/mmb_exact_cuda.cu"
git -C "$WORK" add -A && git -C "$WORK" commit -qm kernel
out=$(run_restamp)
[ "$(echo "$out" | grep -c "RE-RUN")" -eq 3 ] && ok "kernel diff refuses the three kernel checks" || { bad "kernel refusals"; echo "$out"; }
echo "$out" | grep -q "cuda/mmb_exact_cuda.cu" && ok "refusal names the checked file" || bad "refusal names file"
echo "$out" | grep "RESTAMP" | grep -q "check-inputs" && ok "check-inputs restamps (cuda is not among its inputs)" || bad "check-inputs restamps"

# 3. --force records a reasoned override for a refused check
stamp_all "$HEAD1"
out=$(run_restamp --force example "kernel comment-only change, judged outside numerics")
echo "$out" | grep -q "FORCED.*example" && ok "--force overrides the refusal" || { bad "--force overrides"; echo "$out"; }
grep -q "restamp_reason=kernel comment-only" "$WORK/.checks/example.PASS" && ok "override reason recorded in stamp" || bad "override reason recorded"
grep -q "restamped=forced" "$WORK/.checks/example.PASS" && ok "override marked forced, not auto" || bad "forced marker"

# 4. Stamp already at HEAD -> untouched. Unknown check for --force -> error
out=$(run_restamp)
echo "$out" | grep -q "OK.*example already records HEAD" && ok "HEAD stamp left alone" || bad "HEAD stamp left alone"
if run_restamp --force nosuchcheck "x" >/dev/null 2>&1; then bad "unknown check must error"; else ok "unknown --force check errors"; fi

# 5. Stamp with a commit unknown to the clone -> re-run demanded, no restamp
{ echo "source_id=git:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; echo "check=example"; } > "$WORK/.checks/example.PASS"
out=$(run_restamp)
echo "$out" | grep -q "RE-RUN.*example.*unknown to this clone" && ok "unverifiable base demands re-run" || { bad "unverifiable base"; echo "$out"; }

# 6. The interruption check covers the job-matching helper, so a change to it
#    demands that check be run again.
stamp_all "$(git -C "$WORK" rev-parse HEAD)"
echo "# queue helper change" >> "$WORK/tools/slurm_jobs.sh"
git -C "$WORK" add -A && git -C "$WORK" commit -qm "queue helper"
out=$(run_restamp)
echo "$out" | grep "RE-RUN" | grep -q interruption && ok "a slurm_jobs.sh change demands the interruption check again" || \
    { bad "a slurm_jobs.sh change demands the interruption check again"; echo "$out"; }
echo "$out" | grep -A2 "interruption" | grep -q "tools/slurm_jobs.sh" && ok "the refusal names tools/slurm_jobs.sh" || \
    { bad "the refusal names tools/slurm_jobs.sh"; echo "$out"; }
echo "$out" | grep "RESTAMP" | grep -q "example" && ok "checks that do not cover it still restamp" || \
    { bad "checks that do not cover it still restamp"; echo "$out"; }

# 7. A check that has never passed has no record to update. --force does not
#    create one, so a failed input comparison cannot be stamped as passing.
rm -f "$WORK/.checks/check-inputs.PASS"
out=$(run_restamp --force check-inputs "input comparison failed on this platform")
echo "$out" | grep -q "NOT RUN.*check-inputs" && ok "a check with no record reports NOT RUN" || \
    { bad "a check with no record reports NOT RUN"; echo "$out"; }
[ ! -f "$WORK/.checks/check-inputs.PASS" ] && ok "--force does not create a passing record" || \
    { bad "--force does not create a passing record"; cat "$WORK/.checks/check-inputs.PASS"; }

echo ""
# Each HPC test must still be covered by its saved check record.
for check in example determinism interruption; do
    stamp_all "$(git -C "$WORK" rev-parse HEAD)"
    printf '# changed test\n' >> "$WORK/tests/hpc/test_${check}.sh"
    git -C "$WORK" add -A && git -C "$WORK" commit -qm "change HPC test"
    out=$(run_restamp)
    echo "$out" | grep "RE-RUN" | grep -q "$check" && ok "$check covers its test script" || \
        { bad "$check covers its test script"; echo "$out"; }
done

stamp_all "$(git -C "$WORK" rev-parse HEAD)"
printf 'datasetB\n' >> "$WORK/runs/dataset_ids.txt"
git -C "$WORK" add -A && git -C "$WORK" commit -qm "change dataset list"
out=$(run_restamp)
echo "$out" | grep "RE-RUN" | grep -q check-inputs && ok "input check covers the dataset list" || \
    { bad "input check covers the dataset list"; echo "$out"; }

echo "restamp: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
