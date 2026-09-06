#!/usr/bin/env bash
# Build and run FlowRat's native gfx application through Flow's Python-host
# MLIR -> LLVM backend, then link the same native gfx ABI used by `flow gfx`.
#
# This is intentionally local-only. It does not invoke CI.

set -euo pipefail

source "$(dirname "$0")/env.sh"

PYTHONPATH="$FLOW_HOME/src${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH

BUILD_DIR="${FLOWRAT_MLIR_BUILD_DIR:-$RATVILLE_ROOT/build/mlir}"
RUNTIME_C_DIR="$BUILD_DIR/runtime_flow"
LL_FILE="$BUILD_DIR/flowrat.gfx.ll"
EXE_FILE="$BUILD_DIR/flowrat.gfx.mlir"

mkdir -p "$BUILD_DIR" "$RUNTIME_C_DIR"

if ! command -v python3 >/dev/null 2>&1; then
    echo "flowrat: python3 is required for the Python-host MLIR backend" >&2
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "flowrat: clang is required to link the MLIR/LLVM output" >&2
    exit 1
fi

python3 -m flow.transpiler \
    "$RATVILLE_ROOT/flowrat.flow" \
    --mlir --llvm --lenient \
    -o "$LL_FILE"

runtime_flow_sources=()

for source in "$FLOW_HOME"/lib/runtime/*.flow; do
    [ -f "$source" ] || continue

    base="$(basename "$source" .flow)"

    case "$base" in
        shader_host|gfx_record)
            continue
            ;;
        gpu_memory_stub)
            if [ "$(uname -s)" = "Darwin" ]; then
                continue
            fi
            ;;
    esac

    output="$RUNTIME_C_DIR/$base.c"

    python3 -m flow.transpiler \
        "$source" \
        --c --library --lenient \
        -o "$output"

    runtime_flow_sources+=("$output")
done

runtime_sources=(
    "$FLOW_HOME/runtime/flow_python_embed.c"
    "$FLOW_HOME/runtime/flow_concurrency.c"
    "$FLOW_HOME/runtime/flow_fiber.c"
    "$FLOW_HOME/runtime/flow_fctx_init.c"
    "$FLOW_HOME/runtime/flow_netpoll.c"
    "$FLOW_HOME/runtime/flow_netpoll_fiber.c"
    "$FLOW_HOME/runtime/flow_http_bench.c"
    "$FLOW_HOME/runtime/flow_tcp.c"
    "$FLOW_HOME/runtime/flow_race.c"
    "$FLOW_HOME/runtime/flow_cont.c"
    "$FLOW_HOME/runtime/flow_rt_support.c"
    "$FLOW_HOME/runtime/flow_rt_task_store.c"
    "$FLOW_HOME/runtime/flow_rt_fiber_async.c"
    "$FLOW_HOME/runtime/flow_rt_parallel.c"
    "$FLOW_HOME/runtime/flow_rt_cchan.c"
    "$FLOW_HOME/runtime/flow_rt_sysinfo.c"
    "$FLOW_HOME/runtime/flow_rt_crypto.c"
    "$FLOW_HOME/runtime/flow_tls.c"
)

case "$(uname -m)" in
    arm64|aarch64)
        runtime_sources+=("$FLOW_HOME/runtime/flow_fctx_arm64.S")
        ;;
    x86_64|amd64)
        runtime_sources+=("$FLOW_HOME/runtime/flow_fctx_x86_64.S")
        ;;
esac

common_flags=(
    -O2
    -fno-omit-frame-pointer
    -DFLOW_HAS_OPENSSL=0
    -I"$FLOW_HOME/runtime"
    -pthread
)

case "$(uname -s)" in
    Darwin)
        clang "${common_flags[@]}" \
            "$LL_FILE" \
            "$FLOW_HOME/runtime/gfx_macos.m" \
            "$FLOW_HOME/runtime/gpu_metal.m" \
            "${runtime_sources[@]}" \
            "${runtime_flow_sources[@]}" \
            -framework Cocoa \
            -framework CoreGraphics \
            -framework QuartzCore \
            -framework CoreText \
            -framework Metal \
            -framework Foundation \
            -lm \
            -o "$EXE_FILE"
        ;;
    Linux)
        if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists sdl2; then
            echo "flowrat: SDL2 development files are required on Linux" >&2
            exit 1
        fi

        read -r -a sdl_cflags <<<"$(pkg-config --cflags sdl2)"
        read -r -a sdl_libs <<<"$(pkg-config --libs sdl2)"

        clang "${common_flags[@]}" \
            "${sdl_cflags[@]}" \
            "$LL_FILE" \
            "$FLOW_HOME/runtime/gfx_linux.c" \
            "${runtime_sources[@]}" \
            "${runtime_flow_sources[@]}" \
            "${sdl_libs[@]}" \
            -lm \
            -o "$EXE_FILE"
        ;;
    *)
        echo "flowrat: tools/run-mlir.sh currently supports macOS and Linux" >&2
        exit 1
        ;;
esac

echo "FlowRat MLIR binary: $EXE_FILE"
exec "$EXE_FILE" "$@"
