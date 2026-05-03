#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMIT_SHA="${SURREALDB_C_COMMIT_SHA:-039481e0c46fcd9c4096a9eaf85ec3a8fadf80ec}"
PROFILE="${SURREALDB_C_PROFILE:-release}"
TARGET_TRIPLE="${SURREALDB_CARGO_TARGET:-}"
STRIP_BINARY="${SURREALDB_STRIP_BINARY:-1}"
RELEASE_LTO="${SURREALDB_RELEASE_LTO:-fat}"
RELEASE_CODEGEN_UNITS="${SURREALDB_RELEASE_CODEGEN_UNITS:-1}"
RELEASE_PANIC="${SURREALDB_RELEASE_PANIC:-abort}"
RELEASE_PROFILE_STRIP="${SURREALDB_RELEASE_PROFILE_STRIP:-symbols}"
RELEASE_OPT_LEVEL="${SURREALDB_RELEASE_OPT_LEVEL:-z}"
SDK_ROOT="${ROOT}/third_party/surrealdb/tree"
DEST_ROOT="${ROOT}/third_party/surrealdb"
INCLUDE_ROOT="${DEST_ROOT}/include"

default_target_triple() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64) echo "aarch64-apple-darwin" ;;
        Darwin:x86_64) echo "x86_64-apple-darwin" ;;
        Linux:aarch64) echo "aarch64-unknown-linux-gnu" ;;
        Linux:x86_64) echo "x86_64-unknown-linux-gnu" ;;
        MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64) echo "x86_64-pc-windows-gnu" ;;
        *)
            echo "unsupported host platform: $(uname -s):$(uname -m)" >&2
            exit 1
            ;;
    esac
}

platform_subdir_for_target() {
    case "$1" in
        aarch64-apple-darwin) echo "macos-arm64" ;;
        x86_64-apple-darwin) echo "macos-x86_64" ;;
        aarch64-unknown-linux-gnu) echo "linux-arm64" ;;
        x86_64-unknown-linux-gnu) echo "linux-x86_64" ;;
        aarch64-unknown-linux-musl) echo "linux-musl-arm64" ;;
        x86_64-unknown-linux-musl) echo "linux-musl-x86_64" ;;
        x86_64-pc-windows-msvc|x86_64-pc-windows-gnu) echo "windows-x86_64" ;;
        aarch64-pc-windows-msvc) echo "windows-arm64" ;;
        *)
            echo "unsupported target triple: $1" >&2
            exit 1
            ;;
    esac
}

built_shared_library_name() {
    case "$1" in
        *-apple-darwin) echo "libsurrealdb_c.dylib" ;;
        *-linux-gnu|*-linux-musl) echo "libsurrealdb_c.so" ;;
        *-windows-msvc|*-windows-gnu) echo "surrealdb_c.dll" ;;
        *)
            echo "unsupported target triple: $1" >&2
            exit 1
            ;;
    esac
}

installed_shared_library_name() {
    case "$1" in
        *-apple-darwin) echo "libsurrealdb.dylib" ;;
        *-linux-gnu|*-linux-musl) echo "libsurrealdb.so" ;;
        *-windows-msvc|*-windows-gnu) echo "surrealdb.dll" ;;
        *)
            echo "unsupported target triple: $1" >&2
            exit 1
            ;;
    esac
}

apply_default_compiler_env() {
    case "$(uname -s)" in
        Darwin)
            : "${CC:=clang}"
            : "${CXX:=clang++}"
            export CC CXX
            ;;
    esac
}

apply_release_optimization_env() {
    if [ "${PROFILE}" != "release" ]; then
        return 0
    fi

    export CARGO_PROFILE_RELEASE_LTO="${RELEASE_LTO}"
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${RELEASE_CODEGEN_UNITS}"
    export CARGO_PROFILE_RELEASE_PANIC="${RELEASE_PANIC}"
    export CARGO_PROFILE_RELEASE_STRIP="${RELEASE_PROFILE_STRIP}"
    export CARGO_PROFILE_RELEASE_OPT_LEVEL="${RELEASE_OPT_LEVEL}"
}

profile_dir() {
    case "$1" in
        debug) echo "debug" ;;
        release) echo "release" ;;
        *)
            echo "unsupported profile: $1" >&2
            exit 1
            ;;
    esac
}

strip_supported() {
    case "$1" in
        *-apple-darwin|*-linux-gnu|*-linux-musl) return 0 ;;
        *) return 1 ;;
    esac
}

strip_installed_library() {
    file_path="$1"
    target_triple="$2"

    if [ "${STRIP_BINARY}" != "1" ]; then
        return 0
    fi

    strip_supported "${target_triple}" || return 0

    case "${target_triple}" in
        *-apple-darwin)
            strip -x "${file_path}"
            ;;
        *-linux-gnu|*-linux-musl)
            strip --strip-unneeded "${file_path}"
            ;;
    esac
}

write_build_manifest() {
    manifest_path="${DEST_ROOT}/build-manifest.txt"
    cat > "$manifest_path" <<EOF
commit_sha=${COMMIT_SHA}
profile=${PROFILE}
target_triple=${EFFECTIVE_TARGET_TRIPLE}
host_platform=${PLATFORM_SUBDIR}
library_path=lib/${PLATFORM_SUBDIR}/${INSTALL_LIB_FILENAME}
header_path=include/surrealdb.h
artifact_kind=cdylib
strip_binary=${STRIP_BINARY}
release_lto=${RELEASE_LTO}
release_codegen_units=${RELEASE_CODEGEN_UNITS}
release_panic=${RELEASE_PANIC}
release_profile_strip=${RELEASE_PROFILE_STRIP}
release_opt_level=${RELEASE_OPT_LEVEL}
EOF
}

if [ ! -f "${SDK_ROOT}/Cargo.toml" ]; then
    echo "missing surrealdb.c source tree at ${SDK_ROOT}" >&2
    echo "run scripts/download_surrealdb_c_source.sh first" >&2
    exit 1
fi

apply_default_compiler_env
PROFILE_DIR=$(profile_dir "${PROFILE}")
EFFECTIVE_TARGET_TRIPLE="${TARGET_TRIPLE}"
if [ -z "${EFFECTIVE_TARGET_TRIPLE}" ]; then
    EFFECTIVE_TARGET_TRIPLE=$(default_target_triple)
fi

apply_release_optimization_env

PLATFORM_SUBDIR=$(platform_subdir_for_target "${EFFECTIVE_TARGET_TRIPLE}")
BUILT_LIB_FILENAME=$(built_shared_library_name "${EFFECTIVE_TARGET_TRIPLE}")
INSTALL_LIB_FILENAME=$(installed_shared_library_name "${EFFECTIVE_TARGET_TRIPLE}")

TARGET_DIR="${SDK_ROOT}/target/${PROFILE_DIR}/deps"
if [ -n "${TARGET_TRIPLE}" ]; then
    TARGET_DIR="${SDK_ROOT}/target/${TARGET_TRIPLE}/${PROFILE_DIR}/deps"
fi

LIB_PATH="${TARGET_DIR}/${BUILT_LIB_FILENAME}"
DEST_LIB_DIR="${DEST_ROOT}/lib/${PLATFORM_SUBDIR}"

mkdir -p "${DEST_LIB_DIR}" "${INCLUDE_ROOT}"

echo "==> building surrealdb.c ${PROFILE} shared library"
if [ "${PROFILE}" = "release" ]; then
    if [ -n "${TARGET_TRIPLE}" ]; then
        cargo build --manifest-path "${SDK_ROOT}/Cargo.toml" --release --target "${TARGET_TRIPLE}"
    else
        cargo build --manifest-path "${SDK_ROOT}/Cargo.toml" --release
    fi
else
    if [ -n "${TARGET_TRIPLE}" ]; then
        cargo build --manifest-path "${SDK_ROOT}/Cargo.toml" --target "${TARGET_TRIPLE}"
    else
        cargo build --manifest-path "${SDK_ROOT}/Cargo.toml"
    fi
fi

if [ ! -f "${LIB_PATH}" ]; then
    echo "missing built library: ${LIB_PATH}" >&2
    exit 1
fi

rm -f "${DEST_LIB_DIR}/${INSTALL_LIB_FILENAME}" "${DEST_LIB_DIR}/${BUILT_LIB_FILENAME}"
cp "${LIB_PATH}" "${DEST_LIB_DIR}/${INSTALL_LIB_FILENAME}"
strip_installed_library "${DEST_LIB_DIR}/${INSTALL_LIB_FILENAME}" "${EFFECTIVE_TARGET_TRIPLE}"
cp "${SDK_ROOT}/include/surrealdb.h" "${INCLUDE_ROOT}/surrealdb.h"

write_build_manifest

printf 'installed %s -> %s\n' "${LIB_PATH}" "${DEST_LIB_DIR}/${INSTALL_LIB_FILENAME}"
printf 'installed %s -> %s\n' "${SDK_ROOT}/include/surrealdb.h" "${INCLUDE_ROOT}/surrealdb.h"
printf 'wrote %s\n' "${DEST_ROOT}/build-manifest.txt"
