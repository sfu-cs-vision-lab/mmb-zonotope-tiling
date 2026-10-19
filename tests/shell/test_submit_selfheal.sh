#!/bin/bash
# tests/shell/test_submit_selfheal.sh
# Test recovery from failed array jobs and removal of inactive locks.

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_heal.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; failed=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failed=$((failed+1)); echo "  FAIL: $1"; }

WORK="$TMP/repo"
mkdir -p "$WORK/tools" "$WORK/runs" "$WORK/.checks" "$WORK/runs_output" "$WORK/config"
cp "$SCRIPTDIR/tools/regenerate_datasets.sh" "$SCRIPTDIR/tools/source_id.sh" "$SCRIPTDIR/tools/slurm_jobs.sh" "$WORK/tools/"
cp "$SCRIPTDIR/config/cluster.sh" "$WORK/config/"
printf 'datasetA\ndatasetB\ndatasetC\n' > "$WORK/runs/dataset_ids.txt"
touch "$WORK/runs/runs_all_datasets.m"
printf '#!/bin/bash\necho "MMBRUN-STUB $*"\n' > "$WORK/mmb_run.sh"

mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho stub-head\n' > "$TMP/bin/git"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/module"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/matlab"
cat > "$TMP/bin/scancel" << 'EOF'
#!/bin/bash
echo "$@" >> "${SCANCEL_LOG:?}"
EOF
# squeue stub: emits whatever SQUEUE_FIXTURE contains
cat > "$TMP/bin/squeue" << 'EOF'
#!/bin/bash
cat "${SQUEUE_FIXTURE:-/dev/null}" 2>/dev/null
exit "${SQUEUE_EXIT:-0}"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
# An environment module system reaches these tests two ways. It exports
# `module` as a shell function, and BASH_ENV makes every non-interactive
# shell re-define it. A function takes precedence over the stub on PATH.
# Close both so the stubbed command is used on a cluster login node too.
unset -f module 2>/dev/null || true
unset BASH_ENV
export SCANCEL_LOG="$TMP/scancel.log"
export SQUEUE_FIXTURE="$TMP/squeue.txt"

source "$WORK/tools/slurm_jobs.sh"
QUEUE_TAG=$(mmb_job_tag "$WORK/runs_output")
SID=$(cd "$WORK" && bash tools/source_id.sh)
for g in example determinism interruption check-inputs; do
    { echo "source_id=$SID"; echo "check=$g"; } > "$WORK/.checks/$g.PASS"
done

# Run the driver under the shell running this suite, so a Bash 4.2+ run
# reaches the launcher paths that Bash 3.2 cannot.
run_submit() { (cd "$WORK" && "$BASH" tools/regenerate_datasets.sh submit --max-datasets 2 2>&1); }

# 1. DatasetA: orphaned lock, NO jobs at all (auto-canceled zombie) -> cleared,
#    dataset_id becomes submittable
mkdir -p "$WORK/runs_output/datasetA"
touch "$WORK/runs_output/datasetA/.running"
: > "$SQUEUE_FIXTURE"
: > "$SCANCEL_LOG"
out=$(run_submit)
[ ! -f "$WORK/runs_output/datasetA/.running" ] && ok "orphaned lock cleared (no live jobs)" || bad "orphaned lock cleared"
echo "$out" | grep -q "MMBRUN-STUB" && ok "resubmission proceeds in the same invocation" || bad "resubmission proceeds"

# 2. DatasetB: zombie hull (PENDING DependencyNeverSatisfied) -> scancel'd, lock cleared
mkdir -p "$WORK/runs_output/datasetB"
touch "$WORK/runs_output/datasetB/.running"
printf '%s|  9001 hull-datasetB PENDING DependencyNeverSatisfied\n' "$QUEUE_TAG" > "$SQUEUE_FIXTURE"
: > "$SCANCEL_LOG"
out=$(run_submit)
grep -q "9001" "$SCANCEL_LOG" && ok "zombie hull canceled" || bad "zombie hull canceled"
[ ! -f "$WORK/runs_output/datasetB/.running" ] && ok "lock cleared after zombie cancel" || bad "lock cleared after zombie cancel"

# 3. DatasetC: genuinely running (RUNNING chunk task) -> lock kept, counted in-flight
mkdir -p "$WORK/runs_output/datasetC"
touch "$WORK/runs_output/datasetC/.running"
printf '%s|  9002_3 mmb-datasetC RUNNING None\n' "$QUEUE_TAG" > "$SQUEUE_FIXTURE"
: > "$SCANCEL_LOG"
out=$(run_submit)
[ -f "$WORK/runs_output/datasetC/.running" ] && ok "live dataset_id's lock untouched" || bad "live dataset_id's lock untouched"
[ ! -s "$SCANCEL_LOG" ] && ok "no cancellation of live jobs" || bad "no cancellation of live jobs"
echo "$out" | grep -q "In flight: 1" && ok "live dataset_id counted in-flight" || { bad "live dataset_id counted in-flight"; echo "$out" | head -3; }

# A blocked job for another output directory must not be canceled.
touch "$WORK/runs_output/datasetB/.running"
printf '%s|  9003 hull-datasetB PENDING DependencyNeverSatisfied\n' "$(mmb_job_tag "$TMP/other_output")" > "$SQUEUE_FIXTURE"
: > "$SCANCEL_LOG"
out=$(run_submit)
[ ! -s "$SCANCEL_LOG" ] && ok "another output directory's job is not canceled" || bad "canceled a job for another output directory"
[ ! -f "$WORK/runs_output/datasetB/.running" ] && ok "another output directory's job does not retain this lock" || bad "unrelated job retained this lock"

# A failed queue query stops submit before it can act on the rows it did get.
# The partial output names another dataset, so believing it would clear this
# dataset's live lock and submit the dataset a second time.
rm -f "$WORK/runs_output/datasetB/.running"
touch "$WORK/runs_output/datasetC/.running"
printf '%s|  9004 mmb-datasetZ RUNNING None\n' "$QUEUE_TAG" > "$SQUEUE_FIXTURE"
: > "$SCANCEL_LOG"
out=$(SQUEUE_EXIT=1 run_submit); rc=$?
[ "$rc" -ne 0 ] && ok "submit fails when the queue cannot be read" || { bad "submit fails when the queue cannot be read"; echo "rc=$rc"; }
[ -f "$WORK/runs_output/datasetC/.running" ] && ok "a failed query does not clear a live lock" || bad "a failed query does not clear a live lock"
[ ! -s "$SCANCEL_LOG" ] && ok "a failed query cancels nothing" || { bad "a failed query cancels nothing"; cat "$SCANCEL_LOG"; }
echo "$out" | grep -q "MMBRUN-STUB" && bad "a failed query submits nothing" || ok "a failed query submits nothing"

# With USER unset, the queue is still read for the right account, so a live
# lock is recognized rather than cleared.
printf '%s|  9005 mmb-datasetC RUNNING None\n' "$QUEUE_TAG" > "$SQUEUE_FIXTURE"
: > "$SCANCEL_LOG"
out=$( (cd "$WORK" && env -u USER "$BASH" tools/regenerate_datasets.sh submit --max-datasets 2 2>&1) )
[ -f "$WORK/runs_output/datasetC/.running" ] && ok "unset USER still sees the live job and keeps the lock" || \
    { bad "unset USER still sees the live job and keeps the lock"; echo "$out" | head -3; }
echo "$out" | grep -q "In flight: 1" && ok "unset USER counts the live dataset in flight" || \
    { bad "unset USER counts the live dataset in flight"; echo "$out" | head -3; }

echo ""
echo "submit self-heal: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
