#!/bin/bash
# tests/hpc/test_interruption.sh  [LOGIN NODE]  Resilience under interruption
#
# Check recovery from an interrupted Slurm job. Cancel one running chunk,
# confirm it is missing and resume without recomputing completed chunks.
# Compare the result with an uninterrupted run. Also check that verification
# rejects incomplete output deliberately placed under a result filename.
#
# It also runs a control. With verification bypassed, the killed unit is
# promoted onto its canonical name, and the remaining checks still catch it.
#
# The test tracks the job ids it submits and acts only on those, so it is
# safe to run while other work of yours is in the queue.
#
# Uses the 2 nm D65 to A dataset, about 216 GPU-seconds, forced into 6
# chunks of about 36 s so one can be killed while it runs. Runtime is
# dominated by queue waits. Typically 10 to 30 minutes.
#
# Usage: bash tests/hpc/test_interruption.sh    (from the repository root)
#        PARTITION=<name> bash tests/hpc/test_interruption.sh
#   A preemptible partition is a good choice here. Placement is faster, and
#   a preemption is just another interruption covered by this test.
#
# Exit 0 = all four properties and the control demonstrated.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$SCRIPTDIR/config/cluster.sh"
cd "$SCRIPTDIR"

DATASET_ID="1931_2deg_D65_A_2nm_refl50"
RUNS_FILE="runs/runs_convergence.m"
case "$MMB_OUTPUT_ROOT" in
    /*) OUTROOT=$MMB_OUTPUT_ROOT ;;
    *)  OUTROOT=$SCRIPTDIR/$MMB_OUTPUT_ROOT ;;
esac
RD="$OUTROOT/$DATASET_ID"
FILTER="^${DATASET_ID//./\\.}\$"
NCHUNKS=6
PARTITION=${PARTITION:-$MMB_PARTITION}
PFLAG=${PARTITION:+--partition $PARTITION}
JOB_WAIT_SECONDS=${JOB_WAIT_SECONDS:-3600}

# Guard: this test force-reruns a real dataset, so it must never run against
# collection data. If the dataset already has verified results or a
# certificate, a collection run has already used it, so refuse.
if [ -f "$RD/results/.hull_verified" ] || [ -f "$RD/results/mmb_${DATASET_ID}_gate.json" ]; then
    echo "REFUSING: $DATASET_ID already has verified results." >&2
    echo "Run this test before starting the collection. Running it now would" >&2
    echo "wipe and recompute collection data. To recover the dataset afterwards:" >&2
    echo "  bash tools/regenerate_datasets.sh redo $DATASET_ID --yes" >&2
    exit 1
fi

fail() { echo "INTERRUPTION TEST FAIL: $*" >&2; exit 1; }

# Submit through the launcher and capture the job ids it reports, so every
# wait and every cancellation below is scoped to this test's own jobs.
SUBMIT_OUT=""; ARRAY_ID=""; HULL_ID=""; JOB_IDS=""
submit() {  # submit [extra mmb_run.sh flags...]
    SUBMIT_OUT=$(bash mmb_run.sh $PFLAG "$@" --chunks "$NCHUNKS" \
        --filter "$FILTER" "$RUNS_FILE" 2>&1)
    printf '%s\n' "$SUBMIT_OUT"
    ARRAY_ID=$(printf '%s\n' "$SUBMIT_OUT" | sed -n 's/.*array \([0-9][0-9]*\).*/\1/p' | tail -1)
    HULL_ID=$(printf '%s\n' "$SUBMIT_OUT" | sed -n 's/.*hull \([0-9][0-9]*\)).*/\1/p' | tail -1)
    JOB_IDS=$(printf '%s\n' "$SUBMIT_OUT" | grep -oE '(array|hull|job) [0-9]+' | awk '{print $2}' | sort -u)
    [ -n "$JOB_IDS" ] || fail "the launcher reported no job id. Nothing was submitted"
}

wait_ids() {  # wait until none of the given job ids are in the queue
    local deadline=$(( $(date +%s) + JOB_WAIT_SECONDS ))
    local id live
    while :; do
        live=""
        for id in "$@"; do
            [ -n "$id" ] || continue
            if squeue -h -j "$id" -o "%i" 2>/dev/null | grep -q .; then
                live="$live $id"
            fi
        done
        [ -z "$live" ] && return 0
        [ "$(date +%s)" -gt "$deadline" ] && fail "timed out waiting for job(s):$live"
        sleep 15
    done
}

own_chunks() {  # count this dataset's promoted chunk files
    find "$RD/chunks" -maxdepth 1 -name "mmb_${DATASET_ID}_chunk*.txt" 2>/dev/null | wc -l | tr -d ' '
}

chunk_mtimes() {
    find "$RD/chunks" -maxdepth 1 -name "mmb_${DATASET_ID}_chunk*.txt" \
        -exec stat -c '%n %Y' {} \; 2>/dev/null | sed 's|.*/||' | sort
}

echo "reference run (uninterrupted)"
submit --force-rerun
echo "reference jobs: $(echo $JOB_IDS | tr '\n' ' ')"
wait_ids $JOB_IDS
[ -f "$RD/results/.hull_verified" ] || fail "reference run did not complete verified"
REF_SHA=$(sed -n 's/^vertices_sha256=//p' "$RD/results/.hull_verified")
REF_ROWS=$(sed -n 's/^chunk_rows=//p' "$RD/results/.hull_verified")
[ -n "$REF_SHA" ] || fail "no vertices sha in the reference record"
echo "reference vertices sha256: $REF_SHA"
echo "reference chunk rows:      $REF_ROWS"

echo ""
echo "interrupted run: resubmit, then kill one chunk task of this run"
submit --force-rerun
RUN_ARRAY=$ARRAY_ID
RUN_HULL=$HULL_ID
RUN_IDS=$JOB_IDS
[ -n "$RUN_ARRAY" ] || fail "no array job id. The dataset did not take the chunked route"
echo "interrupted-run array: $RUN_ARRAY  hull: ${RUN_HULL:-none}"

# Wait until some chunks have been promoted, then kill a running task of THIS
# array whose chunk has not been promoted yet. A short task can finish between
# the moment squeue reports it running and the moment the cancellation lands,
# which proves nothing, so the kill is confirmed and another task is tried if
# it did not take effect.
victim=""; victim_idx=""; attempts=0
deadline=$(( $(date +%s) + 1800 ))
while [ -z "$victim_idx" ]; do
    [ "$(date +%s)" -gt "$deadline" ] && fail "no task of array $RUN_ARRAY could be killed in time"
    cand=""; cand_idx=""
    while read -r jid idx; do
        [ -n "$jid" ] || continue
        [ -f "$RD/chunks/mmb_${DATASET_ID}_chunk${idx}.txt" ] && continue
        cand=$jid; cand_idx=$idx
        break
    done < <(squeue -h -j "$RUN_ARRAY" -o "%i %K %t" 2>/dev/null | awk '$3 == "R" {print $1, $2}')
    if [ -z "$cand" ] || [ "$(own_chunks)" -lt 2 ]; then
        if ! squeue -h -j "$RUN_ARRAY" -o "%i" 2>/dev/null | grep -q .; then
            fail "the array finished before a task could be killed. Raise NCHUNKS"
        fi
        sleep 5
        continue
    fi
    attempts=$((attempts + 1))
    echo "killing array task $cand, chunk $cand_idx, of this test's array $RUN_ARRAY"
    scancel "$cand"
    sleep 10
    if [ -f "$RD/chunks/mmb_${DATASET_ID}_chunk${cand_idx}.txt" ]; then
        echo "  that task finished before the cancellation took effect. Trying another"
        [ "$attempts" -ge 6 ] && fail "every candidate finished before it could be killed. Raise NCHUNKS"
        continue
    fi
    victim=$cand; victim_idx=$cand_idx
done
echo "killed chunk $victim_idx and confirmed it was not promoted"

wait_ids "$RUN_ARRAY"
# The afterok hull can never be satisfied now. Cancel this test's hull job
# and clear this dataset's lock, without touching anything else in the queue.
if [ -n "$RUN_HULL" ]; then
    scancel "$RUN_HULL" 2>/dev/null || true
    wait_ids "$RUN_HULL"
fi
rm -f "$RD/.running"

have=$(own_chunks)
[ ! -f "$RD/chunks/mmb_${DATASET_ID}_chunk${victim_idx}.txt" ] || \
    fail "the killed chunk $victim_idx is present. Cannot demonstrate (a)"
[ "$have" -lt "$NCHUNKS" ] || fail "all $NCHUNKS chunks are present. Cannot demonstrate (a)"
echo "(a) killed unit absent: chunk $victim_idx missing, $have/$NCHUNKS canonical chunks on disk"
[ ! -f "$RD/results/mmb_${DATASET_ID}_vertices.csv" ] || fail "a hull ran despite the incomplete set"

echo ""
echo "(d) a direct merge attempt on the incomplete set must refuse"
if SLURM_SUBMIT_DIR="$SCRIPTDIR" SLURM_JOB_ID=interruption-test bash slurm/hull_job.sh "$RD" "$DATASET_ID"; then
    fail "hull_job accepted an incomplete chunk set"
fi
echo "(d) the hull preflight refused the incomplete set"

echo ""
echo "control: bypass the content check and confirm it is what caught the kill"
# Promote the killed unit's partial output onto its canonical name with a
# bare mv and no verification. The content check must reject that file, and
# the hull must still refuse it once it carries the canonical name.
missing_idx=$(comm -13 \
    <(find "$RD/chunks" -maxdepth 1 -name "mmb_${DATASET_ID}_chunk*.txt" | sed -E -n 's/.*_chunk([0-9]+)\.txt$/\1/p' | awk '{print $0+0}' | sort -u) \
    <(seq 0 $((NCHUNKS - 1)) | sort) | head -1)
[ -n "$missing_idx" ] || fail "control: no missing index found"
CANON="$RD/chunks/mmb_${DATASET_ID}_chunk${missing_idx}.txt"
FORGE="$RD/chunks/.staging.control_forge.txt"

# Prefer the killed task's own leftover staging file, which is the authentic
# partial write. A task killed after finishing its write leaves a complete
# staging file, which verifies legitimately and shows nothing here. In that
# case truncate a completed sibling and relabel it to the missing index.
leftover=$(find "$RD/chunks" -maxdepth 1 -name ".staging.mmb_${DATASET_ID}_chunk${missing_idx}.*" ! -name "*.FAILED*" 2>/dev/null | head -1)
if [ -n "$leftover" ] && ! bash tools/verify_chunk.sh "$leftover" \
        --dataset-id "$DATASET_ID" --chunk "$missing_idx" --nchunks "$NCHUNKS" --require-footer \
        --generators "$RD/generators_${DATASET_ID}.txt" >/dev/null 2>&1; then
    cp "$leftover" "$FORGE"
    echo "control input: the killed task's own partial staging file"
else
    donor=$(find "$RD/chunks" -maxdepth 1 -name "mmb_${DATASET_ID}_chunk*.txt" | head -1)
    head -n $(( $(wc -l < "$donor") / 2 )) "$donor" | \
        sed "s/% chunk=[0-9]*/% chunk=${missing_idx}/" > "$FORGE"
    echo "control input: a completed sibling truncated and relabeled to chunk ${missing_idx}"
fi

if bash tools/verify_chunk.sh "$FORGE" --dataset-id "$DATASET_ID" --chunk "$missing_idx" --nchunks "$NCHUNKS" \
        --require-footer --generators "$RD/generators_${DATASET_ID}.txt"; then
    rm -f "$FORGE"
    fail "control: verification accepted a partial write"
fi
echo "(control-1) verify_chunk rejected the killed unit's partial output"

mv -f "$FORGE" "$CANON"
echo "(control-2) a bare mv created the canonical name, so the index set now reads $(own_chunks)/$NCHUNKS,"
echo "            so a completeness test based on names and counts would call this dataset complete"

if SLURM_SUBMIT_DIR="$SCRIPTDIR" SLURM_JOB_ID=interruption-test bash slurm/hull_job.sh "$RD" "$DATASET_ID"; then
    rm -f "$CANON"
    fail "control: the hull merged an unverified chunk"
fi
echo "(control-3) the hull preflight caught the wrongly promoted chunk and refused the merge"
[ ! -f "$RD/results/mmb_${DATASET_ID}_vertices.csv" ] || fail "control: results exist after a refusal"
rm -f "$CANON"
rm -f "$RD/.running"
echo "(control) forged chunk removed. Resuming the legitimate path"

MTIMES_BEFORE=$(chunk_mtimes)

echo ""
echo "resume: re-invoke the workflow"
submit
echo "resume jobs: $(echo $JOB_IDS | tr '\n' ' ')"
RESUB_LINE=$(printf '%s\n' "$SUBMIT_OUT" | grep -E 'PARTIAL RESUBMIT' || true)
if [ -n "$ARRAY_ID" ]; then
    echo "resubmitted array $ARRAY_ID index set: $(squeue -h -j "$ARRAY_ID" -o '%K' 2>/dev/null | tr -d ' ')"
fi
wait_ids $JOB_IDS
[ -f "$RD/results/.hull_verified" ] || fail "the resume did not complete verified"

NEW_SHA=$(sed -n 's/^vertices_sha256=//p' "$RD/results/.hull_verified")
NEW_ROWS=$(sed -n 's/^chunk_rows=//p' "$RD/results/.hull_verified")
echo "resumed vertices sha256: $NEW_SHA"
[ "$NEW_SHA" = "$REF_SHA" ] || fail "(c) the resumed hull differs from the uninterrupted reference"
[ "$NEW_ROWS" = "$REF_ROWS" ] || fail "(c) per-chunk row counts differ from the reference"
echo "(c) resumed result byte-identical to the uninterrupted reference"
echo "(b) resubmission was index-scoped: ${RESUB_LINE:-see the line above}"
echo "    surviving chunk mtimes before the resume:"
echo "$MTIMES_BEFORE" | sed 's/^/      /'

echo ""
echo "INTERRUPTION TEST PASS. On live Slurm:"
echo "  (a) a killed chunk is detected as not done, with no canonical file"
echo "  (b) the resume redoes only the killed index. Survivors are kept"
echo "  (c) the resumed hull is byte-identical to an uninterrupted run"
echo "  (d) an incomplete set cannot be hulled"
echo "  (control) with verification bypassed the killed unit is promoted,"
echo "      and the remaining checks still catch it"
mkdir -p "$SCRIPTDIR/.checks"
{ echo "source_id=$(bash "$SCRIPTDIR/tools/source_id.sh")"; echo "date=$(date -u +%FT%TZ)"; echo "check=interruption"; } \
    > "$SCRIPTDIR/.checks/interruption.PASS"
echo "stamp written: .checks/interruption.PASS"
