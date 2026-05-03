#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMIT_SHA="${SURREALDB_C_COMMIT_SHA:-039481e0c46fcd9c4096a9eaf85ec3a8fadf80ec}"
SDK_ROOT="${ROOT}/third_party/surrealdb/tree"
BUILD_ROOT="${ROOT}/.tmp/surrealdb-c-zig-poc/${COMMIT_SHA}"
EXE_PATH="${BUILD_ROOT}/surrealdb_c_poc"

if [ ! -f "${SDK_ROOT}/Cargo.toml" ]; then
    echo "missing surrealdb.c source tree at ${SDK_ROOT}" >&2
    echo "run scripts/download_surrealdb_c_source.sh first" >&2
    exit 1
fi

mkdir -p "${BUILD_ROOT}"

echo "==> building surrealdb.c static library"
cargo build --manifest-path "${SDK_ROOT}/Cargo.toml"

LIB_PATH=$(find "${SDK_ROOT}/target/debug" -name 'libsurrealdb_c.a' | head -n 1)
if [ -z "${LIB_PATH}" ]; then
    echo "failed to locate libsurrealdb_c.a under ${SDK_ROOT}/target/debug" >&2
    exit 1
fi

set -- \
    zig build-exe "${ROOT}/examples/surrealdb_c_poc.zig" \
    -I "${SDK_ROOT}/include" \
    -L "$(dirname -- "${LIB_PATH}")" \
    -lsurrealdb_c \
    -lc \
    -femit-bin="${EXE_PATH}"

case "$(uname -s)" in
    Darwin)
        set -- "$@" \
            -framework Security \
            -framework SystemConfiguration \
            -framework CoreFoundation \
            -framework IOKit \
            -lobjc
        ;;
    Linux)
        set -- "$@" -lm -ldl -lpthread -lrt
        ;;
esac

echo "==> building Zig PoC"
"$@"

echo "==> running Zig PoC"
"${EXE_PATH}"