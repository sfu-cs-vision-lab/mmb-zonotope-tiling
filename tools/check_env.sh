#!/bin/bash
# tools/check_env.sh  Verify the shell resolves the configured toolchain.
#
# Checks the executables found on PATH against MMB_EXPECT_GCC,
# MMB_EXPECT_NVCC and MMB_EXPECT_MATLAB from config/cluster.sh.
#
# Exit: 0 = toolchain resolved, 1 = wrong or missing (details printed).
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/config/cluster.sh"

fail=0
report() {  # report NAME EXPECTED ACTUAL
    if [ -n "$3" ] && echo "$3" | grep -q "$2"; then
        printf '  [OK]  %-7s %s\n' "$1" "$3"
    else
        printf '  [BAD] %-7s %s (need: %s)\n' "$1" "${3:-not found}" "$2"
        fail=1
    fi
}

report gcc  "$MMB_EXPECT_GCC"  "$(gcc --version 2>/dev/null | head -1)"
report nvcc "$MMB_EXPECT_NVCC" "$(nvcc --version 2>/dev/null | grep -i release | head -1)"
# Resolve matlab by PATH. The module puts a versioned path first, while a
# bare version-picker wrapper lives at an unversioned path.
report matlab "$MMB_EXPECT_MATLAB" "$(command -v matlab 2>/dev/null)"

if [ "$fail" -ne 0 ]; then
    cat >&2 << 'MSG'

The resolved toolchain does not match config/cluster.sh. Fix:
    source tools/env.sh          (purges, then loads the configured modules)

Check the module environment if you see any of these symptoms.
Module conflicts and filesystem problems can both cause startup errors:
  - matlab drops into a version-selection menu
      the matlab module is not loaded
  - SIGBUS in libicuuc, or "Input/output error" loading a MATLAB plugin
      check the loaded modules and retry. If the error persists, check
      filesystem access and the cluster service status
  - nvcc or gcc "command not found" inside salloc
      modules do not survive node hops; source tools/env.sh in every shell
MSG
    exit 1
fi
echo "toolchain resolved ($MMB_MODULES_GPU $MMB_MODULES_MATLAB)"
