# tools/env.sh  Load the configured tools in an interactive cluster shell.
#
# Run source tools/env.sh in each new shell. It clears existing modules,
# loads those listed in config/cluster.sh and checks the resolved versions.
# Compute jobs load their own modules.
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

# Environment changes need sourcing, so refuse to be executed.
if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "This file must be sourced:  source tools/env.sh" >&2
    exit 1
fi

_MMB_ENV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_MMB_ROOT=$(cd "$_MMB_ENV_DIR/.." && pwd)

. "$_MMB_ROOT/config/cluster.sh"

if ! command -v module >/dev/null 2>&1 && ! type module >/dev/null 2>&1; then
    echo "env.sh: no 'module' command. This is not a cluster shell" >&2
    return 1
fi

module --force purge >/dev/null 2>&1 || module purge >/dev/null 2>&1 || true
if ! module load $MMB_MODULES_GPU $MMB_MODULES_MATLAB; then
    echo "env.sh: module load FAILED. Check MMB_MODULES_GPU and" >&2
    echo "MMB_MODULES_MATLAB in config/cluster.sh against 'module avail'." >&2
    return 1
fi

bash "$_MMB_ENV_DIR/check_env.sh" || return 1
