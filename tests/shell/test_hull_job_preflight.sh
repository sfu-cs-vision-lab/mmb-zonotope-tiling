#!/bin/bash
# tests/shell/test_hull_job_preflight.sh
# Test chunk checks, hull completion records and cleanup using substitute commands.

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
HJ="$SCRIPTDIR/slurm/hull_job.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_hulljob.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export MMB_READ_RETRY_SLEEP=0   # persistent-verdict retries, no backoff in tests
pass=0; failed=0
ok()   { pass=$((pass+1)); echo "  PASS: $1"; }
bad()  { failed=$((failed+1)); echo "  FAIL: $1"; }

# Stubs: `module` no-op, `matlab` produces plausible hullMMB output
mkdir -p "$TMP/bin"
cat > "$TMP/bin/module" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/bin/matlab" << 'EOF'
#!/bin/bash
# stub hullMMB: parse OutputDir and ExpectDatasetID from the -batch string and
# write a minimal consistent result triple of 4 vertices and tetra faces, or,
# with MMB_STUB_SHAPE=flat or unmarked, a 2-vertex segment with an empty
# faces file, with or without the summary's "Flat body:" line.
args="$*"
outdir=$(echo "$args" | sed -n "s/.*OutputDir='\([^']*\)'.*/\1/p")
dataset_id=$(echo "$args" | sed -n 's/.*ExpectDatasetID="\([^"]*\)".*/\1/p')
[ -n "$outdir" ] && [ -n "$dataset_id" ] || { echo "stub matlab: parse failure: $args" >&2; exit 1; }
mkdir -p "$outdir"
shape=${MMB_STUB_SHAPE:-tetra}
if [ "$shape" = tetra ]; then
  printf '0,0,0\n1,0,0\n0,1,0\n0,0,1\n' > "$outdir/mmb_${dataset_id}_vertices.csv"
  printf '1,2,3\n1,2,4\n1,3,4\n2,3,4\n' > "$outdir/mmb_${dataset_id}_faces.csv"
  nv=4; nf=4; vol=1.666666666666667e-01
else
  printf '0,0,0\n1,0,0\n' > "$outdir/mmb_${dataset_id}_vertices.csv"
  : > "$outdir/mmb_${dataset_id}_faces.csv"
  nv=2; nf=0; vol=0.000000000000000e+00
fi
{
  echo "% MMB vertices from CUDA kernel"
  echo "% Input: /x/generators_${dataset_id}.txt"
  echo "Boundary vertices: $nv"
  echo "Boundary faces:    $nf"
  [ "$shape" = flat ] && echo "Flat body:         width along a principal axis <= 1e-8 of the largest coordinate, volume 0, no faces"
  echo "Hull volume:       $vol"
  echo "% vertices_sha256=stubsha_v"
  echo "% faces_sha256=stubsha_f"
} > "$outdir/mmb_${dataset_id}_summary.txt"
exit 0
EOF
chmod +x "$TMP/bin/module" "$TMP/bin/matlab"
export PATH="$TMP/bin:$PATH"
# An environment module system reaches these tests two ways. It exports
# `module` as a shell function, and BASH_ENV makes every non-interactive
# shell re-define it. A function takes precedence over the stub on PATH.
# Close both so the stubbed command is used on a cluster login node too.
unset -f module 2>/dev/null || true
unset BASH_ENV
export SLURM_JOB_ID=999
export SLURM_SUBMIT_DIR="$SCRIPTDIR"

S="1931_2deg_D65_A_10nm_refl50"

# canonical payload-sha convention (matches prepareGenerators / verify_chunk)
payload_sha() {
    if command -v sha256sum >/dev/null 2>&1; then local H="sha256sum"; else local H="shasum -a 256"; fi
    awk '!/^[[:space:]]*%/ && NF>0 {if(n++)printf "\n"; printf "%s",$0}' "$1" | $H | awk '{print $1}'
}

make_generators() {  # PATH  -> writes a minimal generators file and echoes its payload sha
    { echo "% test generators file"; echo "3"; echo "1.0 2.0 3.0"; echo "400.0 1 1 1 1 1 1"; echo "410.0 1 1 1 1 1 1"; echo "420.0 1 1 1 1 1 1"; } > "$1"
    payload_sha "$1"
}

make_chunk() {  # PATH DATASET_ID CHUNK NCHUNKS NV SHA
    local path=$1 dataset_id=$2 chunk=$3 nchunks=$4 nv=$5 sha=$6 i
    {
        echo "% MMB vertices from CUDA kernel"
        echo "% Input: /x/runs_output/${dataset_id}/generators_${dataset_id}.txt"
        echo "% payload_sha256=${sha}"
        echo "% n=40, tiles_total=100, tiles_tested=50, tiles_intersecting=9, vertices=${nv}"
        echo "% chunk=${chunk}, nchunks=${nchunks}"
        for i in $(seq 1 "$nv"); do echo "1.$i 2.$i 3.$i"; done
        echo "% complete vertices=${nv}"
    } > "$path"
}

fresh_rundir() {  # NCHUNKS_PRESENT NCHUNKS_TOTAL -> writes generators file + chunks
    local present=$1 total=$2 sha
    RD="$TMP/run_$RANDOM"
    mkdir -p "$RD/chunks" "$RD/results"
    sha=$(make_generators "$RD/generators_${S}.txt")
    for (( i=0; i<present; i++ )); do
        make_chunk "$RD/chunks/mmb_${S}_chunk${i}.txt" "$S" "$i" "$total" 5 "$sha"
    done
    echo "$RD"
}

# 1. Complete verified set -> hull runs, sidecar written, chunks deleted
RD=$(fresh_rundir 3 3)
if bash "$HJ" "$RD" "$S" > "$TMP/log1" 2>&1; then
    [ -f "$RD/results/.hull_verified" ] && ok "sidecar written on success" || bad "sidecar written on success"
    n=$(find "$RD/chunks" -name 'mmb_*' | wc -l | tr -d ' ')
    [ "$n" -eq 0 ] && ok "chunks deleted after record" || bad "chunks deleted after record"
    grep -q "nchunks=3" "$RD/results/.hull_verified" && ok "sidecar records N" || bad "sidecar records N"
else
    bad "complete set hulls successfully (see $TMP/log1)"; sed -n '1,20p' "$TMP/log1"
fi

# 2. Missing chunk -> refuse, chunks preserved, no results
RD=$(fresh_rundir 2 3)
if bash "$HJ" "$RD" "$S" > "$TMP/log2" 2>&1; then
    bad "incomplete set refused"
else
    grep -q "missing chunk" "$TMP/log2" && ok "incomplete set refused" || bad "incomplete set refused (wrong reason)"
    [ -f "$RD/chunks/mmb_${S}_chunk0.txt" ] && ok "chunks preserved on refusal" || bad "chunks preserved on refusal"
    [ ! -f "$RD/results/mmb_${S}_summary.txt" ] && ok "no results on refusal" || bad "no results on refusal"
fi

# 3. A chunk named for another dataset prevents the merge
RD=$(fresh_rundir 3 3)
make_chunk "$RD/chunks/mmb_other_dataset_chunk1.txt" "other_dataset" 1 3 5 "$(payload_sha "$RD/generators_${S}.txt")"
if bash "$HJ" "$RD" "$S" > "$TMP/log3" 2>&1; then
    bad "chunk from another dataset refused"
else
    grep -q "file from another dataset" "$TMP/log3" && ok "chunk from another dataset refused" || bad "chunk from another dataset refused (wrong reason)"
fi

# 4. Truncated chunk -> quarantined and reported missing, so the
#    resubmission path recomputes it instead of livelocking
RD=$(fresh_rundir 3 3)
head -n 8 "$RD/chunks/mmb_${S}_chunk1.txt" > "$RD/chunks/mmb_${S}_chunk1.txt.t" \
    && mv "$RD/chunks/mmb_${S}_chunk1.txt.t" "$RD/chunks/mmb_${S}_chunk1.txt"
if bash "$HJ" "$RD" "$S" > "$TMP/log4" 2>&1; then
    bad "truncated chunk refused"
else
    grep -q "QUARANTINED chunk 1" "$TMP/log4" && ok "truncated chunk quarantined" || bad "truncated chunk quarantined"
    [ ! -f "$RD/chunks/mmb_${S}_chunk1.txt" ] && ok "damaged canonical name removed" || bad "damaged canonical name removed"
    ls "$RD/chunks/".staging.REJECTED.* >/dev/null 2>&1 && ok "quarantine file kept for forensics" || bad "quarantine file kept for forensics"
    grep -q "missing chunk(s) 1" "$TMP/log4" && ok "quarantined chunk reported missing (auto-recompute)" || bad "quarantined chunk reported missing"
fi

# 4b. Generation mismatch: chunk computed from a different
#     generators file payload -> quarantined, never merged
RD=$(fresh_rundir 3 3)
make_chunk "$RD/chunks/mmb_${S}_chunk1.txt" "$S" 1 3 5 "0000000000000000000000000000000000000000000000000000000000000000"
if bash "$HJ" "$RD" "$S" > "$TMP/log4b" 2>&1; then
    bad "stale-generation chunk refused"
else
    grep -q "GENERATION MISMATCH" "$TMP/log4b" && ok "stale-generation chunk detected by payload sha" || bad "stale-generation chunk detected"
    grep -q "QUARANTINED chunk 1" "$TMP/log4b" && ok "stale-generation chunk quarantined" || bad "stale-generation chunk quarantined"
fi

# 4c. Generators file missing entirely -> refuse (cannot verify generation)
RD=$(fresh_rundir 3 3)
rm -f "$RD/generators_${S}.txt"
if bash "$HJ" "$RD" "$S" > "$TMP/log4c" 2>&1; then
    bad "missing generators file refused"
else
    grep -q "generators file missing" "$TMP/log4c" && ok "missing generators file refused" || bad "missing generators file refused (wrong reason)"
fi

# 5. Header/.nchunks disagreement -> refuse
RD=$(fresh_rundir 3 3)
echo 5 > "$RD/.nchunks"
if bash "$HJ" "$RD" "$S" > "$TMP/log5" 2>&1; then
    bad "nchunks disagreement refused"
else
    grep -q ".nchunks says 5" "$TMP/log5" && ok "nchunks disagreement refused" || bad "nchunks disagreement refused (wrong reason)"
fi

# 6. Verified results present -> skip without touching anything
RD=$(fresh_rundir 3 3)
bash "$HJ" "$RD" "$S" > /dev/null 2>&1
before=$(cat "$RD/results/.hull_verified")
if bash "$HJ" "$RD" "$S" > "$TMP/log6" 2>&1; then
    grep -q "skipping hull" "$TMP/log6" && ok "verified results skipped" || bad "verified results skipped"
    after=$(cat "$RD/results/.hull_verified")
    [ "$before" = "$after" ] && ok "skip does not modify record" || bad "skip does not modify record"
else
    bad "skip path exits 0"
fi

# 7. Results WITHOUT sidecar -> treated as suspect, recomputed
RD=$(fresh_rundir 3 3)
mkdir -p "$RD/results"
echo "junk" > "$RD/results/mmb_${S}_vertices.csv"
echo "junk" > "$RD/results/mmb_${S}_summary.txt"
if bash "$HJ" "$RD" "$S" > "$TMP/log7" 2>&1; then
    grep -q "Boundary vertices: 4" "$RD/results/mmb_${S}_summary.txt" \
        && ok "unverified results recomputed" || bad "unverified results recomputed"
else
    bad "unverified-results path recomputes (see $TMP/log7)"
fi

# 8. Flat body: an empty faces file and 2 vertices, allowed by the Flat body line
RD=$(fresh_rundir 3 3)
if MMB_STUB_SHAPE=flat bash "$HJ" "$RD" "$S" > "$TMP/log8" 2>&1; then
    [ -f "$RD/results/.hull_verified" ] && ok "flat body recorded" || bad "flat body recorded"
    grep -q "boundary_vertices=2" "$RD/results/.hull_verified" && ok "flat body record has its 2 vertices" || bad "flat body record has its 2 vertices"
else
    bad "flat body accepted (see $TMP/log8)"; sed -n '1,20p' "$TMP/log8"
fi

# 9. The same output without the Flat body line -> refused, chunks kept
RD=$(fresh_rundir 3 3)
if MMB_STUB_SHAPE=unmarked bash "$HJ" "$RD" "$S" > "$TMP/log9" 2>&1; then
    bad "empty faces file without the Flat body line refused"
else
    grep -q "hull output missing or empty" "$TMP/log9" && ok "empty faces file without the Flat body line refused" \
        || bad "empty faces file without the Flat body line refused (wrong reason)"
    [ -f "$RD/chunks/mmb_${S}_chunk0.txt" ] && ok "chunks preserved on refusal" || bad "chunks preserved on refusal"
fi

echo "== read_retry: transient faults retried, persistent ones reported =="
eval "$(sed -n '/^read_retry()/,/^}/p' "$SCRIPTDIR/slurm/hull_job.sh")"
RETRY_SLEEP=0
FLAKY_STATE="$TMP/flaky.n"
flaky() {  # fails twice, then echoes OK
    n=$(cat "$FLAKY_STATE" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FLAKY_STATE"
    [ "$n" -ge 3 ] && { echo "OK"; return 0; }
    return 1
}
rm -f "$FLAKY_STATE"
out=$(read_retry flaky)
[ "$out" = "OK" ] && ok "transient read fault survived by retry" || bad "transient retry"
if read_retry false >/dev/null; then bad "persistent fault must fail"; else ok "persistent read fault still fails after retries"; fi

echo ""
echo "hull_job preflight: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
