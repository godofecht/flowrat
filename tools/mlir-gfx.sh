#!/usr/bin/env bash
# Compile a Flow gfx program through Flow's MLIR backend, then link it against
# the same native runtime ABI used by `flow gfx`.
set -euo pipefail

source "$(dirname "$0")/env.sh"

PROGRAM="$RATVILLE_ROOT/flowrat.flow"
RUN=1

while [ $# -gt 0 ]; do
    case "$1" in
        --build-only|--no-run)
            RUN=0
            shift
            ;;
        --program)
            PROGRAM="${2:-}"
            if [ -z "$PROGRAM" ]; then
                echo "flowrat: --program requires a .flow file" >&2
                exit 2
            fi
            shift 2
            ;;
        --program=*)
            PROGRAM="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "usage: tools/mlir-gfx.sh [--build-only] [--program FILE]"
            exit 0
            ;;
        *)
            echo "flowrat: unknown MLIR runner option: $1" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$PROGRAM" ]; then
    echo "flowrat: program not found: $PROGRAM" >&2
    exit 1
fi

FLOW_ROOT="$FLOW_HOME"
export PYTHONPATH="$FLOW_ROOT/src${PYTHONPATH:+:$PYTHONPATH}"

if ! python3 -c 'import flow.transpiler' 2>/dev/null; then
    echo "flowrat: cannot import Flow compiler from $FLOW_ROOT/src" >&2
    exit 1
fi

resolve_llvm_path() {
    if [ -n "${LLVM_PATH:-}" ] && [ -x "$LLVM_PATH/mlir-opt" ]; then
        return
    fi
    if command -v mlir-opt >/dev/null 2>&1; then
        LLVM_PATH="$(dirname "$(command -v mlir-opt)")"
        return
    fi
    if command -v brew >/dev/null 2>&1; then
        local prefix
        prefix="$(brew --prefix llvm 2>/dev/null || true)"
        if [ -n "$prefix" ] && [ -x "$prefix/bin/mlir-opt" ]; then
            LLVM_PATH="$prefix/bin"
            return
        fi
    fi
    echo "flowrat: MLIR tools not found; install LLVM or set LLVM_PATH" >&2
    exit 1
}

resolve_llvm_path
export LLVM_PATH
export PATH="$LLVM_PATH:$PATH"

for tool in mlir-opt mlir-translate; do
    if [ ! -x "$LLVM_PATH/$tool" ]; then
        echo "flowrat: missing $LLVM_PATH/$tool" >&2
        exit 1
    fi
done

BUILD_DIR="${FLOWRAT_MLIR_BUILD_DIR:-$RATVILLE_ROOT/build/mlir}"
RUNTIME_FLOW_DIR="$BUILD_DIR/runtime_flow"
mkdir -p "$BUILD_DIR" "$RUNTIME_FLOW_DIR"

BASENAME="$(basename "$PROGRAM" .flow)"
LLVM_IR="$BUILD_DIR/$BASENAME.ll"
EXE="$BUILD_DIR/$BASENAME"
FLOWC_ERR="$BUILD_DIR/.flowc_err"

# Keep package resolution identical to normal `flow run`/`flow gfx`.
python3 -m flow.package sync --program "$PROGRAM" >/dev/null

echo "flowrat: FLOW -> MLIR -> LLVM IR"
if ! python3 -m flow.transpiler "$PROGRAM" --mlir --llvm --lenient -o "$LLVM_IR" 2>"$FLOWC_ERR"; then
    cat "$FLOWC_ERR" >&2
    exit 1
fi

# Native runtime set mirrored from Flow's canonical gfx/concurrency link path.
CONC_SOURCES=(
    "$FLOW_ROOT/runtime/flow_concurrency.c"
    "$FLOW_ROOT/runtime/flow_fiber.c"
    "$FLOW_ROOT/runtime/flow_fctx_init.c"
    "$FLOW_ROOT/runtime/flow_netpoll.c"
    "$FLOW_ROOT/runtime/flow_netpoll_fiber.c"
    "$FLOW_ROOT/runtime/flow_http_bench.c"
    "$FLOW_ROOT/runtime/flow_tcp.c"
    "$FLOW_ROOT/runtime/flow_race.c"
    "$FLOW_ROOT/runtime/flow_cont.c"
    "$FLOW_ROOT/runtime/flow_rt_support.c"
    "$FLOW_ROOT/runtime/flow_rt_task_store.c"
    "$FLOW_ROOT/runtime/flow_rt_fiber_async.c"
    "$FLOW_ROOT/runtime/flow_rt_parallel.c"
    "$FLOW_ROOT/runtime/flow_rt_cchan.c"
    "$FLOW_ROOT/runtime/flow_rt_sysinfo.c"
    "$FLOW_ROOT/runtime/flow_rt_crypto.c"
    "$FLOW_ROOT/runtime/flow_tls.c"
)

case "$(uname -m)" in
    arm64|aarch64) CONC_SOURCES+=("$FLOW_ROOT/runtime/flow_fctx_arm64.S") ;;
    x86_64|amd64) CONC_SOURCES+=("$FLOW_ROOT/runtime/flow_fctx_x86_64.S") ;;
esac

CONC_CFLAGS=("-I$FLOW_ROOT/runtime" "-DFLOW_HAS_OPENSSL=0")
CONC_LDFLAGS=("-pthread")

# Preserve FlowRat's parallel-for acceleration when libomp is available.
OMP_PROBE="$BUILD_DIR/.omp_probe.c"
printf 'int main(void){return 0;}\n' > "$OMP_PROBE"
if clang -fopenmp "$OMP_PROBE" -o "$BUILD_DIR/.omp_probe" -lomp >/dev/null 2>&1; then
    CONC_CFLAGS+=("-fopenmp")
    CONC_LDFLAGS+=("-fopenmp" "-lomp")
elif clang -fopenmp "$OMP_PROBE" -o "$BUILD_DIR/.omp_probe" >/dev/null 2>&1; then
    CONC_CFLAGS+=("-fopenmp")
    CONC_LDFLAGS+=("-fopenmp")
elif clang -Xpreprocessor -fopenmp "$OMP_PROBE" -o "$BUILD_DIR/.omp_probe" -lomp >/dev/null 2>&1; then
    CONC_CFLAGS+=("-Xpreprocessor" "-fopenmp")
    CONC_LDFLAGS+=("-Xpreprocessor" "-fopenmp" "-lomp")
fi
rm -f "$OMP_PROBE" "$BUILD_DIR/.omp_probe"

AUDIO_CFLAGS=()
AUDIO_SOURCES=("$FLOW_ROOT/runtime/audio_miniaudio.c")
SKIP_AUDIO_STUB=0
if [ -f "$FLOW_ROOT/third_party/miniaudio.h" ]; then
    AUDIO_CFLAGS+=("-I$FLOW_ROOT/third_party" "-DFLOW_AUDIO_BACKEND_MINIAUDIO")
    SKIP_AUDIO_STUB=1
fi

# Flow's always-linked runtime is itself written partly in Flow. Keep those
# modules on the stable C runtime path while the application is MLIR-compiled.
RUNTIME_FLOW_SOURCES=()
for f in "$FLOW_ROOT"/lib/runtime/*.flow; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .flow)"
    case "$base" in
        shader_host|gfx_record)
            continue
            ;;
        gpu_memory_stub)
            if [ "$(uname -s)" = "Darwin" ]; then
                continue
            fi
            ;;
        audio_device_stub)
            if [ "$SKIP_AUDIO_STUB" = "1" ]; then
                continue
            fi
            ;;
    esac
    out="$RUNTIME_FLOW_DIR/$base.c"
    if ! python3 -m flow.transpiler "$f" --c --library --lenient -o "$out" 2>"$FLOWC_ERR"; then
        echo "flowrat: failed to build Flow runtime module $base.flow" >&2
        cat "$FLOWC_ERR" >&2
        exit 1
    fi
    RUNTIME_FLOW_SOURCES+=("$out")
done

PY_CFLAGS=()
PY_LDFLAGS=()
PY_FRAMEWORK_DIR="/Applications/Xcode.app/Contents/Developer/Library/Frameworks"
PY_HEADER_DIR="$PY_FRAMEWORK_DIR/Python3.framework/Headers"
if [ -d "$PY_HEADER_DIR" ]; then
    PY_CFLAGS+=("-I$PY_HEADER_DIR" "-DFLOW_PY_EMBED")
    PY_LDFLAGS+=("-F$PY_FRAMEWORK_DIR" "-framework" "Python3" "-Wl,-rpath,$PY_FRAMEWORK_DIR")
fi

HOST="$(uname -s)"
LINK_SOURCES=()
LINK_FLAGS=()

case "$HOST" in
    Darwin)
        LINK_SOURCES+=("$FLOW_ROOT/runtime/gfx_macos.m" "$FLOW_ROOT/runtime/gpu_metal.m")
        LINK_FLAGS+=(
            -framework Cocoa
            -framework CoreGraphics
            -framework QuartzCore
            -framework CoreText
            -framework CoreAudio
            -framework AudioToolbox
            -framework AudioUnit
            -framework Metal
            -framework Foundation
        )
        ;;
    Linux)
        LINK_SOURCES+=("$FLOW_ROOT/runtime/gfx_linux.c")
        if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists sdl2; then
            # shellcheck disable=SC2207
            CONC_CFLAGS+=($(pkg-config --cflags sdl2))
            # shellcheck disable=SC2207
            LINK_FLAGS+=($(pkg-config --libs sdl2))
        else
            LINK_FLAGS+=(-lSDL2)
        fi
        LINK_FLAGS+=(-ldl)
        ;;
    *)
        echo "flowrat: MLIR gfx runner currently supports macOS and Linux" >&2
        exit 1
        ;;
esac

echo "flowrat: LLVM IR -> native gfx executable"
if ! clang -O3 -fno-omit-frame-pointer \
    "${AUDIO_CFLAGS[@]}" \
    "${PY_CFLAGS[@]}" \
    "${CONC_CFLAGS[@]}" \
    "$LLVM_IR" \
    "${LINK_SOURCES[@]}" \
    "${CONC_SOURCES[@]}" \
    "${RUNTIME_FLOW_SOURCES[@]}" \
    "${AUDIO_SOURCES[@]}" \
    "${PY_LDFLAGS[@]}" \
    "${CONC_LDFLAGS[@]}" \
    "${LINK_FLAGS[@]}" \
    -lm -o "$EXE"; then
    echo "flowrat: MLIR native link failed" >&2
    exit 1
fi

echo "flowrat: built $EXE"

if [ "$RUN" = "1" ]; then
    exec "$EXE"
fi
