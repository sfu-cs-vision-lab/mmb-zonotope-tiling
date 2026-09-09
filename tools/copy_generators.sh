#!/bin/bash
# tools/copy_generators.sh  Copy supplied inputs into a new output directory.
#
# Usage: bash tools/copy_generators.sh <mmb-data/data> <new-output-directory>
#
# Reads runs/dataset_ids.txt and copies only the listed generator files.
# Check the data archive's checksums before using this command.
# No MATLAB, GPU or scheduler is needed.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

usage() {
    echo "Usage: bash tools/copy_generators.sh <mmb-data/data> <new-output-directory>"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    usage >&2
    exit 2
fi

fail() { echo "ERROR: $*" >&2; exit 1; }

SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATASET_IDS_FILE="$SCRIPTDIR/runs/dataset_ids.txt"
[ -r "$DATASET_IDS_FILE" ] || fail "Cannot read $DATASET_IDS_FILE"
[ -d "$1" ] || fail "Input directory not found: $1"
source_root=$(cd -- "$1" && pwd)
case "$2" in
    /*) target=$2 ;;
    *) target="$PWD/$2" ;;
esac
[ ! -e "$target" ] && [ ! -L "$target" ] || fail "Output path already exists: $target"

# Check every input before creating any output directories.
dataset_ids=()
count=0
seen='|'
while IFS= read -r dataset_id || [ -n "$dataset_id" ]; do
    dataset_id=${dataset_id#"${dataset_id%%[![:space:]]*}"}
    dataset_id=${dataset_id%"${dataset_id##*[![:space:]]}"}
    [ -n "$dataset_id" ] || continue
    case "$dataset_id" in
        .|..|*[!a-zA-Z0-9_.-]*) fail "Invalid dataset ID: $dataset_id" ;;
    esac
    case "$seen" in
        *"|$dataset_id|"*) fail "Repeated dataset ID: $dataset_id" ;;
    esac
    input="$source_root/$dataset_id/generators_${dataset_id}.txt"
    [ -f "$input" ] && [ -r "$input" ] || fail "Missing or unreadable input: $input"
    grep -q '^% payload_sha256=' "$input" || fail "Input has no payload hash: $input"
    dataset_ids+=("$dataset_id")
    seen="$seen$dataset_id|"
    count=$((count + 1))
done < "$DATASET_IDS_FILE"
[ "$count" -gt 0 ] || fail "No datasets listed in $DATASET_IDS_FILE"

mkdir -p "$(dirname "$target")"
mkdir "$target"
for dataset_id in "${dataset_ids[@]}"; do
    mkdir "$target/$dataset_id"
    cp "$source_root/$dataset_id/generators_${dataset_id}.txt" \
       "$target/$dataset_id/generators_${dataset_id}.txt"
done
echo "Copied $count generator files to $target"
