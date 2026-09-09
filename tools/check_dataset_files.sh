#!/bin/bash
# tools/check_dataset_files.sh  Check dataset files against their expected inputs.
#
# Checks input filenames, dataset identifiers, partial-output markers, row
# counts and repeated conversion markers. It can run while jobs are active.
#
# Usage: bash tools/check_dataset_files.sh [--root DIR] [--allow-missing] [--quiet]
#   --root DIR       Output directory. Default: ./runs_output.
#   --allow-missing  Allow datasets that do not yet have results.
#
# Exit 0 if all checks pass, otherwise 1 with details on standard output.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$SCRIPTDIR/config/cluster.sh"
ROOT=$MMB_OUTPUT_ROOT
ALLOW_MISSING=false
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        --root)          ROOT=$2; shift 2 ;;
        --allow-missing) ALLOW_MISSING=true; shift ;;
        --quiet)         QUIET=true; shift ;;
        *) echo "check_dataset_files: unknown option $1" >&2; exit 2 ;;
    esac
done

[ -d "$ROOT" ] || { echo "check_dataset_files: root not found: $ROOT" >&2; exit 2; }

violations=0
dataset_ids=0

report() {  # report TYPE DATASET_ID DETAIL...
    local type=$1 dataset_id=$2; shift 2
    echo "VIOLATION $type $dataset_id $*"
    violations=$((violations + 1))
}

# Extract the dataset_id embedded in an mmb_* result/chunk filename, or "" if the
# name doesn't match a known filename pattern.
dataset_id_of() {
    local b=$1
    case "$b" in
        mmb_*_chunk*.txt)     b=${b#mmb_}; echo "${b%_chunk*.txt}" ;;
        mmb_*_summary.txt)    b=${b#mmb_}; echo "${b%_summary.txt}" ;;
        mmb_*_vertices.csv)   b=${b#mmb_}; echo "${b%_vertices.csv}" ;;
        mmb_*_faces.csv)      b=${b#mmb_}; echo "${b%_faces.csv}" ;;
        mmb_*_gate.json)      b=${b#mmb_}; echo "${b%_gate.json}" ;;
        mmb_*.txt)            b=${b#mmb_}; echo "${b%.txt}" ;;
        *)                    echo "" ;;
    esac
}

for dir in "$ROOT"/*/; do
    [ -d "$dir" ] || continue
    dataset_id=$(basename "$dir")
    dataset_ids=$((dataset_ids + 1))

    # Flag files whose names identify a different dataset from their directory.
    while IFS= read -r f; do
        b=$(basename "$f")
        ns=$(dataset_id_of "$b")
        [ -n "$ns" ] || continue
        if [ "$ns" != "$dataset_id" ]; then
            report ALIEN_FILE "$dataset_id" "$f (names dataset_id '$ns')"
        fi
    done < <(find "$dir/results" "$dir/chunks" "$dir" -maxdepth 1 -type f -name 'mmb_*' 2>/dev/null | sort -u)

    summary="$dir/results/mmb_${dataset_id}_summary.txt"
    if [ ! -f "$summary" ]; then
        $ALLOW_MISSING || report MISSING_SUMMARY "$dataset_id" "no canonical summary at results/mmb_${dataset_id}_summary.txt"
        continue
    fi

    # INPUT_MISMATCH: content must name its own generators file
    input_base=$(awk '/^% Input: /{n=split($3,p,"/"); print p[n]; exit}' "$summary")
    if [ -z "$input_base" ]; then
        report INPUT_MISMATCH "$dataset_id" "summary has no '% Input:' line"
    elif [ "$input_base" != "generators_${dataset_id}.txt" ]; then
        report INPUT_MISMATCH "$dataset_id" "summary Input is '$input_base' (WRONG PROBLEM under canonical name)"
    fi

    # PARTIAL_HEADER: merged hulls carry chunk 0's header
    chunkline=$(awk '/^% chunk=/{print; exit}' "$summary")
    if [ -n "$chunkline" ]; then
        k=$(echo "$chunkline" | sed -E 's/^% chunk=([0-9]+),.*/\1/')
        if [ "$k" != "0" ]; then
            report PARTIAL_HEADER "$dataset_id" "summary header from chunk $k, not 0 (partial-set hull)"
        fi
    fi

    # DOUBLE_CONVERTED: more than one conversion marker
    nconv=$(grep -c '^% CONVERTED' "$summary" || true)
    if [ "$nconv" -gt 1 ]; then
        report DOUBLE_CONVERTED "$dataset_id" "$nconv CONVERTED footers"
    fi

    # COUNT_MISMATCH: summary count vs actual CSV rows
    vcsv="$dir/results/mmb_${dataset_id}_vertices.csv"
    if [ -f "$vcsv" ]; then
        sv=$(awk '/^Boundary vertices:/{print $NF; exit}' "$summary")
        rows=$(awk '!/^%/ && NF > 0 {n++} END {print n+0}' "$vcsv")
        if [ -n "$sv" ] && [ "$rows" -ne "$sv" ]; then
            report COUNT_MISMATCH "$dataset_id" "vertices.csv has $rows rows, summary says $sv"
        fi
    fi
done

if [ "$violations" -gt 0 ]; then
    echo "check_dataset_files: $violations violation(s) across $dataset_ids dataset_id(s)" >&2
    exit 1
fi
$QUIET || echo "check_dataset_files: $dataset_ids dataset_id(s) clean (content matches every canonical name)"
exit 0
