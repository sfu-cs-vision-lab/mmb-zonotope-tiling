#!/bin/bash
#SBATCH --job-name=mmb-hull
#SBATCH --cpus-per-task=4
#SBATCH --mem=64000M
#SBATCH --time=01:00:00
# Account and partition come from config/cluster.sh through the sbatch
# command line in mmb_run.sh.

# slurm/hull_job.sh  Convex hull computation after array job
#
# Arguments: $1=RUNDIR $2=DATASET_ID
#
# Check the complete chunk set and each file before building the hull.
# Pass the dataset identifier and an explicit list of files to hullMMB.
# After checking the written results, save .hull_verified and delete chunks.
# On failure, remove partial results, keep the chunks and clear .running
# so the launcher can retry.
#
# On ANY failure: partial results are removed (so the results-exist skip
# cannot lock in a bad answer), chunks are preserved, exit nonzero and the
# EXIT trap clears .running so the launcher can retry.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

RUNDIR=$1
DATASET_ID=$2
SCRIPTDIR=$SLURM_SUBMIT_DIR
VC="$SCRIPTDIR/tools/verify_chunk.sh"

# Retry read and verification failures before rejecting a chunk. A
# temporary shared-filesystem read error can succeed on a later attempt.
RETRY_SLEEP=${MMB_READ_RETRY_SLEEP:-10}
read_retry() {  # CMD ARGS...  (stdout passed through, 4 attempts with backoff)
    local attempt out
    for attempt in 1 2 3 4; do
        if out=$("$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
        [ "$attempt" -lt 4 ] && sleep $((attempt * RETRY_SLEEP))
    done
    return 1
}

trap 'rm -f "$RUNDIR/.running"' EXIT

RESULTS="$RUNDIR/results"
SIDECAR="$RESULTS/.hull_verified"

fail_clean() {
    echo "ERROR: $*" >&2
    echo "Removing partial results so mmb_run.sh can retry. Chunks preserved." >&2
    rm -f "$RESULTS/mmb_${DATASET_ID}_vertices.csv" \
          "$RESULTS/mmb_${DATASET_ID}_faces.csv" \
          "$RESULTS/mmb_${DATASET_ID}_summary.txt" \
          "$SIDECAR"
    exit 1
}

echo "=== mmb-zonotope-tiling hull computation ==="
echo "  Job ID:    $SLURM_JOB_ID"
echo "  Node:      $(hostname)"
echo "  Run dir:   $RUNDIR"
echo "  Dataset:      $DATASET_ID"

# Skip only a VERIFIED completed result (canonical names + sidecar).
# Results without a sidecar are suspect, so clean and recompute them.
if [ -f "$RESULTS/mmb_${DATASET_ID}_vertices.csv" ] && \
   [ -f "$RESULTS/mmb_${DATASET_ID}_summary.txt" ] && \
   [ -f "$SIDECAR" ]; then
    echo "Verified results already exist for $DATASET_ID, skipping hull"
    exit 0
fi

# Clear inherited modules before loading the configured environment.
. "$SCRIPTDIR/config/cluster.sh"
module --force purge >/dev/null 2>&1 || module purge >/dev/null 2>&1 || true
module load $MMB_MODULES_MATLAB

cd "$SCRIPTDIR"

mkdir -p "$RESULTS"
# Clean existing (unverified) canonical results before hull
rm -f "$RESULTS/mmb_${DATASET_ID}_vertices.csv" \
      "$RESULTS/mmb_${DATASET_ID}_faces.csv" \
      "$RESULTS/mmb_${DATASET_ID}_summary.txt" \
      "$SIDECAR"

# Detect kernel output: this dataset array chunks or single-GPU file
shopt -s nullglob
own_chunks=("$RUNDIR/chunks/mmb_${DATASET_ID}_chunk"*.txt)
all_chunkfiles=("$RUNDIR"/chunks/mmb_*.txt)
shopt -u nullglob

# Reject chunk files whose names identify a different dataset.
for f in ${all_chunkfiles[@]+"${all_chunkfiles[@]}"}; do
    b=$(basename "$f")
    case "$b" in
        "mmb_${DATASET_ID}_chunk"*.txt|"mmb_${DATASET_ID}.txt") : ;;
        *) fail_clean "file from another dataset in $RUNDIR/chunks: $b (expected only mmb_${DATASET_ID}_*). Investigate before re-running." ;;
    esac
done

MODE=""
NCHUNKS=0
declare -a HULL_FILES=()
declare -a CHUNK_ROWS=()

if [ "${#own_chunks[@]}" -gt 0 ]; then
    MODE="chunks"
    echo "  Source:    $RUNDIR/chunks/ (${#own_chunks[@]} own-dataset_id chunk files)"

    # Require chunk headers to agree on the count and match .nchunks if present.
    raw=$(read_retry awk 'FNR<=60 && /^% chunk=/{split($0,kv,/nchunks=/); print kv[2]+0; nextfile}' \
        "${own_chunks[@]}") || fail_clean "cannot read chunk headers after retries (transient filesystem fault?)"
    hdrN=$(printf '%s\n' "$raw" | grep . | sort -u)
    if [ "$(echo "$hdrN" | wc -l | tr -d ' ')" -ne 1 ] || [ -z "$hdrN" ]; then
        fail_clean "chunk headers disagree on nchunks (got: $(echo "$hdrN" | tr '\n' ' '))"
    fi
    NCHUNKS=$hdrN
    if [ -f "$RUNDIR/.nchunks" ]; then
        rec=$(tr -d '[:space:]' < "$RUNDIR/.nchunks")
        if [ "$rec" != "$NCHUNKS" ]; then
            fail_clean ".nchunks says $rec but chunk headers say $NCHUNKS"
        fi
    fi

    # Check every chunk against this dataset's current generators file.
    # Rename a rejected chunk under .staging, so the launcher sees its index
    # as missing and recomputes it.
    CD="$RUNDIR/generators_${DATASET_ID}.txt"
    [ -f "$CD" ] || fail_clean "generators file missing: $CD (cannot verify chunk generation)"
    missing=""
    quarantined=""
    for (( i=0; i<NCHUNKS; i++ )); do
        cf="$RUNDIR/chunks/mmb_${DATASET_ID}_chunk${i}.txt"
        if [ ! -f "$cf" ]; then
            missing="$missing $i"
            continue
        fi
        vok=false
        for vtry in 1 2 3; do
            if out=$(bash "$VC" "$cf" --dataset-id "$DATASET_ID" --chunk "$i" --nchunks "$NCHUNKS" --require-footer --generators "$CD" 2>&1); then
                vok=true; break
            fi
            [ -f "$cf" ] || break
            [ "$vtry" -lt 3 ] && sleep $((vtry * RETRY_SLEEP))
        done
        if ! $vok; then
            q="$RUNDIR/chunks/.staging.REJECTED.$(basename "$cf").${SLURM_JOB_ID}"
            mv -f "$cf" "$q" 2>/dev/null || true
            echo "QUARANTINED chunk $i -> $(basename "$q"): $out" >&2
            quarantined="$quarantined $i"
            missing="$missing $i"
            continue
        fi
        rows=$(echo "$out" | sed -n 's/.*vertices=\([0-9]*\).*/\1/p')
        CHUNK_ROWS+=("$i:$rows")
        HULL_FILES+=("$cf")
    done
    if [ -n "$missing" ]; then
        fail_clean "chunk set incomplete for $DATASET_ID: missing chunk(s)$missing of $NCHUNKS${quarantined:+ (quarantined:$quarantined)}. Resubmission will recompute them"
    fi
elif [ -f "$RUNDIR/mmb_${DATASET_ID}.txt" ]; then
    MODE="single"
    echo "  Source:    $RUNDIR/mmb_${DATASET_ID}.txt (single-GPU output)"
    CD="$RUNDIR/generators_${DATASET_ID}.txt"
    [ -f "$CD" ] || fail_clean "generators file missing: $CD (cannot verify generation)"
    vok=false
    for vtry in 1 2 3; do
        if out=$(bash "$VC" "$RUNDIR/mmb_${DATASET_ID}.txt" --dataset-id "$DATASET_ID" --require-footer --generators "$CD" 2>&1); then
            vok=true; break
        fi
        [ "$vtry" -lt 3 ] && sleep $((vtry * RETRY_SLEEP))
    done
    if ! $vok; then
        q="$RUNDIR/.staging.REJECTED.mmb_${DATASET_ID}.txt.${SLURM_JOB_ID}"
        mv -f "$RUNDIR/mmb_${DATASET_ID}.txt" "$q" 2>/dev/null || true
        fail_clean "single-GPU output failed verification and was quarantined ($(basename "$q")): $out"
    fi
    rows=$(echo "$out" | sed -n 's/.*vertices=\([0-9]*\).*/\1/p')
    CHUNK_ROWS+=("single:$rows")
    HULL_FILES+=("$RUNDIR/mmb_${DATASET_ID}.txt")
else
    fail_clean "no kernel output found for $DATASET_ID in $RUNDIR"
fi

# Hull with pinned dataset_id and explicit files (hullMMB re-verifies all)
FILELIST=$(printf '"%s",' "${HULL_FILES[@]}")
FILELIST=${FILELIST%,}
if ! matlab -batch "addpath('src'); hullMMB([$FILELIST], OutputDir='$RESULTS', ExpectDatasetID=\"$DATASET_ID\")"; then
    fail_clean "hullMMB failed (see log above)"
fi

# Post-hull verification of the result files
vcsv="$RESULTS/mmb_${DATASET_ID}_vertices.csv"
summary="$RESULTS/mmb_${DATASET_ID}_summary.txt"
fcsv="$RESULTS/mmb_${DATASET_ID}_faces.csv"
[ -s "$vcsv" ] && [ -s "$summary" ] || fail_clean "hull output missing or empty"
# A flat body (a polygon, segment or point, from sensors of rank below 6)
# has an empty faces file and may have fewer than 4 vertices. Only a
# summary with the "Flat body:" line allows either.
flat=$(read_retry awk '/^Flat body:/{f=1} END{print f+0}' "$summary") || fail_clean "cannot read $summary after retries"
if [ "$flat" -eq 1 ]; then
    [ -f "$fcsv" ] && [ ! -s "$fcsv" ] || fail_clean "flat body must have an empty faces file"
else
    [ -s "$fcsv" ] || fail_clean "hull output missing or empty"
fi

nlines=$(read_retry awk '!/^%/ && NF>0 {n++} END{print n+0}' "$vcsv") || fail_clean "cannot read $vcsv after retries"
sv=$(read_retry awk '/^Boundary vertices:/{print $NF; exit}' "$summary") || fail_clean "cannot read $summary after retries"
[ "$nlines" -ge 4 ] || [ "$flat" -eq 1 ] || fail_clean "vertices CSV has only $nlines rows (degenerate hull)"
[ "$nlines" -eq "$sv" ] || fail_clean "vertices CSV rows ($nlines) != summary count ($sv)"
grep -q '% PARTIAL' "$summary" && fail_clean "summary branded PARTIAL, refusing to record as verified"

vsha=$(sed -n 's/^% vertices_sha256=//p' "$summary")
fsha=$(sed -n 's/^% faces_sha256=//p' "$summary")

# Durable record FIRST (atomic), deletion strictly AFTER
{
    echo "dataset_id=$DATASET_ID"
    echo "mode=$MODE"
    echo "nchunks=$NCHUNKS"
    echo "chunk_rows=${CHUNK_ROWS[*]}"
    echo "boundary_vertices=$sv"
    echo "vertices_sha256=$vsha"
    echo "faces_sha256=$fsha"
    echo "hull_job_id=$SLURM_JOB_ID"
    echo "hull_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$SIDECAR.tmp"
mv -f "$SIDECAR.tmp" "$SIDECAR"

rm -rf "$RUNDIR/chunks"
mkdir -p "$RUNDIR/chunks"
echo "Chunks cleaned ($nlines boundary vertices verified and recorded)"

echo ""
echo "=== Done ==="
echo "Results in: $RESULTS"
