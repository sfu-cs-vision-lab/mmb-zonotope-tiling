#!/bin/bash

# mmb_run.sh  Single entry point for the mmb-zonotope-tiling pipeline
#
# Usage:
#   bash mmb_run.sh [options] <runs_file>
#   bash mmb_run.sh --status
#
# Options:
#   --status         Show status of all runs
#   --clean-stale    Remove .running locks for datasets with no jobs in queue
#   --heal           Like --clean-stale, plus cancels blocked PENDING
#                    jobs (DependencyNeverSatisfied only)
#   --dry-run        Preview routing without submitting (also previews --clean-stale/--heal)
#   --force-rerun    Recompute from kernel (keep generators file)
#   --force-hull     Rerun hull only (keep chunks/kernel output)
#   --force-prep     Regenerate generators file and recompute everything
#   --filter PAT     Only process datasets matching regex PAT
#   --chunks N       Override auto chunk count
#   --partition P    Override MMB_PARTITION for this invocation
#
# Examples:
#   bash mmb_run.sh runs/runs_validate_10nm.m
#   bash mmb_run.sh --force-rerun runs/runs_lightness_1931_2deg.m
#   bash mmb_run.sh --force-hull --filter "D65_FL11" runs/runs_survey_1931_2deg.m
#   bash mmb_run.sh --status
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPTDIR/config/cluster.sh"
. "$SCRIPTDIR/tools/slurm_jobs.sh"

# Output root. A relative MMB_OUTPUT_ROOT is taken from the repository root.
case "$MMB_OUTPUT_ROOT" in
    /*) OUTROOT=$MMB_OUTPUT_ROOT ;;
    *)  OUTROOT=$SCRIPTDIR/$MMB_OUTPUT_ROOT ;;
esac
JOB_TAG=$(mmb_job_tag "$OUTROOT")

# Site arguments for every sbatch call, from config/cluster.sh. A
# command-line --partition overrides the configured one.
sbatch_site_args() {  # sbatch_site_args gpu|cpu
    case "$1" in
        gpu) printf '%s\n' "--account=$MMB_ACCOUNT_GPU" "--gres=$MMB_GPU_GRES" ;;
        cpu) printf '%s\n' "--account=$MMB_ACCOUNT_CPU" ;;
    esac
    [ -n "$PARTITION" ] && printf '%s\n' "--partition=$PARTITION"
    [ -n "$MMB_EXCLUDE_NODES" ] && printf '%s\n' "--exclude=$MMB_EXCLUDE_NODES"
    return 0
}

DRY_RUN=false
CHUNKS_OVERRIDE=""
PARTITION=$MMB_PARTITION
STATUS_MODE=false
CLEAN_STALE=false
HEAL=false
FORCE_RERUN=false
FORCE_HULL=false
FORCE_PREP=false
FILTER=""
RUNSPATH=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)       DRY_RUN=true; shift ;;
        --chunks)        CHUNKS_OVERRIDE=$2; shift 2 ;;
        --partition)     PARTITION=$2; shift 2 ;;
        --status)        STATUS_MODE=true; shift ;;
        --clean-stale)   CLEAN_STALE=true; shift ;;
        --heal)          HEAL=true; shift ;;
        --force-rerun)   FORCE_RERUN=true; shift ;;
        --force-hull)    FORCE_HULL=true; shift ;;
        --force-prep)    FORCE_PREP=true; FORCE_RERUN=true; shift ;;
        --filter)        FILTER=$2; shift 2 ;;
        -*)              echo "Unknown option: $1" >&2; exit 1 ;;
        *)               RUNSPATH=$1; shift ;;
    esac
done

# Validate flag combinations
if $FORCE_HULL && $FORCE_RERUN; then
    echo "Error: --force-hull and --force-rerun/--force-prep are mutually exclusive" >&2
    exit 1
fi
if $HEAL && $CLEAN_STALE; then
    echo "Error: --heal is a superset of --clean-stale. Use one or the other." >&2
    exit 1
fi

# Compute C(n,6) and GPU seconds via python3 (avoids bash integer overflow)
compute_routing() {
    local n=$1
    python3 -c "
from math import comb
tiles = comb($n, 6)
gpu_secs = max(1, int(tiles / 380_000_000))
print(tiles, gpu_secs)
"
}

# Size job memory by problem size. A uniform request applies the heaviest
# case to every job, which over-reserves memory and slows scheduling.
# n is read from the generators file.
hull_mem_for_n() {
    local n=$1
    # Hull memory requests are based on measurements of the full collection.
    # The largest observed hull used 19.55 GB. The same limits apply to
    # standalone hull jobs, the single-GPU route and memory-error retries.
    if [ "$n" -le 100 ]; then echo 8000M        # 10nm/5nm: <=2M candidates
    else                      echo 32000M       # 2nm..1nm incl. high-chroma
    fi
}
chunk_mem_for_n() {
    local n=$1
    # The host vertex buffer uses 24 bytes per vertex. At the 200 million
    # vertex limit it needs 4.8 GB, plus CUDA and process memory. Request
    # 6 GB for large chunks and 4 GB for smaller problems.
    if [ "$n" -le 220 ]; then echo 4000M
    else                      echo 6000M
    fi
}

# Format seconds as human-readable time (with ~ prefix, for estimates)
fmt_time() {
    local s=$1
    if [ "$s" -le 1 ]; then
        echo "<1s"
    elif [ "$s" -lt 60 ]; then
        echo "~${s}s"
    elif [ "$s" -lt 3600 ]; then
        echo "~$(( (s + 30) / 60 ))min"
    else
        echo "~$(( (s + 1800) / 3600 ))hr"
    fi
}

# Format seconds as duration (no ~ prefix, for elapsed/remaining)
fmt_duration() {
    local s=$1
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    elif [ "$s" -lt 3600 ]; then
        echo "$(( (s + 30) / 60 ))min"
    else
        local h=$(( s / 3600 ))
        local m=$(( (s % 3600 + 30) / 60 ))
        if [ "$m" -eq 0 ]; then
            echo "${h}hr"
        else
            echo "${h}hr ${m}min"
        fi
    fi
}

# Get file modification time as epoch seconds (Linux/macOS)
file_epoch() {
    # GNU form first, BSD form second. On Linux the BSD form (-f) means
    # FILESYSTEM status. It prints a multi-line block to stdout and exits
    # nonzero, so capture both and accept only a clean integer.
    local e
    e=$(stat -c %Y "$1" 2>/dev/null) || e=$(stat -f %m "$1" 2>/dev/null) || e=0
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    echo "$e"
}

# Query only jobs submitted for this output directory.
# Slurm's default display widths can hide the long per-dataset job names.
squeue_job_states() {
    mmb_squeue "$JOB_TAG" "%.200j %.20T" "$@"
}

squeue_job_details() {
    mmb_squeue "$JOB_TAG" "%.200j %.20T %.30i %.200r" "$@"
}

squeue_job_ids_names() {
    mmb_squeue "$JOB_TAG" "%.30i %.200j" "$@"
}

summarize_states() {
    local states=$1
    local has_running=false
    local has_pending=false
    local state
    for state in $states; do
        case "$state" in
            RUNNING) has_running=true ;;
            PENDING) has_pending=true ;;
        esac
    done

    if $has_running; then
        echo "RUNNING"
    elif $has_pending; then
        echo "PENDING"
    else
        echo ""
    fi
}

lower_state() {
    case "$1" in
        RUNNING) echo "running" ;;
        PENDING) echo "pending" ;;
        *)       echo "$1" ;;
    esac
}

# Count chunks only for the requested dataset. A file from another
# dataset must not hide a missing chunk with the same index.
has_chunk_output() {
    find "$1/chunks" -maxdepth 1 -type f -name "mmb_$2_chunk*.txt" -print -quit 2>/dev/null | grep -q .
}

chunk_indices_for_dir() {
    find "$1/chunks" -maxdepth 1 -type f -name "mmb_$2_chunk*.txt" -print 2>/dev/null | \
        sed -E -n 's/.*_chunk([0-9]+)\.txt$/\1/p'
}

chunk_file_count_for_dir() {
    find "$1/chunks" -maxdepth 1 -type f -name "mmb_$2_chunk*.txt" -print 2>/dev/null | \
        wc -l | tr -d ' '
}

chunk_unique_count_for_dir() {
    chunk_indices_for_dir "$1" "$2" | awk '{idx=$0+0; if (!(idx in seen)) { seen[idx]=1; n++ }} END { print n+0 }'
}

# Count chunk or kernel files named for another dataset.
alien_chunk_count_for_dir() {
    find "$1/chunks" -maxdepth 1 -type f -name 'mmb_*.txt' ! -name "mmb_$2_chunk*.txt" ! -name "mmb_$2.txt" -print 2>/dev/null | \
        wc -l | tr -d ' '
}

chunk_status_stats_for_dir() {
    local dir=$1
    local dataset_id=$2
    local expected=${3:-}
    local nullglob_was_set
    local file base idx epoch
    local nfiles=0
    local ndone=0
    local oldest_epoch=0
    declare -A seen=()

    if shopt -q nullglob; then
        nullglob_was_set=true
    else
        nullglob_was_set=false
    fi
    shopt -s nullglob

    for file in "$dir/chunks/mmb_${dataset_id}_chunk"*.txt; do
        nfiles=$((nfiles + 1))

        base=${file##*/}
        idx=${base##*_chunk}
        idx=${idx%.txt}
        if [[ "$idx" =~ ^[0-9]+$ ]]; then
            idx=$((10#$idx))
            if [ -n "$expected" ] && [ "$idx" -ge "$expected" ]; then
                :
            elif [ -z "${seen[$idx]:-}" ]; then
                seen[$idx]=1
                ndone=$((ndone + 1))
            fi
        fi

        epoch=$(file_epoch "$file")
        if [ "$epoch" -gt 0 ] && { [ "$oldest_epoch" -eq 0 ] || [ "$epoch" -lt "$oldest_epoch" ]; }; then
            oldest_epoch=$epoch
        fi
    done

    if ! $nullglob_was_set; then
        shopt -u nullglob
    fi

    printf "%s %s %s\n" "$ndone" "$nfiles" "$oldest_epoch"
}

cancel_dataset_jobs() {
    local dataset_id=$1
    local job_rows=$2 jobid name
    while read -r jobid name; do
        [ -z "$jobid" ] && continue
        if [ "$name" = "mmb-$dataset_id" ] || [ "$name" = "hull-$dataset_id" ]; then
            scancel "$jobid" 2>/dev/null || true
        fi
    done <<< "$job_rows"
}

# Status mode
if $STATUS_MODE; then
    echo "=== mmb_run status ==="
    printf "    %-36s %-5s %8s %8s  %-25s  %s\n" "DATASET_ID" "STATE" "VERTS" "FACES" "VOLUME" "CENTER"
    if [ ! -d "$OUTROOT" ]; then
        echo "No runs found."
        exit 0
    fi

    # Build per-dataset job state maps for accurate lock and hull inference.
    declare -A mmb_job_states
    declare -A hull_job_states
    queue_rows=$(squeue_job_states -t RUNNING,PENDING) || exit 1
    while read -r name state; do
        [ -z "$name" ] && continue
        case "$name" in
            mmb-*)
                dataset_key=${name#mmb-}
                mmb_job_states["$dataset_key"]="${mmb_job_states[$dataset_key]:-} $state"
                ;;
            hull-*)
                dataset_key=${name#hull-}
                hull_job_states["$dataset_key"]="${hull_job_states[$dataset_key]:-} $state"
                ;;
        esac
    done <<< "$queue_rows"

    now_epoch=$(date +%s)
    found=false
    for dir in "$OUTROOT"/*/; do
        [ -d "$dir" ] || continue
        found=true
        dataset_id=$(basename "$dir")

        if [ -f "$dir/results/mmb_${dataset_id}_vertices.csv" ]; then
            # Read this dataset's summary. DONE also requires .hull_verified.
            summary="$dir/results/mmb_${dataset_id}_summary.txt"
            nverts="?" nfaces="?" vol="?" center="?"
            if [ -f "$summary" ]; then
                nverts=$(awk '/^Boundary vertices:/{print $NF}' "$summary" 2>/dev/null || echo "?")
                nfaces=$(awk '/^Boundary faces:/{print $NF}' "$summary" 2>/dev/null || echo "?")
                vol=$(awk '/^Hull volume:/{print $NF}' "$summary" 2>/dev/null || echo "?")
                center=$(awk '/^Center:/{sub(/^Center: */,""); print}' "$summary" 2>/dev/null || echo "?")
            fi
            if [ -f "$dir/results/.hull_verified" ]; then
                verdict="DONE "
            else
                verdict="UNVER"
            fi
            printf "    %-36s %s %8s %8s  %-25s  %s\n" "$dataset_id" "$verdict" "$nverts" "$nfaces" "$vol" "$center"
        elif [ -f "$dir/.running" ]; then
            # Lock file present. Running or stale
            mmb_state=$(summarize_states "${mmb_job_states[$dataset_id]:-}")
            hull_state=$(summarize_states "${hull_job_states[$dataset_id]:-}")

            # Show progress for array jobs
            detail=""
            nchunks_file="$dir/.nchunks"
            total=""
            if [ -f "$nchunks_file" ]; then
                total=$(cat "$nchunks_file")
            fi
            read -r ndone nfiles oldest_epoch < <(chunk_status_stats_for_dir "$dir" "$dataset_id" "$total")
            if [ "$nfiles" -gt 0 ]; then
                if [ -n "$total" ]; then
                    detail="$ndone/$total chunks"
                    if [ "$nfiles" -gt "$ndone" ]; then
                        detail="$detail ($nfiles files)"
                    fi
                else
                    total=""
                    detail="$ndone chunks done"
                    if [ "$nfiles" -gt "$ndone" ]; then
                        detail="$detail ($nfiles files)"
                    fi
                fi

                # Elapsed time from oldest chunk file
                elapsed_str=""
                remaining_str=""
                if [ "$oldest_epoch" -gt 0 ]; then
                    elapsed=$(( now_epoch - oldest_epoch ))
                    if [ "$elapsed" -gt 0 ]; then
                        elapsed_str=$(fmt_duration "$elapsed")
                        if [ -n "$total" ] && [ "$ndone" -gt 0 ] && [ "$ndone" -lt "$total" ]; then
                            remaining=$(( elapsed * (total - ndone) / ndone ))
                            remaining_str=$(fmt_duration "$remaining")
                        fi
                    fi
                fi

                # Hull job status. Infer from queue, not from chunk count.
                # Chunks complete doesn't imply the hull is running. The
                # hull may have failed, been canceled or never submitted.
                hull_status=""
                if [ -n "$total" ]; then
                    if [ "$ndone" -lt "$total" ]; then
                        hull_status="hull: waiting"
                    else
                        case "$hull_state" in
                            RUNNING) hull_status="hull: running" ;;
                            PENDING) hull_status="hull: pending" ;;
                            *)       hull_status="hull: not queued" ;;
                        esac
                    fi
                fi

                [ -n "$elapsed_str" ] && detail="$detail  ${elapsed_str} elapsed"
                [ -n "$remaining_str" ] && detail="$detail  ~${remaining_str} remaining"
                [ -n "$hull_status" ] && detail="$detail  $hull_status"
            else
                detail="waiting"
            fi

            [ -n "$mmb_state" ] && detail="$detail  chunks: $(lower_state "$mmb_state")"

            if [ -n "$mmb_state" ] || [ -n "$hull_state" ]; then
                printf "    %-36s RUN     %s\n" "$dataset_id" "$detail"
            else
                printf "    %-36s STALE   .running exists but no matching jobs in queue (%s)\n" "$dataset_id" "$detail"
            fi
        elif ls "$dir/"generators_*.txt &>/dev/null 2>&1; then
            printf "    %-36s FAIL    generators file present but no lock or results\n" "$dataset_id"
        else
            printf "    %-36s EMPTY\n" "$dataset_id"
        fi
    done

    if ! $found; then
        echo "No runs found."
    fi
    exit 0
fi

# Clean-stale mode
# Removes orphaned .running lock files for datasets with no matching jobs in the
# queue. On the next invocation of mmb_run.sh <runs_file>, the auto-hull-
# resubmission block below will pick up datasets that have kernel output but no
# lock or results. Never deletes chunks, results, generators file, logs or .nchunks.
if $CLEAN_STALE; then
    if $DRY_RUN; then
        echo "=== mmb_run --clean-stale (dry run) ==="
    else
        echo "=== mmb_run --clean-stale ==="
    fi
    if [ ! -d "$OUTROOT" ]; then
        echo "No runs_output directory."
        exit 0
    fi

    # Build job map: name -> state:jobid:reason
    declare -A job_map
    queue_rows=$(squeue_job_details) || exit 1
    while read -r name state jobid reason; do
        [ -z "$name" ] && continue
        job_map["$name"]="$state:$jobid:$reason"
    done <<< "$queue_rows"

    cleaned=0
    kept=0
    zombies=()  # "jobid:dataset_id" pairs for zombie hull jobs to optionally cancel
    stuck_datasets=()  # dataset_ids with ReqNodeNotAvail jobs, for an informational note only
    found_any=false

    for dir in "$OUTROOT"/*/; do
        [ -d "$dir" ] || continue
        [ -f "$dir/.running" ] || continue
        found_any=true
        dataset_id=$(basename "$dir")

        mmb_entry="${job_map[mmb-${dataset_id}]:-}"
        hull_entry="${job_map[hull-${dataset_id}]:-}"

        mmb_state=""
        mmb_reason=""
        if [ -n "$mmb_entry" ]; then
            mmb_state="${mmb_entry%%:*}"
            rest="${mmb_entry#*:}"
            mmb_reason="${rest#*:}"
        fi
        hull_state=""
        hull_id=""
        hull_reason=""
        if [ -n "$hull_entry" ]; then
            hull_state="${hull_entry%%:*}"
            rest="${hull_entry#*:}"
            hull_id="${rest%%:*}"
            hull_reason="${rest#*:}"
        fi

        # A hull job stuck in PENDING with DependencyNeverSatisfied is a zombie.
        # Its array was canceled, so afterok can never fire.
        is_zombie=false
        if [ "$hull_state" = "PENDING" ] && [ "$hull_reason" = "DependencyNeverSatisfied" ]; then
            is_zombie=true
        fi

        # Real active work = any mmb job, or a hull job that isn't a zombie.
        has_real_job=false
        if [ -n "$mmb_entry" ]; then
            has_real_job=true
        elif [ -n "$hull_entry" ] && [ "$is_zombie" = false ]; then
            has_real_job=true
        fi

        if $has_real_job; then
            detail="active jobs:"
            [ -n "$mmb_state" ] && detail="$detail mmb=$mmb_state"
            [ -n "$hull_state" ] && detail="$detail hull=$hull_state"
            printf "    %-36s KEEP    %s\n" "$dataset_id" "$detail"
            kept=$((kept + 1))
            # Track ReqNodeNotAvail-pending datasets for an informational note.
            # These are NOT stuck. Just queue-waiting on a busy cluster.
            if [[ "$mmb_reason" == ReqNodeNotAvail* ]] || [[ "$hull_reason" == ReqNodeNotAvail* ]]; then
                stuck_datasets+=("$dataset_id")
            fi
        else
            if $is_zombie; then
                reason_str="zombie hull (DependencyNeverSatisfied, job $hull_id)"
                zombies+=("$hull_id:$dataset_id")
            else
                reason_str="no matching jobs in queue"
            fi
            if $DRY_RUN; then
                printf "    %-36s WOULD CLEAN  %s\n" "$dataset_id" "$reason_str"
            else
                rm -f "$dir/.running"
                printf "    %-36s CLEANED      %s\n" "$dataset_id" "$reason_str"
            fi
            cleaned=$((cleaned + 1))
        fi
    done

    if ! $found_any; then
        echo "No dataset_ids with .running lock files."
        exit 0
    fi

    echo ""
    if $DRY_RUN; then
        echo "Dry run: would clean $cleaned, keep $kept."
        if [ ${#zombies[@]} -gt 0 ]; then
            echo "Would offer to cancel ${#zombies[@]} pending hull job(s) with unsatisfied dependencies (dry-run: skipping prompt)."
        fi
    else
        echo "Cleaned: $cleaned, Kept: $kept."
        if [ ${#zombies[@]} -gt 0 ]; then
            echo ""
            echo "Found ${#zombies[@]} pending hull job(s) with DependencyNeverSatisfied:"
            for z in "${zombies[@]}"; do
                printf "  job %-10s (hull-%s)\n" "${z%%:*}" "${z#*:}"
            done
            read -r -p "Cancel these zombie jobs? [y/N] " ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                for z in "${zombies[@]}"; do
                    scancel "${z%%:*}" 2>/dev/null || true
                done
                echo "Canceled ${#zombies[@]} job(s)."
            else
                echo "Left the pending jobs in the queue."
            fi
        fi
        echo ""
        echo "Run mmb_run.sh <runs_file> to resubmit failed hulls"
    fi
    if [ ${#stuck_datasets[@]} -gt 0 ]; then
        echo ""
        echo "Note: ${#stuck_datasets[@]} dataset_id(s) have PENDING jobs with reason"
        echo "ReqNodeNotAvail. This is usually cosmetic (down nodes cluster-wide)."
        echo "The jobs will run once GPU slots free up. No action needed:"
        for s in "${stuck_datasets[@]}"; do echo "  $s"; done
    fi
    exit 0
fi

# Heal mode
# Superset of --clean-stale. Classifies each dataset_id with a .running lock by its
# squeue state and takes one of four actions:
#   HEALTHY      (some job RUNNING)              -> KEEP
#   SCHEDULABLE  (PENDING, reason None/Priority/Resources/Dependency) -> KEEP
#   STUCK        (PENDING, reason DependencyNeverSatisfied only)
#                -> scancel the stuck jobs, remove .running
#                NOTE: ReqNodeNotAvail* is NOT stuck on this cluster. It is a
#                cosmetic reason naming cluster-wide down nodes. Such jobs are
#                SCHEDULABLE and left alone.
#   ORPHANED     (no matching jobs)              -> remove .running
# Never deletes anything except .running lock files.
if $HEAL; then
    if $DRY_RUN; then
        echo "=== mmb_run --heal (dry run) ==="
    else
        echo "=== mmb_run --heal ==="
    fi
    if [ ! -d "$OUTROOT" ]; then
        echo "No runs_output directory."
        exit 0
    fi

    # Multi-entry job map: each job name can appear multiple times (array tasks
    # in different states). Store all entries space-separated, as "state:id:reason ...".
    declare -A heal_job_map
    queue_rows=$(squeue_job_details) || exit 1
    while read -r name state jobid reason; do
        [ -z "$name" ] && continue
        if [ -n "${heal_job_map[$name]:-}" ]; then
            heal_job_map["$name"]="${heal_job_map[$name]} $state:$jobid:$reason"
        else
            heal_job_map["$name"]="$state:$jobid:$reason"
        fi
    done <<< "$queue_rows"

    healed=0
    orphaned=0
    kept=0
    canceled_datasets=()
    found_any=false

    for dir in "$OUTROOT"/*/; do
        [ -d "$dir" ] || continue
        [ -f "$dir/.running" ] || continue
        found_any=true
        dataset_id=$(basename "$dir")

        has_running=false
        has_stuck=false
        has_schedulable=false
        stuck_jobs=()
        state_summary=""

        for job_name in "mmb-${dataset_id}" "hull-${dataset_id}"; do
            entries="${heal_job_map[$job_name]:-}"
            [ -z "$entries" ] && continue
            kind="${job_name%%-*}"  # "mmb" or "hull"
            for entry in $entries; do
                state="${entry%%:*}"
                rest="${entry#*:}"
                jobid="${rest%%:*}"
                reason="${rest#*:}"

                case "$state" in
                    RUNNING)
                        has_running=true
                        state_summary="$state_summary $kind=R"
                        ;;
                    PENDING)
                        case "$reason" in
                            DependencyNeverSatisfied)
                                # Genuine zombie: hull dep will never be met.
                                has_stuck=true
                                stuck_jobs+=("$jobid")
                                state_summary="$state_summary $kind=P/$reason"
                                ;;
                            ReqNodeNotAvail*)
                                # Leave ReqNodeNotAvail jobs in the queue. This reason alone does
                                # not establish that the dependency cannot be satisfied.
                                has_schedulable=true
                                state_summary="$state_summary $kind=P"
                                ;;
                            *)
                                has_schedulable=true
                                state_summary="$state_summary $kind=P"
                                ;;
                        esac
                        ;;
                esac
            done
        done

        # Priority: RUNNING > STUCK > SCHEDULABLE > ORPHANED
        if $has_running; then
            status="HEALTHY"
        elif $has_stuck; then
            status="STUCK"
        elif $has_schedulable; then
            status="SCHEDULABLE"
        else
            status="ORPHANED"
        fi

        case "$status" in
            HEALTHY)
                printf "    %-36s KEEP       HEALTHY%s\n" "$dataset_id" "$state_summary"
                kept=$((kept + 1))
                ;;
            SCHEDULABLE)
                printf "    %-36s KEEP       SCHEDULABLE%s\n" "$dataset_id" "$state_summary"
                kept=$((kept + 1))
                ;;
            STUCK)
                if $DRY_RUN; then
                    printf "    %-36s WOULD HEAL STUCK%s  (would cancel %s, remove .running)\n" \
                        "$dataset_id" "$state_summary" "${stuck_jobs[*]}"
                else
                    for jid in "${stuck_jobs[@]}"; do
                        scancel "$jid" 2>/dev/null || true
                    done
                    rm -f "$dir/.running"
                    printf "    %-36s HEALED     STUCK%s  (canceled %s, removed .running)\n" \
                        "$dataset_id" "$state_summary" "${stuck_jobs[*]}"
                    canceled_datasets+=("$dataset_id")
                fi
                healed=$((healed + 1))
                ;;
            ORPHANED)
                if $DRY_RUN; then
                    printf "    %-36s WOULD CLEAN  no matching jobs in queue\n" "$dataset_id"
                else
                    rm -f "$dir/.running"
                    printf "    %-36s CLEANED      no matching jobs in queue\n" "$dataset_id"
                fi
                orphaned=$((orphaned + 1))
                ;;
        esac
    done

    if ! $found_any; then
        echo "No dataset_ids with .running lock files."
        exit 0
    fi

    # Verify scancels actually propagated before declaring success.
    if ! $DRY_RUN && [ ${#canceled_datasets[@]} -gt 0 ]; then
        echo ""
        echo "Verifying scancels propagated..."
        sleep 2
        lingering=()
        queue_rows=$(squeue_job_states) || exit 1
        while read -r name state; do
            [ -z "$name" ] && continue
            for s in "${canceled_datasets[@]}"; do
                if [ "$name" = "mmb-${s}" ] || [ "$name" = "hull-${s}" ]; then
                    lingering+=("$name ($state)")
                fi
            done
        done <<< "$queue_rows"
        if [ ${#lingering[@]} -gt 0 ]; then
            echo "WARNING: some canceled jobs still visible in queue (Slurm propagation delay):"
            for l in "${lingering[@]}"; do echo "  $l"; done
        else
            echo "All scancels propagated."
        fi
    fi

    echo ""
    if $DRY_RUN; then
        echo "Dry run: would heal $healed, orphan $orphaned, keep $kept."
    else
        echo "Healed: $healed, Orphaned: $orphaned, Kept: $kept."
    fi
    echo ""
    echo "Run mmb_run.sh <runs_file> to resubmit failed hulls"
    exit 0
fi

# Validate arguments
if [ -z "$RUNSPATH" ]; then
    echo "Usage: bash $0 [options] <runs_file>"
    echo "       bash $0 --status"
    echo "       bash $0 --clean-stale [--dry-run]"
    echo "       bash $0 --heal [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --status         Show status of all runs"
    echo "  --clean-stale    Remove .running locks for datasets with no jobs in queue"
    echo "  --heal           Like --clean-stale, plus cancels blocked PENDING"
    echo "                   jobs (DependencyNeverSatisfied only)"
    echo "  --dry-run        Preview routing without submitting (also previews --clean-stale/--heal)"
    echo "  --force-rerun    Recompute from kernel (keep generators file)"
    echo "  --force-hull     Rerun hull only (keep chunks/kernel output)"
    echo "  --force-prep     Regenerate generators file and recompute everything"
    echo "  --filter PAT     Only process datasets matching regex PAT"
    echo "  --chunks N       Override auto chunk count"
    echo "  --partition P    Override MMB_PARTITION for this invocation"
    echo ""
    echo "Examples:"
    echo "  bash $0 runs/runs_validate_10nm.m"
    echo "  bash $0 --force-rerun runs/runs_lightness_1931_2deg.m"
    echo "  bash $0 --force-hull --filter D65_FL11 runs/runs_survey_1931_2deg.m"
    echo "  bash $0 --status"
    echo "  bash $0 --clean-stale --dry-run"
    echo "  bash $0 --heal --dry-run"
    exit 1
fi

if [ ! -f "$RUNSPATH" ]; then
    echo "Error: runs file not found: $RUNSPATH" >&2
    exit 1
fi

# Warn about stale generated files in project root
if ls "$SCRIPTDIR"/generators_*.txt "$SCRIPTDIR"/mmb_*.txt 2>/dev/null | grep -q .; then
    echo "WARNING: stale data files in project root. Clean with:"
    echo "  rm -f generators_*.txt mmb_*.txt"
    echo ""
fi

RUNSDIR=$(cd "$(dirname "$RUNSPATH")" && pwd)
RUNSNAME=$(basename "$RUNSPATH" .m)

# Generate inputs in a private preparation directory for this process.
# Routing moves each file into its dataset directory. The exit handler
# removes the preparation directory.
PREPDIR=$(mktemp -d "$SCRIPTDIR/.prep.XXXXXX")
trap 'rm -rf "$PREPDIR"' EXIT
echo "=== mmb_run: $RUNSPATH ==="
echo "Generating generators file (prep dir: $(basename "$PREPDIR"))..."
module load $MMB_MODULES_MATLAB 2>/dev/null || true
matlab -batch "addpath('$SCRIPTDIR/src','$RUNSDIR'); cd('$PREPDIR'); $RUNSNAME"
echo ""

# Build the CUDA kernel if it is missing
if ! $DRY_RUN && ! $FORCE_HULL && [ ! -x "$SCRIPTDIR/cuda/mmb_exact" ]; then
    echo "Building CUDA kernel..."
    module load $MMB_MODULES_GPU 2>/dev/null || true
    make -C "$SCRIPTDIR/cuda" NVCC_ARCH="$MMB_GPU_ARCH"
    echo ""
fi

# Step 2+3: Route each generators file
echo "Routing:"

n_submitted=0
n_skip_done=0
n_skip_running=0
n_hull_retry=0
n_incomplete=0

for datafile in "$PREPDIR"/generators_*.txt; do
    [ -f "$datafile" ] || continue
    fname=$(basename "$datafile")
    dataset_id=${fname#generators_}
    dataset_id=${dataset_id%.txt}
    RUNDIR=$OUTROOT/$dataset_id

    # Filter check
    if [ -n "$FILTER" ] && ! echo "$dataset_id" | grep -qE "$FILTER"; then
        rm -f "$datafile"
        continue
    fi

    # Read the queue before changing a dataset selected for a forced rerun.
    if ! $DRY_RUN && { $FORCE_RERUN || $FORCE_HULL; }; then
        force_job_rows=$(squeue_job_ids_names) || exit 1
    fi

    # Create the run directory
    mkdir -p "$RUNDIR"/{chunks,results,logs}

    # Remove staging files that have not been updated for more than three
    # hours. Their names exclude them from chunk processing.
    find "$RUNDIR" "$RUNDIR/chunks" -maxdepth 1 -type f -name '.staging.*' -mmin +180 -delete 2>/dev/null || true

    # Handle generators file (exact dataset_id name, never a glob)
    # A generators file without a payload hash cannot be checked against
    # kernel output. Replace it with the newly generated input. Keep an
    # existing input that already carries the hash.
    if $FORCE_PREP || [ ! -f "$RUNDIR/generators_${dataset_id}.txt" ] || \
       ! grep -q '^% payload_sha256=' "$RUNDIR/generators_${dataset_id}.txt"; then
        mv -f "$datafile" "$RUNDIR/generators_${dataset_id}.txt"
    else
        rm -f "$datafile"
    fi

    # Force cleanup
    if $FORCE_RERUN; then
        if $DRY_RUN; then
            printf "    %-36s -> cancel jobs, clear results, rerun from the start\n" "$dataset_id"
            continue
        fi
        # Cancel any queued/running jobs for this dataset_id
        cancel_dataset_jobs "$dataset_id" "$force_job_rows"
        rm -f "$RUNDIR/.running" "$RUNDIR/.nchunks"
        rm -rf "$RUNDIR/chunks" "$RUNDIR/results"
        rm -f "$RUNDIR/mmb_${dataset_id}.txt"
        mkdir -p "$RUNDIR"/{chunks,results}
    fi

    # Hull-only path (--force-hull)
    if $FORCE_HULL; then
        has_output=false
        if has_chunk_output "$RUNDIR" "$dataset_id"; then
            has_output=true
        elif [ -f "$RUNDIR/mmb_${dataset_id}.txt" ]; then
            has_output=true
        fi

        if [ "$has_output" = true ]; then
            if $DRY_RUN; then
                printf "    %-36s -> hull only\n" "$dataset_id"
            else
                # Clean up only datasets that have kernel output to hull
                cancel_dataset_jobs "$dataset_id" "$force_job_rows"
                rm -f "$RUNDIR/.running"
                rm -rf "$RUNDIR/results"
                mkdir -p "$RUNDIR/results"

                touch "$RUNDIR/.running"
                hn=$(awk '/^[^%]/{print $1; exit}' "$RUNDIR/generators_${dataset_id}.txt" 2>/dev/null | tr -d '[:space:]')
                JOB_HULL=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args cpu) \
                    --job-name="hull-${dataset_id}" \
                    --mem="$(hull_mem_for_n "${hn:-401}")" \
                    --output="$RUNDIR/logs/mmb-hull-%j.out" \
                    --error="$RUNDIR/logs/mmb-hull-%j.err" \
                    "$SCRIPTDIR/slurm/hull_job.sh" "$RUNDIR" "$dataset_id")
                printf "    %-36s HULL ONLY  (job %s)\n" "$dataset_id" "$JOB_HULL"
                n_submitted=$((n_submitted + 1))
            fi
        else
            printf "    %-36s SKIP    no kernel output\n" "$dataset_id"
        fi
        continue
    fi

    # Standard dedup checks
    # A dataset is complete when its result files and .hull_verified exist.
    # Files belonging to another dataset do not count.
    if [ -f "$RUNDIR/results/mmb_${dataset_id}_vertices.csv" ] && \
       [ -f "$RUNDIR/results/mmb_${dataset_id}_summary.txt" ] && \
       [ -f "$RUNDIR/results/.hull_verified" ]; then
        printf "    %-36s SKIP    verified results exist\n" "$dataset_id"
        n_skip_done=$((n_skip_done + 1))
        continue
    fi
    if [ -f "$RUNDIR/.running" ]; then
        printf "    %-36s SKIP    run in progress\n" "$dataset_id"
        n_skip_running=$((n_skip_running + 1))
        continue
    fi

    # Auto hull resubmission
    # Dataset has kernel output but no results and no lock, so the hull likely failed
    has_kernel_output=false
    kernel_output_kind=""
    chunk_count=0
    chunk_file_count=0
    if has_chunk_output "$RUNDIR" "$dataset_id"; then
        has_kernel_output=true
        kernel_output_kind="chunks"
        chunk_count=$(chunk_unique_count_for_dir "$RUNDIR" "$dataset_id")
        chunk_file_count=$(chunk_file_count_for_dir "$RUNDIR" "$dataset_id")
    elif [ -f "$RUNDIR/mmb_${dataset_id}.txt" ]; then
        has_kernel_output=true
        kernel_output_kind="single"
    fi
    n_alien=$(alien_chunk_count_for_dir "$RUNDIR" "$dataset_id")
    if [ "$n_alien" -gt 0 ]; then
        printf "    %-36s ERROR   %d file from another dataset(s) in chunks/. Investigate before running\n" "$dataset_id" "$n_alien"
        n_incomplete=$((n_incomplete + 1))
        continue
    fi

    if [ "$has_kernel_output" = true ]; then
        # Check chunk completeness (only when chunks/ has files)
        if [ -f "$RUNDIR/.nchunks" ] && [ "$chunk_count" -gt 0 ]; then
            expected=$(tr -d '[:space:]' < "$RUNDIR/.nchunks")

            # Missing = {0..expected-1} minus the unique PRESENT index set
            # (leading zeros stripped). Set difference via comm on two
            # lexicographically-sorted lists (portable, no bash-4 assoc
            # arrays), so duplicate/stale files cannot hide a missing chunk.
            missing_indices=()
            while read -r i; do
                [ -n "$i" ] && missing_indices+=("$i")
            done < <(comm -13 \
                <(chunk_indices_for_dir "$RUNDIR" "$dataset_id" | awk '{print $0+0}' | sort -u) \
                <(seq 0 $((expected - 1)) | sort))
            n_missing=${#missing_indices[@]}

            if [ "$n_missing" -gt 0 ]; then
                # Partial chunk resubmission
                # Kernel needs the original generators file to recompute missing chunks.
                coldata="$RUNDIR/generators_${dataset_id}.txt"
                [ -f "$coldata" ] || coldata=""
                if [ -z "$coldata" ]; then
                    printf "    %-36s ERROR   incomplete (%s/%s unique chunks, %s files) but generators file missing. Regenerate via runs file\n" \
                        "$dataset_id" "$chunk_count" "$expected" "$chunk_file_count"
                    n_incomplete=$((n_incomplete + 1))
                    continue
                fi
                coldata_fname=$(basename "$coldata")

                # Per-chunk wall time: same formula as fresh array submissions
                n=$(awk '/^[^%]/{print $1; exit}' "$coldata" | tr -d '[:space:]')
                read tiles gpu_secs <<< $(compute_routing "$n")
                chunk_secs=$((gpu_secs / expected))
                chunk_time=$(fmt_time "$chunk_secs")

                # Comma-separated --array spec (5,17,23,...)
                array_spec=$(IFS=,; echo "${missing_indices[*]}")

                if $DRY_RUN; then
                    printf "    %-36s -> partial resubmit (%d/%d missing, --array=%s, %s each)\n" \
                        "$dataset_id" "$n_missing" "$expected" "$array_spec" "$chunk_time"
                else
                    touch "$RUNDIR/.running"

                    # Set walltime from the tile count with a margin for variation between
                    # chunks. An interrupted write does not distinguish a timeout from
                    # preemption, so retries use the same estimate. Repeated interruptions
                    # produce a message with the sacct command to inspect the cause.
                    # MMB_CHUNK_WALL_MINS can increase the request up to the configured limit.
                    chunk_wall_mins=$(( (chunk_secs * 2) / 60 + 5 ))
                    if [ "$expected" -ge 100 ]; then
                        [ "$chunk_wall_mins" -lt 5 ] && chunk_wall_mins=5
                    else
                        [ "$chunk_wall_mins" -lt "$MMB_CHUNK_WALL_MIN_MINS" ] && chunk_wall_mins=$MMB_CHUNK_WALL_MIN_MINS
                    fi
                    [ -n "${MMB_CHUNK_WALL_MINS:-}" ] && chunk_wall_mins=$MMB_CHUNK_WALL_MINS
                    [ "$chunk_wall_mins" -gt "$MMB_CHUNK_WALL_MAX_MINS" ] && chunk_wall_mins=$MMB_CHUNK_WALL_MAX_MINS
                    for _idx in "${missing_indices[@]}"; do
                        _c=$(find "$RUNDIR/chunks" -maxdepth 1 \
                            -name ".staging.mmb_${dataset_id}_chunk${_idx}.*" ! -name "*FAILED*" 2>/dev/null | wc -l | tr -d ' ')
                        if [ "$_c" -ge 3 ]; then
                            echo "    ADVISORY: chunk $_idx has $_c killed attempts. Diagnose the cause before assuming slowness:"
                            echo "      sacct -u \$USER --name=mmb-${dataset_id} -o JobID,State,Elapsed,Timelimit,Reason | tail -20"
                            echo "      TIMEOUT -> resubmit with MMB_CHUNK_WALL_MINS=<mins>. PREEMPTED/NODE_FAIL -> queue churn, no action"
                        fi
                    done
                    chunk_wall=$(printf "%02d:%02d:00" $((chunk_wall_mins / 60)) $((chunk_wall_mins % 60)))

                    JOB_ARRAY=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args gpu) \
                        --job-name="mmb-${dataset_id}" \
                        --array="$array_spec" \
                        --time="$chunk_wall" \
                        --mem="$(chunk_mem_for_n "$n")" \
                        --output="$RUNDIR/logs/mmb-chunk-%A_%a.out" \
                        --error="$RUNDIR/logs/mmb-chunk-%A_%a.err" \
                        "$SCRIPTDIR/slurm/gpu_chunk.sh" "$coldata_fname" "$expected" "$RUNDIR")

                    JOB_HULL=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args cpu) \
                        --job-name="hull-${dataset_id}" \
                        --dependency=afterok:$JOB_ARRAY \
                        --mem="$(hull_mem_for_n "$n")" \
                        --output="$RUNDIR/logs/mmb-hull-%j.out" \
                        --error="$RUNDIR/logs/mmb-hull-%j.err" \
                        "$SCRIPTDIR/slurm/hull_job.sh" "$RUNDIR" "$dataset_id")

                    printf "    %-36s PARTIAL RESUBMIT  (%d/%d chunks missing, array %s, hull %s)\n" \
                        "$dataset_id" "$n_missing" "$expected" "$JOB_ARRAY" "$JOB_HULL"
                    n_submitted=$((n_submitted + 1))
                fi
                continue
            fi
        fi

        # Chunk count OK or no count file, so submit the hull
        if [ "$kernel_output_kind" = "chunks" ]; then
            if [ -f "$RUNDIR/.nchunks" ]; then
                expected=$(tr -d '[:space:]' < "$RUNDIR/.nchunks")
                chunk_note="$chunk_count/$expected chunks"
            else
                chunk_note="$chunk_count chunks, no count file"
            fi
            if [ "$chunk_file_count" -gt "$chunk_count" ]; then
                chunk_note="$chunk_note, $chunk_file_count files"
            fi
        else
            chunk_note="single-GPU output"
        fi

        if $DRY_RUN; then
            printf "    %-36s -> resubmit hull (%s)\n" "$dataset_id" "$chunk_note"
        else
            touch "$RUNDIR/.running"
            hn=$(awk '/^[^%]/{print $1; exit}' "$RUNDIR/generators_${dataset_id}.txt" 2>/dev/null | tr -d '[:space:]')
            JOB_HULL=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args cpu) \
                --job-name="hull-${dataset_id}" \
                --mem="$(hull_mem_for_n "${hn:-401}")" \
                --output="$RUNDIR/logs/mmb-hull-%j.out" \
                --error="$RUNDIR/logs/mmb-hull-%j.err" \
                "$SCRIPTDIR/slurm/hull_job.sh" "$RUNDIR" "$dataset_id")
            printf "    %-36s RESUBMIT HULL  (%s, job %s)\n" "$dataset_id" "$chunk_note" "$JOB_HULL"
            n_hull_retry=$((n_hull_retry + 1))
        fi
        continue
    fi

    # Fresh submission
    # Read n from generators file (now in RUNDIR)
    coldata="$RUNDIR/generators_${dataset_id}.txt"
    [ -f "$coldata" ] || coldata=""
    if [ -z "$coldata" ]; then
        printf "    %-36s SKIP    no generators file\n" "$dataset_id"
        continue
    fi
    n=$(awk '/^[^%]/{print $1; exit}' "$coldata" | tr -d '[:space:]')

    # Compute routing via python3
    read tiles gpu_secs <<< $(compute_routing "$n")

    if [ "$gpu_secs" -lt 600 ] && [ -z "$CHUNKS_OVERRIDE" ]; then
        # Use one GPU unless --chunks explicitly requests an array.
        time_str=$(fmt_time "$gpu_secs")

        if $DRY_RUN; then
            printf "    %-36s n=%-6d %-6s -> single GPU\n" "$dataset_id" "$n" "$time_str"
        else
            touch "$RUNDIR/.running"

            # Covers kernel (3x margin) plus the delegated hull_job step
            # (a 2nm hull reads ~15M rows), same timeout-vs-reservation
            # asymmetry as the chunk walltime.
            wall_mins=$(( (gpu_secs * 3 + 1200) / 60 + 1 ))
            [ "$wall_mins" -lt 30 ] && wall_mins=30
            [ "$wall_mins" -gt "$MMB_CHUNK_WALL_MAX_MINS" ] && wall_mins=$MMB_CHUNK_WALL_MAX_MINS
            wall_time=$(printf "%02d:%02d:00" $((wall_mins / 60)) $((wall_mins % 60)))

            JOB=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args gpu) \
                --job-name="mmb-${dataset_id}" \
                --time="$wall_time" \
                --mem="$(hull_mem_for_n "$n")" \
                "$SCRIPTDIR/slurm/single_gpu.sh" "$RUNDIR")
            printf "    %-36s n=%-6d %-6s -> single GPU  (job %s)\n" "$dataset_id" "$n" "$time_str" "$JOB"
            n_submitted=$((n_submitted + 1))
        fi
    else
        # Array route
        if [ -n "$CHUNKS_OVERRIDE" ]; then
            nchunks=$CHUNKS_OVERRIDE
        else
            nchunks=$(( (gpu_secs + 299) / 300 ))
            [ "$nchunks" -gt 80 ] && nchunks=80
        fi
        chunk_secs=$((gpu_secs / nchunks))
        chunk_time=$(fmt_time "$chunk_secs")
        total_time=$(fmt_time "$gpu_secs")

        if $DRY_RUN; then
            printf "    %-36s n=%-6d       -> parallel (%d GPUs x %s each)\n" "$dataset_id" "$n" "$nchunks" "$chunk_time"
            wall_est_secs=$(( nchunks * chunk_secs / 4 ))
            wall_est=$(fmt_time "$wall_est_secs")
            echo "      Total compute: $total_time on 1 GPU, split across $nchunks independent jobs."
            echo "      Each job requests 1 GPU and processes 1/$nchunks of the tiles."
            echo "      Wall time depends on how many jobs Slurm runs concurrently."
            echo "      Last observed: ~4 concurrent GPUs -> $wall_est wall time."
        else
            touch "$RUNDIR/.running"
            echo "$nchunks" > "$RUNDIR/.nchunks"

            # Empirical base: measured uncensored 1nm chunk runtimes top
            # out at ~10 min, so 2x the tile-count average (+5) covers the
            # worst observed with headroom while staying backfill-sized.
            # MMB_CHUNK_WALL_MINS overrides (operator decision, capped).
            chunk_wall_mins=$(( (chunk_secs * 2) / 60 + 5 ))
            if [ "$nchunks" -ge 100 ]; then
                [ "$chunk_wall_mins" -lt 5 ] && chunk_wall_mins=5
            else
                [ "$chunk_wall_mins" -lt "$MMB_CHUNK_WALL_MIN_MINS" ] && chunk_wall_mins=$MMB_CHUNK_WALL_MIN_MINS
            fi
            [ -n "${MMB_CHUNK_WALL_MINS:-}" ] && chunk_wall_mins=$MMB_CHUNK_WALL_MINS
            [ "$chunk_wall_mins" -gt "$MMB_CHUNK_WALL_MAX_MINS" ] && chunk_wall_mins=$MMB_CHUNK_WALL_MAX_MINS
            chunk_wall=$(printf "%02d:%02d:00" $((chunk_wall_mins / 60)) $((chunk_wall_mins % 60)))

            JOB_ARRAY=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args gpu) \
                --job-name="mmb-${dataset_id}" \
                --array=0-$((nchunks - 1)) \
                --time="$chunk_wall" \
                --mem="$(chunk_mem_for_n "$n")" \
                --output="$RUNDIR/logs/mmb-chunk-%A_%a.out" \
                --error="$RUNDIR/logs/mmb-chunk-%A_%a.err" \
                "$SCRIPTDIR/slurm/gpu_chunk.sh" "$fname" "$nchunks" "$RUNDIR")

            JOB_HULL=$(sbatch --parsable --comment="$JOB_TAG" $(sbatch_site_args cpu) \
                --job-name="hull-${dataset_id}" \
                --dependency=afterok:$JOB_ARRAY \
                --mem="$(hull_mem_for_n "$n")" \
                --output="$RUNDIR/logs/mmb-hull-%j.out" \
                --error="$RUNDIR/logs/mmb-hull-%j.err" \
                "$SCRIPTDIR/slurm/hull_job.sh" "$RUNDIR" "$dataset_id")

            printf "    %-36s n=%-6d       -> parallel    (array %s, hull %s)\n" "$dataset_id" "$n" "$JOB_ARRAY" "$JOB_HULL"
            echo "      $nchunks jobs x $chunk_time each, wall time depends on cluster availability."
            n_submitted=$((n_submitted + 1))
        fi
    fi
done

# Prep dir (and any unrouted generators file in it) is removed by the EXIT trap.

echo ""
if $DRY_RUN; then
    echo "Dry run complete. No jobs submitted."
else
    summary="Submitted: $n_submitted"
    [ "$n_hull_retry" -gt 0 ] && summary="$summary, Hull retries: $n_hull_retry"
    [ "$n_skip_done" -gt 0 ] && summary="$summary, Skipped (done): $n_skip_done"
    [ "$n_skip_running" -gt 0 ] && summary="$summary, Skipped (in progress): $n_skip_running"
    [ "$n_incomplete" -gt 0 ] && summary="$summary, Incomplete: $n_incomplete"
    echo "$summary"
    echo ""
    echo "All runs output to: $OUTROOT"
    echo "Monitor: bash mmb_run.sh --status"
fi
