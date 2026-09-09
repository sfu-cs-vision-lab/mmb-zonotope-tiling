#!/bin/bash
# tools/regenerate_datasets.sh  Run and check the datasets in runs/dataset_ids.txt.
#
# Calls mmb_run.sh and limits the number of datasets in progress. Completed
# datasets are skipped and interrupted jobs can be resumed by running submit
# again. Peak scratch usage depends on --max-datasets and the chunk file sizes.
# See docs/HPC_GUIDE.md for setup and the full procedure.
#
# Subcommands:
#   preflight                 Check inputs, environment, build and saved checks.
#   submit [--max-datasets N] Submit work, with at most N datasets in progress.
#   status                    Show collection progress.
#   check-files               Check dataset filenames and input identity.
#   validate [--sample N]     Validate results and write certificates.
#   check-inputs              Compare regenerated inputs with STORED_ROOT.
#   restamp [--force C R]     Update saved checks after reviewing source changes.
#   redo <dataset_id> --yes   Delete and recompute one dataset's outputs.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$SCRIPTDIR"
. "$SCRIPTDIR/config/cluster.sh"
. "$SCRIPTDIR/tools/slurm_jobs.sh"
DATASET_IDS_FILE="$SCRIPTDIR/runs/dataset_ids.txt"
RUNS_FILE="runs/runs_all_datasets.m"
case "$MMB_OUTPUT_ROOT" in
    /*) ROOT=$MMB_OUTPUT_ROOT ;;
    *)  ROOT=$SCRIPTDIR/$MMB_OUTPUT_ROOT ;;
esac

# Identity of the source tree, used to bind saved check results to the code that
# passed them. Works in a Git checkout and in an extracted release archive.
source_id() { bash "$SCRIPTDIR/tools/source_id.sh"; }
have_git() {
    local git_root
    command -v git >/dev/null 2>&1 &&
        git_root=$(git rev-parse --show-toplevel 2>/dev/null) &&
        [ "$git_root" -ef "$SCRIPTDIR" ]
}

[ -f "$DATASET_IDS_FILE" ] || { echo "ERROR: $DATASET_IDS_FILE missing" >&2; exit 1; }

cmd=${1:-}
shift || true

dataset_done() {  # verified hull results present
    local s=$1
    [ -f "$ROOT/$s/results/mmb_${s}_vertices.csv" ] && \
    [ -f "$ROOT/$s/results/mmb_${s}_summary.txt" ] && \
    [ -f "$ROOT/$s/results/.hull_verified" ]
}

dataset_inflight() {
    [ -f "$ROOT/$1/.running" ]
}

# Submission requires a passing record for each check and the current source.
# The restamp command compares changed files with the files covered by each
# check. An explicit override records the reason supplied by the user.
CHECKS=(example determinism interruption check-inputs)
checks_ok() {
    local now g f c missing=""
    now=$(source_id)
    for g in "${CHECKS[@]}"; do
        f="$SCRIPTDIR/.checks/$g.PASS"
        if [ ! -f "$f" ]; then
            missing="$missing $g(not-run)"
            continue
        fi
        c=$(sed -n 's/^source_id=//p' "$f")
        if [ "$c" != "$now" ]; then
            missing="$missing $g(stale)"
        fi
    done
    if [ -n "$missing" ]; then
        echo "checks not passed for source $now:$missing" >&2
        echo "Run the checks listed by '$0 preflight'. Each writes .checks/<name>.PASS on success." >&2
        return 1
    fi
    return 0
}

case "$cmd" in

preflight)
    echo "regen preflight"
    bash tools/check_data_hashes.sh
    echo "datasets listed: $(grep -c . "$DATASET_IDS_FILE")"
    echo "source id: $(source_id)"
    module load $MMB_MODULES_GPU $MMB_MODULES_MATLAB 2>/dev/null || true
    bash tools/check_env.sh || exit 1
    make -C cuda NVCC_ARCH="$MMB_GPU_ARCH"
    echo ""
    echo "Saved check results for this source:"
    for g in "${CHECKS[@]}"; do
        f="$SCRIPTDIR/.checks/$g.PASS"
        if [ -f "$f" ] && [ "$(sed -n 's/^source_id=//p' "$f")" = "$(source_id)" ]; then
            echo "  [PASS]    $g ($(sed -n 's/^date=//p' "$f"))"
        elif [ -f "$f" ]; then
            echo "  [STALE]   $g (passed on $(sed -n 's/^source_id=//p' "$f"), re-run on this source)"
        else
            echo "  [NOT RUN] $g"
        fi
    done
    echo ""
    echo "Preflight OK. 'submit' refuses until all four checks PASS on this source:"
    echo "  1. bash tests/hpc/test_example.sh                     (GPU node)"
    echo "  2. bash tests/hpc/test_determinism.sh               (GPU node)"
    echo "  3. bash tools/regenerate_datasets.sh check-inputs (login node)"
    echo "  4. bash tests/hpc/test_interruption.sh              (login node, before the collection run)"
    ;;

submit)
    MAX_DATASETS=8
    PARTITION=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-datasets) MAX_DATASETS=$2; shift 2 ;;
            --partition) PARTITION=$2; shift 2 ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
    done

    checks_ok || exit 1

    # Clear locks left by failed array jobs and cancel hull jobs whose
    # dependencies cannot be satisfied. The launcher then retries missing
    # chunks. A hull job that starts clears its own lock on exit.
    sq=$(mmb_squeue "$(mmb_job_tag "$ROOT")" "%.30i %.200j %.20T %.40r") || exit 1
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        [ -f "$ROOT/$s/.running" ] || continue
        jobs=$(echo "$sq" | awk -v m="mmb-$s" -v h="hull-$s" '$2==m || $2==h')
        zombies=$(echo "$jobs" | awk '$3=="PENDING" && $4=="DependencyNeverSatisfied" {print $1}')
        if [ -n "$zombies" ]; then
            for j in $zombies; do scancel "$j" 2>/dev/null || true; done
            jobs=$(echo "$jobs" | awk '$3!="PENDING" || $4!="DependencyNeverSatisfied"')
        fi
        if [ -z "$(echo "$jobs" | tr -d '[:space:]')" ]; then
            rm -f "$ROOT/$s/.running"
            echo "self-heal: cleared stale lock for $s (no live jobs, so the resubmission path will redo it)"
        fi
    done < "$DATASET_IDS_FILE"

    inflight=0
    declare -a batch=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if dataset_done "$s"; then continue; fi
        if dataset_inflight "$s"; then inflight=$((inflight + 1)); continue; fi
        batch+=("$s")
    done < "$DATASET_IDS_FILE"

    room=$((MAX_DATASETS - inflight))
    if [ "$room" -le 0 ]; then
        echo "In flight: $inflight >= cap $MAX_DATASETS. Nothing submitted. Re-invoke later."
        exit 0
    fi
    if [ "${#batch[@]}" -eq 0 ]; then
        echo "No pending datasets. In flight: $inflight. If that is 0, run: $0 validate"
        exit 0
    fi
    n=$(( ${#batch[@]} < room ? ${#batch[@]} : room ))
    echo "In flight: $inflight. Submitting $n of ${#batch[@]} pending (cap $MAX_DATASETS)"

    # Anchored, dot-escaped alternation over exactly this batch. One
    # mmb_run.sh invocation generates generators file in its private prep dir and
    # routes/submits only the matching datasets (fresh, hull-retry or partial
    # chunk resubmission, as its content-verified state machine decides).
    filter="^($(printf '%s|' "${batch[@]:0:$n}" | sed 's/\./\\./g; s/|$//'))\$"
    bash mmb_run.sh ${PARTITION:+--partition "$PARTITION"} --filter "$filter" "$RUNS_FILE"
    ;;

status)
    total=0; done_n=0; run_n=0; pend_n=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        total=$((total + 1))
        if dataset_done "$s"; then done_n=$((done_n + 1));
        elif dataset_inflight "$s"; then run_n=$((run_n + 1));
        else pend_n=$((pend_n + 1)); fi
    done < "$DATASET_IDS_FILE"
    echo "collection: $done_n verified-done, $run_n in flight, $pend_n pending, of $total"
    echo "(details: bash mmb_run.sh --status)"
    ;;

check-files)
    bash tools/check_dataset_files.sh --root "$ROOT" --allow-missing
    ;;

validate)
    SAMPLE=1024
    while [ $# -gt 0 ]; do
        case "$1" in
            --sample) SAMPLE=$2; shift 2 ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
    done
    module load $MMB_MODULES_MATLAB 2>/dev/null || true
    matlab -batch "addpath('src'); cert = validateCollection('$ROOT', '$DATASET_IDS_FILE', Sample=$SAMPLE); exit(double(string(cert.result) ~= \"PASS\"))"
    ;;


restamp)
    # Compare changes since each saved check with the files that check covers.
    # Update the source identifier only if those files are unchanged. An explicit
    # override records the reason supplied by the user.
    if ! have_git; then
        echo "restamp needs Git history and this is not a Git checkout." >&2
        echo "In an extracted release archive, re-run the checks instead." >&2
        exit 1
    fi
    FORCE_CHECK=""
    FORCE_REASON=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE_CHECK=$2; FORCE_REASON=${3:?"--force <check> \"<reason>\""}; shift 3 ;;
            *) echo "unknown option: $1" >&2; exit 1 ;;
        esac
    done
    if [ -n "$FORCE_CHECK" ]; then
        case " ${CHECKS[*]} " in
            *" $FORCE_CHECK "*) ;;
            *) echo "ERROR: unknown check '$FORCE_CHECK' (checks: ${CHECKS[*]})" >&2; exit 1 ;;
        esac
    fi
    checked_paths() {
        case "$1" in
            example)              echo "cuda/ data/ src/ slurm/single_gpu.sh slurm/hull_job.sh tools/verify_chunk.sh tests/hpc/test_example.sh tools/check_data_hashes.sh" ;;
            determinism)        echo "cuda/ data/ src/prepareGenerators.m tools/verify_chunk.sh tests/hpc/test_determinism.sh tools/check_data_hashes.sh" ;;
            interruption)       echo "cuda/ data/ mmb_run.sh slurm/ src/ tools/slurm_jobs.sh tools/verify_chunk.sh tests/hpc/test_interruption.sh" ;;
            check-inputs) echo "data/ runs/dataset_ids.txt src/prepareGenerators.m src/compareReference.m tools/check_data_hashes.sh tools/regenerate_datasets.sh" ;;
        esac
    }
    head=$(git rev-parse HEAD)
    for g in "${CHECKS[@]}"; do
        f="$SCRIPTDIR/.checks/$g.PASS"
        if [ ! -f "$f" ]; then
            echo "  [NOT RUN] $g: no stamp. Run the check"
            continue
        fi
        base=$(sed -n 's/^source_id=git://p' "$f" | head -1)
        base=${base%+dirty}
        if [ -z "$base" ]; then
            echo "  [RE-RUN]  $g: stamp does not record a Git commit. Re-run the check"
            continue
        fi
        if [ "$base" = "$head" ]; then
            echo "  [OK]      $g already records HEAD"
            continue
        fi
        if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
            echo "  [RE-RUN]  $g: stamp commit '$base' unknown to this clone. Cannot verify the diff"
            continue
        fi
        changed=$(git diff --name-only "$base" "$head")
        hits=""
        for pfx in $(checked_paths "$g"); do
            h=$(echo "$changed" | grep -E "^${pfx}" || true)
            [ -n "$h" ] && hits="${hits}${h}
"
        done
        hits=$(echo "$hits" | grep . || true)
        if [ -z "$hits" ]; then
            sed -i.bak "s/^source_id=.*/source_id=git:$head/" "$f" && rm -f "$f.bak"
            {
                echo "restamped=auto date=$(date -u +%FT%TZ) from=$base"
                echo "restamp_basis=no checked-file change across $(echo "$changed" | grep -c .) changed file(s)"
            } >> "$f"
            echo "  [RESTAMP] $g $(echo "$base" | cut -c1-8) -> $(echo "$head" | cut -c1-8) (files covered by this check untouched)"
        elif [ "$FORCE_CHECK" = "$g" ]; then
            sed -i.bak "s/^source_id=.*/source_id=git:$head/" "$f" && rm -f "$f.bak"
            {
                echo "restamped=forced date=$(date -u +%FT%TZ) from=$base"
                echo "restamp_reason=$FORCE_REASON"
                echo "restamp_checked_files_changed=$(echo "$hits" | grep -c .)"
            } >> "$f"
            echo "  [FORCED]  $g $(echo "$base" | cut -c1-8) -> $(echo "$head" | cut -c1-8): $FORCE_REASON"
        else
            echo "  [RE-RUN]  $g: files covered by this check changed since $(echo "$base" | cut -c1-8):"
            echo "$hits" | sed 's/^/              /'
        fi
    done
    ;;

check-inputs)
    # Use an explicit reference directory so the comparison has a known input.
    total=$(grep -c . "$DATASET_IDS_FILE")
    if [ -z "${STORED_ROOT:-}" ]; then
        echo "ERROR: set STORED_ROOT to the extracted mmb-data/data directory." >&2
        exit 1
    fi
    [ -d "$STORED_ROOT" ] || { echo "ERROR: STORED_ROOT '$STORED_ROOT' not found" >&2; exit 1; }
    cov=0
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        [ ! -f "$STORED_ROOT/$s/generators_${s}.txt" ] || cov=$((cov + 1))
    done < "$DATASET_IDS_FILE"
    if [ "$cov" -ne "$total" ]; then
        echo "ERROR: STORED_ROOT holds inputs for $cov/$total datasets. A complete reference is required." >&2
        exit 1
    fi
    echo "Input reference: $STORED_ROOT"
    module load $MMB_MODULES_MATLAB 2>/dev/null || true
    if matlab -batch "addpath('src'); r = compareReference('inputs', '$STORED_ROOT', '$DATASET_IDS_FILE'); exit(double(~r.pass))"; then
        mkdir -p "$SCRIPTDIR/.checks"
        { echo "source_id=$(source_id)"; echo "date=$(date -u +%FT%TZ)";
          echo "check=check-inputs"; echo "reference=$STORED_ROOT"; } \
            > "$SCRIPTDIR/.checks/check-inputs.PASS"
        echo "Check result written: .checks/check-inputs.PASS"
    else
        exit 1
    fi
    ;;

redo)
    # Require an exact dataset identifier and --yes before deleting outputs.
    # The launcher regenerates the input and submits this dataset again.
    DATASET_ARG=""
    CONFIRM=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes) CONFIRM=true; shift ;;
            *) DATASET_ARG=$1; shift ;;
        esac
    done
    [ -n "$DATASET_ARG" ] || { echo "usage: $0 redo <dataset_id> --yes" >&2; exit 1; }
    grep -qxF "$DATASET_ARG" "$DATASET_IDS_FILE" || { echo "ERROR: '$DATASET_ARG' is not in runs/dataset_ids.txt (exact match required)" >&2; exit 1; }
    checks_ok || exit 1
    if ! $CONFIRM; then
        echo "This deletes the outputs and recomputes $DATASET_ARG (results, chunks, validation certificate)."
        echo "Re-run with --yes to proceed. Then confirm its jobs are gone: squeue -u \$USER | grep -F '$DATASET_ARG'"
        exit 1
    fi
    filter="^$(printf '%s' "$DATASET_ARG" | sed 's/\./\\./g')\$"
    bash mmb_run.sh --force-prep --filter "$filter" "$RUNS_FILE"
    echo "NOTE: verify the dataset_id's old jobs are gone (scancel is async): squeue -u \$USER | grep -F '$DATASET_ARG'"
    ;;

*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
