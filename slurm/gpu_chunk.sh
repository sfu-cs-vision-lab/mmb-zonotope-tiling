#!/bin/bash
#SBATCH --job-name=mmb-chunk
#SBATCH --cpus-per-task=4
#SBATCH --mem=32000M
#SBATCH --time=01:00:00
# Account, partition, GPU request and node exclusions come from
# config/cluster.sh through the sbatch command line in mmb_run.sh.

# slurm/gpu_chunk.sh  Job array: one CUDA chunk per H100
#
# Each array task processes one chunk of the tile space on a single GPU.
# Log files are directed by the parent script to RUNDIR/logs/.
#
# Arguments: $1=DATAFILE $2=NCHUNKS $3=RUNDIR
#
# Write kernel output to a temporary staging file. Check its input hash,
# chunk index, row count and completion footer before renaming it to the
# result filename. Failed or interrupted work leaves no accepted chunk.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

DATAFILE=$1
NCHUNKS=$2
RUNDIR=$3
CHUNK=$SLURM_ARRAY_TASK_ID

echo "=== mmb-zonotope-tiling chunk $CHUNK/$NCHUNKS ==="
echo "  Job ID:    $SLURM_JOB_ID"
echo "  Array ID:  $SLURM_ARRAY_JOB_ID task $SLURM_ARRAY_TASK_ID"
echo "  Node:      $(hostname)"
echo "  Data:      $DATAFILE"
echo "  Run dir:   $RUNDIR"

# Clear inherited modules before loading the configured environment.
. "$SLURM_SUBMIT_DIR/config/cluster.sh"
module --force purge >/dev/null 2>&1 || module purge >/dev/null 2>&1 || true
module load $MMB_MODULES_GPU

cd "$SLURM_SUBMIT_DIR"

# Refuse a kernel binary older than its source. Build before submission
# so concurrent array tasks do not try to compile the same executable.
if [ ! -x cuda/mmb_exact ]; then
    echo "ERROR: cuda/mmb_exact missing. Run 'make -C cuda' (preflight) first" >&2
    exit 1
fi
if [ cuda/mmb_exact_cuda.cu -nt cuda/mmb_exact ]; then
    echo "ERROR: cuda/mmb_exact is STALE (older than its source). Rebuild via preflight before computing" >&2
    exit 1
fi

# Derive dataset_id from the generators filename so we can name the output explicitly.
# Pattern: generators_<dataset_id>.txt -> mmb_<dataset_id>_chunk<N>.txt
DATASET_ID=${DATAFILE#generators_}
DATASET_ID=${DATASET_ID%.txt}

if [ ! -f "$RUNDIR/$DATAFILE" ]; then
    echo "ERROR: generators file not found: $RUNDIR/$DATAFILE" >&2
    exit 1
fi

mkdir -p "$RUNDIR/chunks"
STAGE="$RUNDIR/chunks/.staging.mmb_${DATASET_ID}_chunk${CHUNK}.${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.txt"
FINAL="$RUNDIR/chunks/mmb_${DATASET_ID}_chunk${CHUNK}.txt"

# Kernel exits nonzero on overflow, MAX_VPTS, invalid input or write failure
# (set -e aborts here and the staging file is never promoted).
./cuda/mmb_exact --data "$RUNDIR/$DATAFILE" --chunk "$CHUNK" --nchunks "$NCHUNKS" \
    --max-verts 200000000 --output "$STAGE"

# Retry failed verification before rejecting a chunk. Shared-filesystem
# read errors can be temporary.
RETRY_SLEEP=${MMB_READ_RETRY_SLEEP:-10}
vok=false
for vtry in 1 2 3; do
    if bash "$SLURM_SUBMIT_DIR/tools/verify_chunk.sh" "$STAGE" \
            --dataset-id "$DATASET_ID" --chunk "$CHUNK" --nchunks "$NCHUNKS" --require-footer \
            --generators "$RUNDIR/$DATAFILE"; then
        vok=true; break
    fi
    [ "$vtry" -lt 3 ] && sleep $((vtry * RETRY_SLEEP))
done
if ! $vok; then
    mv -f "$STAGE" "${STAGE%.txt}.FAILED.txt" 2>/dev/null || true
    echo "ERROR: chunk $CHUNK failed content verification persistently. NOT promoted (kept as .FAILED for forensics)" >&2
    exit 1
fi

# Flush the staged file before renaming it. The hull job checks it again
# before using it.
sync -d "$STAGE" 2>/dev/null || sync 2>/dev/null || true
mv -f "$STAGE" "$FINAL"
echo "Promoted verified chunk: $FINAL"
