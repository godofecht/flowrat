#!/usr/bin/env bash
# Compile one Flow file and report only what matters.
#
# `flow compile` does not link the window runtime, so the gfx entry point
# always ends in a pile of missing _flow_gfx_* symbols. That is expected and
# is not a fault in the code. Everything else is real, including a link error
# for a function the file forgot to import: an earlier version of this script
# dropped the whole linker report whenever it appeared, which hid exactly that
# and reported OK on a file that could not be built.
source "$(dirname "$0")/env.sh"
set +e
target="${1:?usage: check.sh <file.flow>}"
out=$("$FLOW_HOME/flow" compile "$RATVILLE_ROOT/$target" 2>&1)

# Undefined symbols that are not the graphics runtime.
bad_syms=$(echo "$out" | grep -oE '"_[A-Za-z0-9_]+", referenced from' \
  | grep -v '"_flow_gfx_' )
gfx_only=0
if echo "$out" | grep -q "_flow_gfx_" && [ -z "$bad_syms" ]; then
    gfx_only=1
fi

trimmed=$(echo "$out" | sed '/Undefined symbols for architecture/,$d')
real=$(echo "$trimmed" \
  | grep -vE "Falling back|^Overload resolution|warning:|^ +\||^ +\^|generated\.|ignoring duplicate" \
  | grep -E "❌|error:|^Error")

if [ -n "$real" ] || { [ -n "$bad_syms" ] && [ "$gfx_only" -eq 0 ]; }; then
    echo "$trimmed" | grep -vE "Falling back|^Overload resolution" | tail -20
    if [ -n "$bad_syms" ]; then
        echo "undefined, and not the graphics runtime:"
        echo "$bad_syms"
    fi
    echo "FAIL  $target"
    exit 1
fi
if [ "$gfx_only" -eq 1 ]; then
    echo "OK  $target  (link needs the gfx runtime; use flow gfx to build it)"
else
    echo "OK  $target"
fi
