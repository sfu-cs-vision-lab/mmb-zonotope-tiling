#!/bin/bash

# tools/find_low_vertex_datasets.sh
#
# Flag completed datasets with unusually low boundary vertex counts.
# This is a heuristic for inspection. A low count does not by itself show
# that a result is wrong.
#
# Heuristic: for each observer (1931_2deg, 1964_10deg, cfb_2deg, cfb_10deg,
# lms_2deg, lms_10deg), take the median Boundary-vertex count across all DONE
# datasets for that observer. Flag any dataset_id whose count is below
# (THRESHOLD_PCT/100) * median.
#
# Output:
#   stdout   one flagged dataset_id per line, suitable for piping
#   stderr   diagnostic detail when --verbose is set
#
# This script READS ONLY. It does not modify any run state.
#
# Usage:
#   bash tools/find_low_vertex_datasets.sh                 # list flagged datasets
#   bash tools/find_low_vertex_datasets.sh --verbose       # show medians + reasoning
#   bash tools/find_low_vertex_datasets.sh --threshold 50  # change cutoff (default 30)
#
# Pipe into a force-rerun loop (review first, do not auto-run):
#   bash tools/find_low_vertex_datasets.sh > flagged_datasets.txt
#   # inspect flagged_datasets.txt, then for each dataset_id decide rerun strategy
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

THRESHOLD_PCT=30
VERBOSE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --verbose)   VERBOSE=true; shift ;;
        --threshold) THRESHOLD_PCT=$2; shift 2 ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! [[ "$THRESHOLD_PCT" =~ ^[0-9]+$ ]] || [ "$THRESHOLD_PCT" -le 0 ] || [ "$THRESHOLD_PCT" -ge 100 ]; then
    echo "Error: --threshold must be an integer in (0, 100), got '$THRESHOLD_PCT'" >&2
    exit 1
fi

SCRIPTDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$SCRIPTDIR/config/cluster.sh"
case "$MMB_OUTPUT_ROOT" in
    /*) RUNS_ROOT=$MMB_OUTPUT_ROOT ;;
    *)  RUNS_ROOT=$SCRIPTDIR/$MMB_OUTPUT_ROOT ;;
esac

if [ ! -d "$RUNS_ROOT" ]; then
    echo "Error: $RUNS_ROOT does not exist" >&2
    exit 1
fi

# Known observer prefixes (must include underscore variants present in prepareGenerators.m)
OBSERVERS=(1931_2deg 1964_10deg cfb_2deg cfb_10deg lms_2deg lms_10deg)

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Collect (observer, dataset_id, verts) for every DONE dataset_id.
for dir in "$RUNS_ROOT"/*/; do
    [ -d "$dir" ] || continue
    dataset_id=$(basename "$dir")

    summary=$(ls "$dir"results/*_summary.txt 2>/dev/null | head -1)
    [ -n "$summary" ] && [ -f "$summary" ] || continue

    verts=$(awk '/^Boundary vertices:/ {print $NF; exit}' "$summary" 2>/dev/null || true)
    [[ "$verts" =~ ^[0-9]+$ ]] || continue

    observer=""
    for obs in "${OBSERVERS[@]}"; do
        if [[ "$dataset_id" == "$obs"_* ]]; then
            observer=$obs
            break
        fi
    done
    [ -n "$observer" ] || continue

    printf "%s\t%s\t%s\n" "$observer" "$dataset_id" "$verts" >> "$tmpfile"
done

if [ ! -s "$tmpfile" ]; then
    $VERBOSE && echo "No DONE dataset_ids found in $RUNS_ROOT." >&2
    exit 0
fi

# Compute per-observer median.
declare -A medians
declare -A counts
for obs in "${OBSERVERS[@]}"; do
    median=$(awk -v o="$obs" -F'\t' '$1==o {print $3}' "$tmpfile" | sort -n | awk '
        { v[NR] = $1 + 0 }
        END {
            if (NR == 0) { exit }
            if (NR % 2 == 1) {
                print v[(NR + 1) / 2]
            } else {
                printf "%d\n", (v[NR/2] + v[NR/2 + 1]) / 2
            }
        }
    ')
    cnt=$(awk -v o="$obs" -F'\t' '$1==o' "$tmpfile" | wc -l | tr -d ' ')
    [ -n "$median" ] && medians[$obs]=$median
    counts[$obs]=$cnt
done

# Flag datasets below threshold. Emit to stdout.
flagged=0
total=0
while IFS=$'\t' read -r obs dataset_id verts; do
    total=$((total + 1))
    med=${medians[$obs]:-}
    [ -n "$med" ] || continue
    thresh=$(( THRESHOLD_PCT * med / 100 ))
    if [ "$verts" -lt "$thresh" ]; then
        if $VERBOSE; then
            printf "FLAG  %-48s verts=%-8s observer=%-12s median=%-8s threshold=%s\n" \
                "$dataset_id" "$verts" "$obs" "$med" "$thresh" >&2
        fi
        echo "$dataset_id"
        flagged=$((flagged + 1))
    fi
done < <(sort -t$'\t' -k1,1 -k3,3n "$tmpfile")

if $VERBOSE; then
    echo "" >&2
    echo "Per-observer medians (threshold = ${THRESHOLD_PCT}% of median):" >&2
    for obs in "${OBSERVERS[@]}"; do
        med=${medians[$obs]:-}
        cnt=${counts[$obs]:-0}
        if [ -n "$med" ]; then
            printf "  %-12s n=%-4s median=%-8s flag-threshold=%s\n" \
                "$obs" "$cnt" "$med" "$((THRESHOLD_PCT * med / 100))" >&2
        elif [ "$cnt" -gt 0 ]; then
            printf "  %-12s n=%-4s median=<none>\n" "$obs" "$cnt" >&2
        fi
    done
    echo "" >&2
    echo "Flagged $flagged of $total DONE dataset_ids." >&2
fi
