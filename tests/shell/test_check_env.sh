#!/bin/bash
# tests/shell/test_check_env.sh
# Test environment checks with substitute gcc, nvcc and matlab commands.

set -u

SCRIPTDIR=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mmb_env.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; failed=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failed=$((failed+1)); echo "  FAIL: $1"; }

mk_tool() {  # NAME OUTPUT
    printf '#!/bin/bash\necho "%s"\n' "$2" > "$TMP/bin/$1"
    chmod +x "$TMP/bin/$1"
}

# 1. Pinned toolchain resolved -> exit 0
# An environment module system reaches these tests two ways. It exports
# `module` as a shell function, and BASH_ENV makes every non-interactive
# shell re-define it. A function takes precedence over the stub on PATH.
# Close both so the stubbed command is used on a cluster login node too.
unset -f module 2>/dev/null || true
unset BASH_ENV
mkdir -p "$TMP/bin/matlab-2024b.1"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/matlab-2024b.1/matlab"; chmod +x "$TMP/bin/matlab-2024b.1/matlab"
mkdir -p "$TMP/bin"
mk_tool gcc "gcc (Gentoo) 12.3.0"
mk_tool nvcc "Cuda compilation tools, release 12.2, V12.2.140"
if out=$(PATH="$TMP/bin/matlab-2024b.1:$TMP/bin:/usr/bin:/bin" bash "$SCRIPTDIR/tools/check_env.sh" 2>&1); then
    ok "pinned set passes"
else
    bad "pinned set passes"; echo "$out"
fi

# 2. Wrong gcc -> exit 1
mk_tool gcc "gcc (Gentoo) 13.1.0"
if out=$(PATH="$TMP/bin/matlab-2024b.1:$TMP/bin:/usr/bin:/bin" bash "$SCRIPTDIR/tools/check_env.sh" 2>&1); then
    bad "wrong gcc must fail"
else
    ok "wrong gcc fails"
fi
mk_tool gcc "gcc (Gentoo) 12.3.0"

# 3. Matlab resolving to an unversioned wrapper path (the menu picker) -> fail
mkdir -p "$TMP/bin/wrapper"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/wrapper/matlab"; chmod +x "$TMP/bin/wrapper/matlab"
if out=$(PATH="$TMP/bin/wrapper:$TMP/bin:/usr/bin:/bin" bash "$SCRIPTDIR/tools/check_env.sh" 2>&1); then
    bad "wrapper matlab must fail"
else
    echo "$out" | grep -q "\[BAD\] matlab" && ok "unversioned matlab wrapper caught" || bad "unversioned matlab wrapper caught"
fi

# 4. Nothing resolves -> fail, every row BAD
if out=$(PATH="/usr/bin:/bin" bash "$SCRIPTDIR/tools/check_env.sh" 2>&1); then
    bad "bare shell must fail"
else
    n=$(echo "$out" | grep -c "\[BAD\]")
    [ "$n" -ge 2 ] && ok "bare shell reports missing tools ($n BAD rows)" || bad "bare shell reports missing tools"
fi

echo ""
echo "check_env: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
