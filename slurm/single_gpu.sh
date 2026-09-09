#!/bin/bash
#SBATCH --job-name=mmb-single
#SBATCH --cpus-per-task=4
#SBATCH --mem=64000M
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
# Account, partition, GPU request and node exclusions come from
# config/cluster.sh through the sbatch command line in mmb_run.sh.

# slurm/single_gpu.sh  Single-GPU pipeline (Steps 2-3)
#
# Runs the CUDA kernel and hull computation for small/moderate jobs
# that fit on a single H100 GPU (< 10 min compute).
#
# Arguments: $1=RUNDIR (must contain generators_*.txt)
# All output stays in RUNDIR. Moves its own log files at the end.
#
# Check the staged kernel output before renaming it. The hull job checks
# the file again and writes the completion record used when resuming.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

RUNDIR=$1
SCRIPTDIR=$SLURM_SUBMIT_DIR

trap "rm -f \"$RUNDIR/.running\"" EXIT

echo "=== mmb-zonotope-tiling single-GPU ==="
echo "  Job ID:    $SLURM_JOB_ID"
echo "  Node:      $SLURM_NODELIST"
echo "  GPU:       $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "  Run dir:   $RUNDIR"
echo ""

# Clear inherited modules before loading the configured environment.
. "$SCRIPTDIR/config/cluster.sh"
module --force purge >/dev/null 2>&1 || module purge >/dev/null 2>&1 || true
module load $MMB_MODULES_GPU $MMB_MODULES_MATLAB

cd "$SCRIPTDIR"

# Build CUDA kernel if needed. Refuse to compute with a stale binary
if [ ! -x cuda/mmb_exact ]; then
    echo "--- Building CUDA kernel ---"
    make -C cuda NVCC_ARCH="$MMB_GPU_ARCH"
    echo ""
fi
if [ cuda/mmb_exact_cuda.cu -nt cuda/mmb_exact ]; then
    echo "ERROR: cuda/mmb_exact is STALE (older than its source). Rebuild via preflight before computing" >&2
    exit 1
fi

# Step 2: GPU kernel, staged, content-verified and atomically promoted per dataset_id
echo "--- Step 2: Running CUDA kernel ---"
DATASET_IDS=()
for f in "$RUNDIR"/generators_*.txt; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    dataset_id=${fname#generators_}
    dataset_id=${dataset_id%.txt}
    echo "  Processing: $fname"

    STAGE="$RUNDIR/.staging.mmb_${dataset_id}.${SLURM_JOB_ID}.txt"
    FINAL="$RUNDIR/mmb_${dataset_id}.txt"

    # --max-verts unified with the array route. Overflow is fatal either way
    ./cuda/mmb_exact --data "$f" --max-verts 200000000 --output "$STAGE"

    # Retry verification failures in case a filesystem read failed temporarily.
    vok=false
    for vtry in 1 2 3; do
        if bash "$SCRIPTDIR/tools/verify_chunk.sh" "$STAGE" --dataset-id "$dataset_id" --require-footer \
                --generators "$f"; then
            vok=true; break
        fi
        [ "$vtry" -lt 3 ] && sleep $((vtry * ${MMB_READ_RETRY_SLEEP:-10}))
    done
    if ! $vok; then
        mv -f "$STAGE" "${STAGE%.txt}.FAILED.txt" 2>/dev/null || true
        echo "ERROR: kernel output for $dataset_id failed content verification persistently. NOT promoted" >&2
        exit 1
    fi
    sync -d "$STAGE" 2>/dev/null || sync 2>/dev/null || true
    mv -f "$STAGE" "$FINAL"
    echo "  Promoted verified output: $FINAL"
    DATASET_IDS+=("$dataset_id")
done

if [ "${#DATASET_IDS[@]}" -eq 0 ]; then
    echo "ERROR: no dataset_id was processed (no generators_*.txt matched in $RUNDIR)" >&2
    exit 1
fi

# Build and check the hull through hull_job.sh, which also writes the
# .hull_verified record used by the launcher and collection driver.
echo ""
echo "--- Step 3: Computing convex hulls ---"
for dataset_id in "${DATASET_IDS[@]}"; do
    bash "$SCRIPTDIR/slurm/hull_job.sh" "$RUNDIR" "$dataset_id"
done

echo ""
echo "=== Done ==="
echo "Results in: $RUNDIR/results/"

# Move Slurm log files into the run output directory
mkdir -p "$RUNDIR/logs"
mv "$SLURM_SUBMIT_DIR/${SLURM_JOB_NAME}-${SLURM_JOB_ID}.out" "$RUNDIR/logs/" 2>/dev/null || true
mv "$SLURM_SUBMIT_DIR/${SLURM_JOB_NAME}-${SLURM_JOB_ID}.err" "$RUNDIR/logs/" 2>/dev/null || true
