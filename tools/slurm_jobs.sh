#!/bin/bash
# Match Slurm jobs to the output directory managed by the caller.
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

mmb_job_tag() {
    python3 -c 'import hashlib, os, sys; print("mmb:" + hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).hexdigest())' "$1"
}

mmb_squeue() {
    local tag=$1 format=$2 owner line queue_user queue_rows
    shift 2
    queue_user=${USER:-$(id -un)} || return 1
    if ! queue_rows=$(squeue -u "$queue_user" -h "$@" -o "%k|$format"); then
        echo "ERROR: cannot read the Slurm queue. Check the scheduler connection and retry." >&2
        return 1
    fi
    while IFS='|' read -r owner line; do
        if [ "$owner" = "$tag" ]; then
            printf '%s\n' "$line"
        fi
    done <<< "$queue_rows"
}
