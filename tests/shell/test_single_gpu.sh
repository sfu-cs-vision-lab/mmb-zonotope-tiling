#!/bin/bash
# tests/shell/test_single_gpu.sh
# Test the single-GPU job script using simulated cluster and kernel commands.

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_sgl.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export MMB_READ_RETRY_SLEEP=0
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failed=$((failed+1)); echo "  FAIL: $1"; }

# temp repo copy (single_gpu resolves tools/, slurm/, cuda/ from CWD)
WORK="$TMP/repo"
mkdir -p "$WORK/slurm" "$WORK/tools" "$WORK/src" "$WORK/cuda" "$WORK/config"
cp "$SCRIPTDIR/config/cluster.sh" "$WORK/config/"
cp "$SCRIPTDIR"/slurm/single_gpu.sh "$SCRIPTDIR"/slurm/hull_job.sh "$WORK/slurm/"
cp "$SCRIPTDIR"/tools/verify_chunk.sh "$WORK/tools/"

# stub kernel: reads the generator/generators file, echoes its comment lines
# (so payload_sha256 rides along, as the real kernel does), writes a valid
# kernel-format output to --output. KERNEL_TRUNCATE=1 simulates a kill/quota
# mid-write (short body, no footer).
cat > "$WORK/cuda/mmb_exact" << 'EOF'
#!/bin/bash
data=""; out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --data) data=$2; shift 2 ;;
        --output) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
{
    echo "% MMB vertices from CUDA kernel"
    echo "% Input: $data"
    grep '^%' "$data"
    echo "% n=40, tiles_total=100, tiles_tested=100, tiles_intersecting=9, vertices=5"
    echo "% gpu_seconds=0.01"
    if [ "${KERNEL_TRUNCATE:-0}" = "1" ]; then
        echo "1.0 2.0 3.0"
        echo "1.5 2.5"
    else
        for i in 1 2 3 4 5; do echo "1.$i 2.$i 3.$i"; done
        echo "% complete vertices=5"
    fi
} > "$out"
echo "  Vertices collected: 5"
EOF
chmod +x "$WORK/cuda/mmb_exact"
touch -t 202601010000 "$WORK/cuda/mmb_exact_cuda.cu"   # older than the stub binary

mkdir -p "$TMP/bin"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/module"
printf '#!/bin/bash\necho H100-stub\n' > "$TMP/bin/nvidia-smi"
cat > "$TMP/bin/matlab" << 'EOF'
#!/bin/bash
args="$*"
outdir=$(echo "$args" | sed -n "s/.*OutputDir='\([^']*\)'.*/\1/p")
dataset_id=$(echo "$args" | sed -n 's/.*ExpectDatasetID="\([^"]*\)".*/\1/p')
[ -n "$outdir" ] && [ -n "$dataset_id" ] || { echo "stub matlab parse failure: $args" >&2; exit 1; }
mkdir -p "$outdir"
printf '1,2,3\n4,5,6\n7,8,9\n2,4,6\n8,7,5\n' > "$outdir/mmb_${dataset_id}_vertices.csv"
printf '1,2,3\n1,2,4\n1,3,4\n2,3,4\n1,2,5\n3,4,5\n' > "$outdir/mmb_${dataset_id}_faces.csv"
{
  echo "% MMB vertices from CUDA kernel"
  echo "% Input: /x/generators_${dataset_id}.txt"
  echo "Boundary vertices: 5"
  echo "Boundary faces:    6"
  echo "Hull volume:       1.0e+00"
  echo "% vertices_sha256=stub_v"
  echo "% faces_sha256=stub_f"
} > "$outdir/mmb_${dataset_id}_summary.txt"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
# An environment module system reaches these tests two ways. It exports
# `module` as a shell function, and BASH_ENV makes every non-interactive
# shell re-define it. A function takes precedence over the stub on PATH.
# Close both so the stubbed command is used on a cluster login node too.
unset -f module 2>/dev/null || true
unset BASH_ENV
export SLURM_JOB_ID=777
export SLURM_JOB_NAME=mmb-single-test
export SLURM_NODELIST=stub-node
export SLURM_SUBMIT_DIR="$WORK"

S="1931_2deg_D65_A_10nm_refl50"
if command -v sha256sum >/dev/null 2>&1; then H="sha256sum"; else H="shasum -a 256"; fi

make_rundir() {
    RD="$WORK/runs_output/$S"
    rm -rf "$RD"; mkdir -p "$RD"
    { echo "% test generators"; echo "3"; echo "1.0 2.0 3.0"; echo "400.0 1 1 1 1 1 1"; } > "$RD/generators_$S.txt"
    sha=$(awk '!/^[[:space:]]*%/ && NF>0 {if(n++)printf "\n"; printf "%s",$0}' "$RD/generators_$S.txt" | $H | awk '{print $1}')
    sed -i.bak "1a\\
% payload_sha256=$sha" "$RD/generators_$S.txt" && rm -f "$RD/generators_$S.txt.bak"
    echo "$RD"
}

echo "== single_gpu end-to-end (normal run) =="
RD=$(make_rundir)
if (cd "$WORK" && bash slurm/single_gpu.sh "$RD" > "$TMP/log1" 2>&1); then
    ok "exits 0"
    [ -f "$RD/mmb_${S}.txt" ] && ok "kernel output promoted to canonical name" || bad "promotion"
    [ -f "$RD/results/mmb_${S}_summary.txt" ] && ok "hull results written" || bad "hull results"
    [ -f "$RD/results/.hull_verified" ] && ok "verified record written (dataset_id can be marked done)" || bad "verified record"
else
    bad "exits 0 (see log)"; tail -15 "$TMP/log1"
fi

echo "== single_gpu: kill/quota-truncated kernel output =="
RD=$(make_rundir)
if (cd "$WORK" && KERNEL_TRUNCATE=1 bash slurm/single_gpu.sh "$RD" > "$TMP/log2" 2>&1); then
    bad "truncated output must not pass"
else
    ok "truncated output fails the job"
    ls "$RD"/.staging.*.FAILED.txt >/dev/null 2>&1 && ok "partial kept as .FAILED, never promoted" || bad ".FAILED forensic file"
    [ ! -f "$RD/mmb_${S}.txt" ] && ok "no canonical file from a bad write" || bad "canonical file exists"
    [ ! -f "$RD/results/.hull_verified" ] && ok "no verified record" || bad "verified record exists"
fi

echo "== single_gpu: empty rundir =="
RD="$WORK/runs_output/empty"; rm -rf "$RD"; mkdir -p "$RD"
if (cd "$WORK" && bash slurm/single_gpu.sh "$RD" > "$TMP/log3" 2>&1); then
    bad "empty rundir must fail"
else
    grep -q "no dataset_id was processed" "$TMP/log3" && ok "empty rundir fails with honest message" || bad "error message"
fi

echo ""
echo "single_gpu route: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
