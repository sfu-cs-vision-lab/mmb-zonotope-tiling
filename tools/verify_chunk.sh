#!/bin/bash
# tools/verify_chunk.sh  Content-verify a single CUDA kernel output file.
#
# Check the embedded input filename, chunk index, row count, finite
# coordinates and completion footer. With --generators, also compare the
# input payload hash. Job scripts call this before accepting output and
# again before building the hull.
#
# This is the promotion check for gpu_chunk.sh/single_gpu.sh (a chunk that
# fails is never renamed to its canonical name) and the hull preflight
# re-check. It never trusts a filename or a file count alone.
#
# Usage:
#   verify_chunk.sh <file> [--dataset-id DATASET_ID] [--chunk K] [--nchunks N]
#                   [--require-footer] [--generators PATH]
#
#   --dataset-id DATASET_ID       expected dataset_id. Default: derived from the filename
#   --chunk K         expected chunk index. Default: derived from filename
#   --nchunks N       expected total chunks (checked when file has chunk line)
#   --require-footer  fail if the "% complete" footer is absent (use for all
#                     output from this kernel)
#   --generators PATH  Generation check: the kernel echoes the
#                     generators file's "% payload_sha256=" header line into its
#                     output. With this option the embedded sha must be
#                     present AND equal the sha of PATH's current numeric
#                     payload. A chunk computed from any other generators file
#                     generation fails here, at promotion, not at the hull.
#
# Exit: 0 = verified, 1 = FAILED (reasons on stderr), 2 = usage error
#
# Copyright 2026 Alex Forsythe and Brian Funt. Simon Fraser University.

set -euo pipefail

FILE=""
EXP_DATASET_ID=""
EXP_CHUNK=""
EXP_NCHUNKS=""
REQUIRE_FOOTER=false
COLORDATA=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dataset-id)           EXP_DATASET_ID=$2; shift 2 ;;
        --chunk)          EXP_CHUNK=$2; shift 2 ;;
        --nchunks)        EXP_NCHUNKS=$2; shift 2 ;;
        --require-footer) REQUIRE_FOOTER=true; shift ;;
        --generators)      COLORDATA=$2; shift 2 ;;
        -*)               echo "verify_chunk: unknown option $1" >&2; exit 2 ;;
        *)                FILE=$1; shift ;;
    esac
done

if [ -z "$FILE" ]; then
    echo "Usage: verify_chunk.sh <file> [--dataset-id DATASET_ID] [--chunk K] [--nchunks N] [--require-footer]" >&2
    exit 2
fi

fail() { echo "verify_chunk FAIL [$FILE]: $*" >&2; exit 1; }

[ -f "$FILE" ] || fail "file does not exist"
[ -s "$FILE" ] || fail "file is empty"

base=$(basename "$FILE")

# Derive expectations from the filename (name is a claim, not truth)
# Staging files (.staging.*) don't carry a canonical name yet. For those the
# caller MUST supply --dataset-id (and --chunk for array chunks). Verification then
# runs purely against the explicit expectations, and the canonical name is
# only created by the promotion mv after this verification passes.
name_dataset_id=""
name_chunk=""
case "$base" in
    mmb_*_chunk*.txt)
        name_dataset_id=${base#mmb_}
        name_dataset_id=${name_dataset_id%_chunk*.txt}
        name_chunk=${base##*_chunk}
        name_chunk=${name_chunk%.txt}
        ;;
    mmb_*.txt)
        name_dataset_id=${base#mmb_}
        name_dataset_id=${name_dataset_id%.txt}
        ;;
    *)
        if [ -z "$EXP_DATASET_ID" ]; then
            fail "unrecognized kernel output filename pattern: $base (staging files need --dataset-id)"
        fi
        name_dataset_id=$EXP_DATASET_ID
        name_chunk=$EXP_CHUNK
        ;;
esac
[ -n "$EXP_DATASET_ID" ]  || EXP_DATASET_ID=$name_dataset_id
[ -n "$EXP_CHUNK" ] || EXP_CHUNK=$name_chunk

# Filename must agree with expectations (catches misplaced/renamed files)
if [ "$name_dataset_id" != "$EXP_DATASET_ID" ]; then
    fail "filename dataset_id '$name_dataset_id' != expected dataset_id '$EXP_DATASET_ID'"
fi
if [ -n "$EXP_CHUNK" ] && [ -n "$name_chunk" ] && [ "$name_chunk" != "$EXP_CHUNK" ]; then
    fail "filename chunk '$name_chunk' != expected chunk '$EXP_CHUNK'"
fi

# Single awk pass: header fields, row count, field validation, footer
# Emits "KEY VALUE" lines consumed below. Fatal row problems are counted.
result=$(awk '
    BEGIN { rows = 0; badrows = 0; header_v = -1; hdr_chunk = -1; hdr_nchunks = -1
            footer_v = -1; input_base = ""; after_footer = 0; first_bad_line = 0 }
    /^%/ {
        if ($0 ~ /^% Input: /) {
            p = $0; sub(/^% Input: /, "", p)
            nslash = split(p, parts, "/")
            input_base = parts[nslash]
        }
        if (match($0, /vertices=[0-9]+/) && $0 !~ /^% complete/) {
            v = substr($0, RSTART + 9, RLENGTH - 9); header_v = v + 0
        }
        if (match($0, /chunk=[0-9]+, nchunks=[0-9]+/)) {
            s = substr($0, RSTART, RLENGTH)
            split(s, kv, /[=,]/)
            hdr_chunk = kv[2] + 0
            sub(/^[ ]*/, "", kv[4]); hdr_nchunks = kv[4] + 0
        }
        if ($0 ~ /^% complete vertices=[0-9]+/) {
            match($0, /vertices=[0-9]+/)
            footer_v = substr($0, RSTART + 9, RLENGTH - 9) + 0
        }
        if (match($0, /^% payload_sha256=[0-9a-f]{64}/)) {
            embedded_sha = substr($0, 18, 64)
        }
        next
    }
    {
        if (footer_v >= 0) { after_footer++ }
        rows++
        ok = (NF == 3)
        if (ok) for (i = 1; i <= 3; i++) {
            if ($i !~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/) { ok = 0; break }
        }
        if (!ok) { badrows++; if (!first_bad_line) first_bad_line = NR }
    }
    END {
        print "ROWS " rows
        print "BADROWS " badrows
        print "FIRSTBAD " first_bad_line
        print "HEADER_V " header_v
        print "HDR_CHUNK " hdr_chunk
        print "HDR_NCHUNKS " hdr_nchunks
        print "FOOTER_V " footer_v
        print "AFTER_FOOTER " after_footer
        print "INPUT_BASE " input_base
        print "EMBEDDED_SHA " embedded_sha
    }
' "$FILE")

get() { echo "$result" | awk -v k="$1" '$1 == k { print $2 }'; }

rows=$(get ROWS)
badrows=$(get BADROWS)
firstbad=$(get FIRSTBAD)
header_v=$(get HEADER_V)
hdr_chunk=$(get HDR_CHUNK)
hdr_nchunks=$(get HDR_NCHUNKS)
footer_v=$(get FOOTER_V)
after_footer=$(get AFTER_FOOTER)
input_base=$(get INPUT_BASE)

# 1. Provenance: embedded Input must name this dataset_id's generators file
[ -n "$input_base" ] || fail "no '% Input:' line in header (not a kernel output, or header truncated)"
expected_input="generators_${EXP_DATASET_ID}.txt"
if [ "$input_base" != "$expected_input" ]; then
    fail "embedded Input '$input_base' != expected '$expected_input' (WRONG-PROVENANCE content)"
fi

# 2. Chunk identity: embedded chunk/nchunks vs filename and expectations
if [ -n "$name_chunk" ]; then
    [ "$hdr_chunk" -ge 0 ] || fail "filename says chunk $name_chunk but header has no chunk line"
    [ "$hdr_chunk" -eq "$name_chunk" ] || fail "embedded chunk=$hdr_chunk != filename chunk $name_chunk"
    if [ -n "$EXP_NCHUNKS" ] && [ "$hdr_nchunks" -ne "$EXP_NCHUNKS" ]; then
        fail "embedded nchunks=$hdr_nchunks != expected $EXP_NCHUNKS"
    fi
else
    [ "$hdr_chunk" -lt 0 ] || fail "single-GPU filename but header claims chunk=$hdr_chunk"
fi

# 3. Count: header promise vs actual data rows
[ "$header_v" -ge 0 ] || fail "no 'vertices=' count in header (header truncated)"
[ "$rows" -eq "$header_v" ] || fail "data rows ($rows) != header vertices=$header_v (TRUNCATED or padded)"

# 4. Row integrity: 3 finite numeric fields each
if [ "$badrows" -gt 0 ]; then
    fail "$badrows malformed/non-finite data row(s), first at line $firstbad"
fi

# 5. Completion footer
if [ "$footer_v" -ge 0 ]; then
    [ "$footer_v" -eq "$header_v" ] || fail "footer vertices=$footer_v != header vertices=$header_v"
    [ "$after_footer" -eq 0 ] || fail "$after_footer data row(s) after the completion footer"
elif $REQUIRE_FOOTER; then
    fail "missing '% complete' footer"
fi

# 6. Generation identity: the embedded generators file payload sha must match the
# CURRENT generators file's payload. The canonical form is the non-comment,
# non-empty lines joined by \n with no trailing newline, the convention of
# prepareGenerators and the dataset check. This closes cross-generation chunk
# mixing at promotion.
if [ -n "$COLORDATA" ]; then
    [ -f "$COLORDATA" ] || fail "--generators file not found: $COLORDATA"
    embedded_sha=$(get EMBEDDED_SHA)
    if [ -z "$embedded_sha" ]; then
        fail "missing embedded '%% payload_sha256=' header"
    fi
    if command -v sha256sum >/dev/null 2>&1; then HASHER="sha256sum"; else HASHER="shasum -a 256"; fi
    actual_sha=$(awk '!/^[[:space:]]*%/ && NF>0 {if(n++)printf "\n"; printf "%s",$0}' "$COLORDATA" | $HASHER | awk '{print $1}')
    if [ "$embedded_sha" != "$actual_sha" ]; then
        fail "GENERATION MISMATCH: chunk was computed from generators file payload ${embedded_sha:0:12}..., current generators file is ${actual_sha:0:12}..."
    fi
fi

echo "verify_chunk OK [$base]: dataset_id=$EXP_DATASET_ID${name_chunk:+ chunk=$name_chunk/$hdr_nchunks} vertices=$rows footer=$([ "$footer_v" -ge 0 ] && echo yes || echo no)"
exit 0
