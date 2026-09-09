#!/bin/bash
# tests/shell/test_mmb_run_routing.sh
# Test launcher routing and resubmission using simulated cluster commands.

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_runtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; failed=0
ok()   { pass=$((pass+1)); echo "  PASS: $1"; }
bad()  { failed=$((failed+1)); echo "  FAIL: $1"; }

# Work on an isolated copy of the repo scripts (mmb_run writes runs_output/)
WORK="$TMP/repo"
mkdir -p "$WORK/slurm" "$WORK/tools" "$WORK/runs" "$WORK/src" "$WORK/cuda" "$WORK/config"
cp "$SCRIPTDIR/config/cluster.sh" "$WORK/config/"
cp "$SCRIPTDIR/mmb_run.sh" "$WORK/"
cp "$SCRIPTDIR"/slurm/*.sh "$WORK/slurm/"
cp "$SCRIPTDIR"/tools/*.sh "$WORK/tools/"
touch "$WORK/cuda/mmb_exact" && chmod +x "$WORK/cuda/mmb_exact"

# Stubs
mkdir -p "$TMP/bin"
cat > "$TMP/bin/module" << 'EOF'
#!/bin/bash
exit 0
EOF
# matlab stub: honor the cd('...') in the -batch string (mmb_run points it at
# the prep dir), then emulate a runs-file generating one 10nm generators file there.
cat > "$TMP/bin/matlab" << 'EOF'
#!/bin/bash
target=$(echo "$*" | sed -n "s/.*cd('\([^']*\)').*/\1/p")
[ -n "$target" ] && cd "$target"
S="1931_2deg_D65_A_10nm_refl50"
{
  echo "% test generators file FRESH"
  echo "% payload_sha256=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  echo "40"
  echo "1.0 2.0 3.0"
  for i in $(seq 1 40); do echo "$i 1 1 1 1 1 1"; done
} > "generators_${S}.txt"
exit 0
EOF
cat > "$TMP/bin/sbatch" << 'EOF'
#!/bin/bash
[ -n "${SBATCH_LOG:-}" ] && echo "$@" >> "$SBATCH_LOG"
echo "12345"
EOF
cat > "$TMP/bin/squeue" << 'EOF'
#!/bin/bash
[ -z "${SQUEUE_ARGS_LOG:-}" ] || echo "$@" >> "$SQUEUE_ARGS_LOG"
cat "${MMB_QUEUE_FIXTURE:-/dev/null}"
exit "${MMB_QUEUE_EXIT:-0}"
EOF
cat > "$TMP/bin/scancel" << 'EOF'
#!/bin/bash
[ -z "${SCANCEL_LOG:-}" ] || echo "$@" >> "$SCANCEL_LOG"
exit 0
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
# An environment module system reaches these tests two ways. It exports
# `module` as a shell function, and BASH_ENV makes every non-interactive
# shell re-define it. A function takes precedence over the stub on PATH.
# Close both so the stubbed command is used on a cluster login node too.
unset -f module 2>/dev/null || true
unset BASH_ENV

S="1931_2deg_D65_A_10nm_refl50"
echo "% runs stub" > "$WORK/runs/runs_test.m"

# Run the launcher under the shell running this suite, so a Bash 4.2+ run
# exercises the associative-array modes that Bash 3.2 cannot reach.
run_mmb() { (cd "$WORK" && "$BASH" mmb_run.sh "$@" runs/runs_test.m 2>&1); }

# 1. Fresh dataset_id routes to single GPU (n=40 -> <10min), generators file lands in RUNDIR
out=$(run_mmb --dry-run)
echo "$out" | grep -q "single GPU" && ok "fresh dataset_id routes (dry-run)" || { bad "fresh dataset_id routes (dry-run)"; echo "$out"; }
[ -f "$WORK/runs_output/$S/generators_$S.txt" ] && ok "generators file routed to RUNDIR (exact name)" || bad "generators file routed to RUNDIR"
ls "$WORK"/generators_*.txt >/dev/null 2>&1 && bad "no generators file left in repo root" || ok "no generators file left in repo root"
ls -d "$WORK"/.prep.* >/dev/null 2>&1 && bad "prep dir cleaned up" || ok "prep dir cleaned up"

# 2. Verified results -> SKIP. Unverified results -> NOT skipped
RD="$WORK/runs_output/$S"
mkdir -p "$RD/results"
printf '0,0,0\n1,0,0\n0,1,0\n0,0,1\n' > "$RD/results/mmb_${S}_vertices.csv"
echo "Boundary vertices: 4" > "$RD/results/mmb_${S}_summary.txt"
out=$(run_mmb --dry-run)
echo "$out" | grep -q "SKIP    verified" && bad "unverified results not skipped" || ok "unverified results not skipped"
echo "verified" > "$RD/results/.hull_verified"
out=$(run_mmb --dry-run)
echo "$out" | grep -q "SKIP    verified results exist" && ok "verified results skipped" || { bad "verified results skipped"; echo "$out"; }

# 3. Results named for another dataset do not satisfy the skip check
rm -f "$RD/results/mmb_${S}_vertices.csv" "$RD/results/mmb_${S}_summary.txt" "$RD/results/.hull_verified"
printf '0,0,0\n' > "$RD/results/mmb_OTHER_DATASET_vertices.csv"
echo "x" > "$RD/results/mmb_OTHER_DATASET_summary.txt"
echo "v" > "$RD/results/.hull_verified"
out=$(run_mmb --dry-run)
echo "$out" | grep -q "SKIP    verified results exist" && bad "alien results don't satisfy skip" || ok "alien results don't satisfy skip"
rm -rf "$RD/results"

# 4. A chunk named for another dataset prevents submission
mkdir -p "$RD/chunks"
echo "% junk" > "$RD/chunks/mmb_ALIEN_DATASET_chunk0.txt"
out=$(run_mmb --dry-run)
echo "$out" | grep -q "file from another dataset" && ok "chunk from another dataset blocks dispatch" || { bad "chunk from another dataset blocks dispatch"; echo "$out"; }
rm -rf "$RD/chunks"

# 5. Partial this dataset chunks -> resubmit only the missing indices
mkdir -p "$RD/chunks"
echo 3 > "$RD/.nchunks"
for i in 0 2; do
    { echo "% Input: /x/generators_${S}.txt"; echo "% n=40, vertices=1"; echo "% chunk=$i, nchunks=3"; echo "1 2 3"; echo "% complete vertices=1"; } \
        > "$RD/chunks/mmb_${S}_chunk${i}.txt"
done
out=$(run_mmb --dry-run)
echo "$out" | grep -q -- "--array=1," && ok "missing chunk resubmitted by index" || \
    { echo "$out" | grep -q "partial resubmit (1/3 missing, --array=1" && ok "missing chunk resubmitted by index" || { bad "missing chunk resubmitted by index"; echo "$out" | tail -5; }; }

# 6. --chunks forces the array route (the interruption check needs real chunks)
rm -rf "$RD"
out=$(run_mmb --dry-run --chunks 4)
echo "$out" | grep -q "parallel (4 GPUs" && ok "--chunks forces the array route" || { bad "--chunks forces the array route"; echo "$out" | tail -3; }

# 7. Input without a payload hash is replaced. Input with a hash is kept.
rm -rf "$RD"; mkdir -p "$RD"
{ echo "% INPUT WITHOUT PAYLOAD HASH"; echo "40"; echo "1 2 3"; } > "$RD/generators_$S.txt"
run_mmb --dry-run > /dev/null
grep -q "payload_sha256" "$RD/generators_$S.txt" && ok "sha-less generators file replaced with fresh" || bad "sha-less generators file replaced with fresh"
echo "% PRESERVED MARKER" >> "$RD/generators_$S.txt"
run_mmb --dry-run > /dev/null
grep -q "PRESERVED MARKER" "$RD/generators_$S.txt" && ok "sha-bearing generators file preserved" || bad "sha-bearing generators file preserved"

# 7b. Memory tiers: pin the sizing functions (chunk = code ceiling, hull
# middle tier = high-chroma 2nm, shared by standalone hulls, the single-GPU
# inline hull and the OOM-recovery resubmit path)
eval "$(sed -n '/^hull_mem_for_n()/,/^}/p' "$WORK/mmb_run.sh")"
eval "$(sed -n '/^chunk_mem_for_n()/,/^}/p' "$WORK/mmb_run.sh")"
[ "$(hull_mem_for_n 40)" = "8000M" ] && [ "$(hull_mem_for_n 200)" = "32000M" ] && [ "$(hull_mem_for_n 401)" = "32000M" ] \
    && ok "hull mem tiers 8G/32G-flat (measured ceiling 19.55G)" || bad "hull mem tiers"
[ "$(chunk_mem_for_n 200)" = "4000M" ] && [ "$(chunk_mem_for_n 401)" = "6000M" ] \
    && ok "chunk mem tiers 4G/6G (code ceiling)" || bad "chunk mem tiers"

# 8. File_epoch must yield a clean integer even when Linux stat -f (filesystem
# status) spews multi-line junk with nonzero exit (the GNU->BSD fallback trap)
eval "$(sed -n '/^file_epoch()/,/^}/p' "$WORK/mmb_run.sh")"
mkdir -p "$TMP/statbin"
cat > "$TMP/statbin/stat" << 'EOF'
#!/bin/bash
if [ "$1" = "-c" ]; then exit 1; fi                      # GNU form fails (EIO/missing)
if [ "$1" = "-f" ]; then                                  # Linux: filesystem junk + exit 1
    printf '  File: "%s"\n  ID: x Namelen: 255 Type: lustre\nBlocks: Total: 5\n' "$3"
    exit 1
fi
exit 1
EOF
chmod +x "$TMP/statbin/stat"
e=$(PATH="$TMP/statbin:$PATH" file_epoch "/some/chunk11.txt")
[ "$e" = "0" ] && ok "file_epoch returns 0 on Linux stat -f junk (not multiline garbage)" || { bad "file_epoch junk handling"; echo "got: $e"; }
e=$(file_epoch "$WORK/mmb_run.sh")
[[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -gt 0 ] && ok "file_epoch returns real epoch for existing file" || bad "file_epoch real epoch"

# 9. Killed chunks resubmit at BASE walltime (kill residue does not show the
# cause. Preemption leaves the same leftovers as a timeout, so a retry keeps
# its base estimate). Three failed attempts name sacct.
# MMB_CHUNK_WALL_MINS is the operator override, capped at 170.
rm -rf "$RD"; mkdir -p "$RD/chunks"
{ echo "% collection generators"; echo "% payload_sha256=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"; echo "40"; echo "1 2 3"; } > "$RD/generators_$S.txt"
echo 3 > "$RD/.nchunks"
for i in 0 2; do
    { echo "% Input: /x/generators_${S}.txt"; echo "% n=40, vertices=1"; echo "% chunk=$i, nchunks=3"; echo "1 2 3"; echo "% complete vertices=1"; } \
        > "$RD/chunks/mmb_${S}_chunk${i}.txt"
done
touch "$RD/chunks/.staging.mmb_${S}_chunk1.111.txt" "$RD/chunks/.staging.mmb_${S}_chunk1.222.txt" \
      "$RD/chunks/.staging.mmb_${S}_chunk1.444.txt"
touch "$RD/chunks/.staging.mmb_${S}_chunk1.333.FAILED.txt"
export SBATCH_LOG="$TMP/sbatch.log"; : > "$SBATCH_LOG"
out=$(run_mmb)
grep -q -- "--array=1" "$SBATCH_LOG" && ok "resubmit targets the missing index" || { bad "resubmit targets missing index"; cat "$SBATCH_LOG"; }
grep -q -- "--time=00:10:00" "$SBATCH_LOG" && ok "resubmit stays at BASE walltime despite kill residue" || { bad "resubmit at base"; grep -o -- "--time=[0-9:]*" "$SBATCH_LOG"; }
grep -q -- "--mem=4000M" "$SBATCH_LOG" && ok "chunk mem sized to code ceiling tier (4000M for n<=220)" || { bad "chunk mem tier"; grep -o -- "--mem=[0-9M]*" "$SBATCH_LOG"; }
echo "$out" | grep -q "ADVISORY: chunk 1 has 3 killed attempts" && ok "repeated kills give an advisory (not silent inflation)" || { bad "kill advisory"; echo "$out" | tail -4; }
echo "$out" | grep -q "sacct" && ok "advisory names the cause-diagnosis command" || bad "advisory names sacct"
: > "$SBATCH_LOG"; rm -f "$RD/.running"
(cd "$WORK" && MMB_CHUNK_WALL_MINS=25 "$BASH" mmb_run.sh runs/runs_test.m > /dev/null 2>&1)
grep -q -- "--time=00:25:00" "$SBATCH_LOG" && ok "MMB_CHUNK_WALL_MINS override honored" || { bad "override honored"; grep -o -- "--time=[0-9:]*" "$SBATCH_LOG"; }
: > "$SBATCH_LOG"; rm -f "$RD/.running"
(cd "$WORK" && MMB_CHUNK_WALL_MINS=500 "$BASH" mmb_run.sh runs/runs_test.m > /dev/null 2>&1)
grep -q -- "--time=02:50:00" "$SBATCH_LOG" && ok "override capped at 170min" || { bad "override cap"; grep -o -- "--time=[0-9:]*" "$SBATCH_LOG"; }
unset SBATCH_LOG

# Forced reruns cancel only jobs for the same output directory.
source "$WORK/tools/slurm_jobs.sh"
QUEUE_TAG=$(mmb_job_tag "$WORK/runs_output")
export MMB_QUEUE_FIXTURE="$TMP/queue.txt" SCANCEL_LOG="$TMP/cancel.log" SBATCH_LOG="$TMP/sbatch.log"
printf '%s|4001 hull-%s\n%s|4002 hull-%s\n(null)|4003 hull-%s\n' \
    "$QUEUE_TAG" "$S" "$(mmb_job_tag "$TMP/other_output")" "$S" "$S" > "$MMB_QUEUE_FIXTURE"
: > "$SCANCEL_LOG"; : > "$SBATCH_LOG"
out=$(run_mmb --force-rerun)
[ "$(cat "$SCANCEL_LOG")" = "4001" ] && ok "forced rerun cancels only this output directory's job" || { bad "forced rerun job scope"; cat "$SCANCEL_LOG"; }
grep -q -- "--comment=$QUEUE_TAG" "$SBATCH_LOG" && ok "submitted jobs identify their output directory" || bad "job output directory tag missing"
[ "$(mmb_job_tag "$WORK/runs_output/../runs_output")" = "$QUEUE_TAG" ] && ok "equivalent output paths match the same jobs" || bad "equivalent output paths differ"
unset MMB_QUEUE_FIXTURE SCANCEL_LOG SBATCH_LOG

# Queue reads. The account name falls back to `id -un`, and a query that
# fails is an error rather than evidence that a dataset has no jobs.
export MMB_QUEUE_FIXTURE="$TMP/queue.txt" SQUEUE_ARGS_LOG="$TMP/squeue_args.log"
export SCANCEL_LOG="$TMP/cancel.log" SBATCH_LOG="$TMP/sbatch.log"
ME=$(id -un)
printf '%s|  7001 mmb-%s\n(null)|  7002 mmb-%s\n' "$QUEUE_TAG" "$S" "$S" > "$MMB_QUEUE_FIXTURE"

: > "$SQUEUE_ARGS_LOG"
(unset USER; mmb_squeue "$QUEUE_TAG" "%.30i %.200j" > /dev/null)
grep -q -- "-u $ME" "$SQUEUE_ARGS_LOG" && ok "unset USER falls back to the account name" || \
    { bad "unset USER falls back to the account name"; cat "$SQUEUE_ARGS_LOG"; }
: > "$SQUEUE_ARGS_LOG"
(USER="" mmb_squeue "$QUEUE_TAG" "%.30i %.200j" > /dev/null)
grep -q -- "-u $ME" "$SQUEUE_ARGS_LOG" && ok "empty USER falls back to the account name" || \
    { bad "empty USER falls back to the account name"; cat "$SQUEUE_ARGS_LOG"; }

rows=$(mmb_squeue "$QUEUE_TAG" "%.30i %.200j"); rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s' "$rows" | grep -c .)" -eq 1 ] && \
    ok "populated queue returns this output directory's jobs only" || \
    { bad "populated queue returns this output directory's jobs only"; echo "rc=$rc rows=$rows"; }
: > "$MMB_QUEUE_FIXTURE"
rows=$(mmb_squeue "$QUEUE_TAG" "%.30i %.200j"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$rows" ] && ok "empty queue succeeds with no rows" || \
    { bad "empty queue succeeds with no rows"; echo "rc=$rc rows=$rows"; }

printf '%s|  7001 mmb-%s\n' "$QUEUE_TAG" "$S" > "$MMB_QUEUE_FIXTURE"
rows=$(MMB_QUEUE_EXIT=1 mmb_squeue "$QUEUE_TAG" "%.30i %.200j" 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && [ -z "$rows" ] && ok "a failed query reports failure and emits no rows" || \
    { bad "a failed query reports failure and emits no rows"; echo "rc=$rc rows=$rows"; }

# A failed query stops every mode that would otherwise treat a dataset as
# inactive. Nothing is canceled, deleted or submitted, and no lock is removed.
# Same hashing convention as the rest of the tree, GNU first and BSD second.
if command -v sha256sum >/dev/null 2>&1; then H="sha256sum"; else H="shasum -a 256"; fi
snapshot() {  # snapshot DIR -> "path sha256" per file
    (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$($H < "$f" | awk '{print $1}')"
    done)
}
seed_dataset() {
    rm -rf "$RD"; mkdir -p "$RD/chunks" "$RD/results"
    { echo "% generators"
      echo "% payload_sha256=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
      echo "40"; echo "1 2 3"; } > "$RD/generators_$S.txt"
    { echo "% Input: /x/generators_${S}.txt"; echo "% n=40, vertices=1"
      echo "% chunk=0, nchunks=1"; echo "1 2 3"; echo "% complete vertices=1"; } \
        > "$RD/chunks/mmb_${S}_chunk0.txt"
    echo 1 > "$RD/.nchunks"
    printf '0,0,0\n' > "$RD/results/mmb_${S}_vertices.csv"
    echo "Boundary vertices: 1" > "$RD/results/mmb_${S}_summary.txt"
    echo verified > "$RD/results/.hull_verified"
    touch "$RD/.running"
}

# Partial output: the query died after listing another dataset's job, so the
# rows it did emit do not mention this dataset. Believing them would clear a
# live lock and cancel nothing that is actually queued.
printf '%s|  7001 mmb-other_dataset RUNNING None\n' "$QUEUE_TAG" > "$MMB_QUEUE_FIXTURE"
# --status, --clean-stale and --heal build associative arrays, so they need
# Bash 4.2 or newer. Name the shell instead of passing the modes silently.
queue_modes="--force-rerun --force-hull"
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    queue_modes="--status --clean-stale --heal $queue_modes"
else
    echo "  SKIP: --status, --clean-stale and --heal need Bash 4.2+ (running $BASH_VERSION)"
fi
for mode in $queue_modes; do
    seed_dataset
    before=$(snapshot "$RD")
    : > "$SCANCEL_LOG"; : > "$SBATCH_LOG"
    MMB_QUEUE_EXIT=1 run_mmb "$mode" > /dev/null 2>&1
    rc=$?
    after=$(snapshot "$RD")
    if [ "$rc" -ne 0 ] && [ "$before" = "$after" ] && [ -f "$RD/.running" ] &&
       [ ! -s "$SCANCEL_LOG" ] && [ ! -s "$SBATCH_LOG" ]; then
        ok "$mode stops on a failed queue query and changes nothing"
    else
        bad "$mode stops on a failed queue query and changes nothing"
        echo "      rc=$rc lock=$([ -f "$RD/.running" ] && echo kept || echo cleared)"
        echo "      scancel=$(wc -l < "$SCANCEL_LOG") sbatch=$(wc -l < "$SBATCH_LOG")"
        diff <(echo "$before") <(echo "$after") | head -5
    fi
done

# --dry-run with a force option previews without canceling or deleting,
# including a dataset that already has verified results.
printf '%s|  8001 mmb-%s\n%s|  8002 hull-%s\n' "$QUEUE_TAG" "$S" "$QUEUE_TAG" "$S" > "$MMB_QUEUE_FIXTURE"
for mode in --force-rerun --force-hull; do
    seed_dataset
    before=$(snapshot "$RD")
    : > "$SCANCEL_LOG"; : > "$SBATCH_LOG"
    out=$(run_mmb --dry-run "$mode")
    rc=$?
    after=$(snapshot "$RD")
    if [ "$rc" -eq 0 ] && [ "$before" = "$after" ] && [ ! -s "$SCANCEL_LOG" ] && [ ! -s "$SBATCH_LOG" ]; then
        ok "--dry-run $mode keeps jobs and computed outputs"
    else
        bad "--dry-run $mode keeps jobs and computed outputs"
        echo "      rc=$rc scancel=$(wc -l < "$SCANCEL_LOG") sbatch=$(wc -l < "$SBATCH_LOG")"
        diff <(echo "$before") <(echo "$after") | head -5
    fi
    echo "$out" | grep -q "$S" && ok "--dry-run $mode reports the dataset" || \
        { bad "--dry-run $mode reports the dataset"; echo "$out" | tail -4; }
done

# Without --dry-run, --force-hull still cancels this output directory's jobs
# and resubmits the hull.
seed_dataset
: > "$SCANCEL_LOG"; : > "$SBATCH_LOG"
run_mmb --force-hull > /dev/null 2>&1
[ "$(cat "$SCANCEL_LOG")" = "8001
8002" ] && ok "forced hull cancels this output directory's jobs" || \
    { bad "forced hull cancels this output directory's jobs"; cat "$SCANCEL_LOG"; }
grep -q -- "--job-name=hull-$S" "$SBATCH_LOG" && ok "forced hull resubmits the hull job" || \
    { bad "forced hull resubmits the hull job"; cat "$SBATCH_LOG"; }
[ ! -f "$RD/results/mmb_${S}_vertices.csv" ] && ok "forced hull clears the previous results" || \
    bad "forced hull clears the previous results"

unset MMB_QUEUE_FIXTURE SCANCEL_LOG SBATCH_LOG SQUEUE_ARGS_LOG

echo ""
echo "mmb_run routing: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
