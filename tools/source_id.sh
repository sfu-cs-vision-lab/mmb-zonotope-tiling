#!/bin/bash
# tools/source_id.sh  Print a stable identifier for the source tree in use.
#
#   bash tools/source_id.sh
#
# Validation certificates and saved check results record which code produced them.
# A Git checkout is identified by its commit. An archive extracted from a
# release ZIP has no Git metadata, so it is identified by the packaged
# source record instead, and a tree with neither is hashed directly.
#
# Output is one line, in the first form that applies:
#   git:<40-hex commit>[+dirty]   Git checkout. +dirty if tracked files differ
#   archive:<64-hex>              SHA-256 of the packaged SHA256SUMS.txt
#   tree:<64-hex>                 SHA-256 over the hashes of the source files
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" | awk '{print $1}'
    else
        shasum -a 256 "$@" | awk '{print $1}'
    fi
}

if command -v git >/dev/null 2>&1 &&
        git_root=$(git rev-parse --show-toplevel 2>/dev/null) &&
        [ "$git_root" -ef "$ROOT" ]; then
    commit=$(git rev-parse HEAD 2>/dev/null)
    if [ -n "$commit" ]; then
        if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            echo "git:${commit}+dirty"
        else
            echo "git:${commit}"
        fi
        exit 0
    fi
fi

if [ -f SHA256SUMS.txt ]; then
    echo "archive:$(sha256_of SHA256SUMS.txt)"
    exit 0
fi

# Hash the source files themselves, in a fixed order, so two identical
# trees produce the same identifier regardless of timestamps or location.
files=$(find src cuda slurm tools runs config tests/hpc mmb_run.sh -type f \
    \( -name '*.m' -o -name '*.sh' -o -name '*.cu' -o -name 'Makefile' \) \
    2>/dev/null | LC_ALL=C sort)
if [ -z "$files" ]; then
    echo "tree:unknown"
    exit 0
fi
# shellcheck disable=SC2086
echo "tree:$(sha256_of $files | LC_ALL=C sort | sha256_of /dev/stdin)"
