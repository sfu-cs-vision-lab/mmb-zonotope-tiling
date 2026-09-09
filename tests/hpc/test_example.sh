#!/bin/bash
# tests/hpc/test_example.sh  Run and check the 10 nm example on a GPU node.
#
# Build the kernel and run input generation, chunked enumeration, hull
# construction and validation. Also exercise the single-GPU job script.
# Compare the volume with 1.6197295874216849e+02 at 1e-12 relative tolerance.
# The reference was obtained independently.
#
# Usage: bash tests/hpc/test_example.sh
# Exit 0 if every check passes.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
cd "$SCRIPTDIR"

DATASET_ID="1931_2deg_D65_A_10nm_refl50"
REFERENCE_VOLUME="1.6197295874216849e+02"
WORK=$(mktemp -d "$SCRIPTDIR/.example.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

. "$SCRIPTDIR/config/cluster.sh"
module load $MMB_MODULES_GPU $MMB_MODULES_MATLAB

echo "example: build"
make -C cuda NVCC_ARCH="$MMB_GPU_ARCH"

echo "example: CIE inputs"
bash tools/check_data_hashes.sh

echo "example: generators file (normalized)"
matlab -batch "addpath('src'); prepareGenerators(\"1931_2deg\",\"D65\",\"A\",Spacing=10,Refl=0.5,DataDir=\"data\",OutputDir=\"$WORK\")"

echo "example: kernel (chunked 3 ways to exercise the array path)"
for k in 0 1 2; do
    STAGE="$WORK/.staging.mmb_${DATASET_ID}_chunk${k}.txt"
    ./cuda/mmb_exact --data "$WORK/generators_${DATASET_ID}.txt" \
        --chunk "$k" --nchunks 3 --max-verts 200000000 --output "$STAGE"
    bash tools/verify_chunk.sh "$STAGE" --dataset-id "$DATASET_ID" --chunk "$k" --nchunks 3 --require-footer \
        --generators "$WORK/generators_${DATASET_ID}.txt"
    mv -f "$STAGE" "$WORK/mmb_${DATASET_ID}_chunk${k}.txt"
done

echo "example: hull (content-verified merge)"
matlab -batch "addpath('src'); hullMMB([\"$WORK/mmb_${DATASET_ID}_chunk0.txt\",\"$WORK/mmb_${DATASET_ID}_chunk1.txt\",\"$WORK/mmb_${DATASET_ID}_chunk2.txt\"], OutputDir=\"$WORK/results\", ExpectDatasetID=\"$DATASET_ID\")"

echo "example: single-GPU route end-to-end (slurm/single_gpu.sh)"
# Run the single-GPU job script and check its completion record.
SGL="$WORK/sglrun/$DATASET_ID"
mkdir -p "$SGL"
cp "$WORK/generators_${DATASET_ID}.txt" "$SGL/"
SLURM_JOB_ID="example$$" SLURM_JOB_NAME="example-single" SLURM_NODELIST="$(hostname)" \
    SLURM_SUBMIT_DIR="$SCRIPTDIR" bash slurm/single_gpu.sh "$SGL"
if [ ! -f "$SGL/results/.hull_verified" ]; then
    echo "FAIL: single-GPU route produced no verified record" >&2
    exit 1
fi
echo "single-GPU route verified: $(grep '^boundary_vertices=' "$SGL/results/.hull_verified")"

echo "example: validation (provenance + LP feasibility + volume recompute)"
# Validate the single-GPU result against its generators file.
matlab -batch "addpath('src'); r = validateDataset(\"$SGL\", Sample=256); exit(double(string(r.result) ~= \"PASS\"))"

echo "example: volume vs reference"
vol=$(awk '/^Hull volume:/{print $NF; exit}' "$SGL/results/mmb_${DATASET_ID}_summary.txt")
python3 - "$vol" "$REFERENCE_VOLUME" << 'EOF'
import sys
vol, reference = float(sys.argv[1]), float(sys.argv[2])
rel = abs(vol - reference) / reference
print(f"volume {vol:.15e} vs reference {reference:.15e}: rel {rel:.3e}")
# Require agreement with the reference within 1e-12 relative tolerance.
sys.exit(0 if rel <= 1e-12 else 1)
EOF

echo ""
echo "EXAMPLE TEST PASS. On this GPU and toolchain:"
echo "  - the kernel compiles and runs clean"
echo "  - chunked kernel output passes content verification and promotes"
echo "  - the single-GPU route runs end-to-end through slurm/single_gpu.sh"
echo "    (kernel -> verify -> promote -> hull_job -> .hull_verified record)"
echo "  - dataset validation passes for the result"
echo "  - the volume matches the reference value to <= 1e-12"
mkdir -p "$SCRIPTDIR/.checks"
{ echo "source_id=$(bash "$SCRIPTDIR/tools/source_id.sh")"; echo "date=$(date -u +%FT%TZ)"; echo "check=example"; } \
    > "$SCRIPTDIR/.checks/example.PASS"
echo "Check result written: .checks/example.PASS"
