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
REMOTE_ACCESS="${SURREALDB_REMOTE_ACCESS:-0}"
REMOTE_TRANSPORTS="${SURREALDB_REMOTE_TRANSPORTS:-http,ws}"
REMOTE_TLS="${SURREALDB_REMOTE_TLS:-rustls}"
EXTRA_CARGO_FEATURES="${SURREALDB_CARGO_FEATURES:-}"
REMOTE_MIN_RUST_MINOR="${SURREALDB_REMOTE_MIN_RUST_MINOR:-88}"
PREFERRED_RUSTUP_TOOLCHAIN="${SURREALDB_RUSTUP_TOOLCHAIN:-}"
SDK_ROOT="${ROOT}/third_party/surrealdb/tree"
DEST_ROOT="${ROOT}/third_party/surrealdb"
INCLUDE_ROOT="${DEST_ROOT}/include"
CARGO_FRONTEND="cargo"
RUSTC_FRONTEND="rustc"
SELECTED_RUST_TOOLCHAIN=""
SELECTED_CARGO_BIN=""
SELECTED_RUSTC_BIN=""

append_feature() {
    feature_name="$1"

    if [ -z "${CARGO_FEATURES}" ]; then
        CARGO_FEATURES="${feature_name}"
        return 0
    fi

    case ",${CARGO_FEATURES}," in
        *,${feature_name},*) ;;
        *) CARGO_FEATURES="${CARGO_FEATURES},${feature_name}" ;;
    esac
}

normalize_csv_to_lines() {
    printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'
}

rustc_version_string() {
    "$@" --version 2>/dev/null | awk 'NR == 1 { print $2 }'
}

rustc_supports_remote() {
    version_string="$1"

    if [ -z "${version_string}" ]; then
        return 1
    fi

    old_ifs=${IFS}
    IFS=.
    set -- ${version_string}
    IFS=${old_ifs}

    major="${1:-0}"
    minor="${2:-0}"

    if [ "${major}" -gt 1 ]; then
        return 0
    fi

    if [ "${major}" -eq 1 ] && [ "${minor}" -ge "${REMOTE_MIN_RUST_MINOR}" ]; then
        return 0
    fi

    return 1
}

try_select_rustup_toolchain() {
    toolchain_name="$1"
    version_string=$(rustc_version_string rustup run "${toolchain_name}" rustc)

    if rustc_supports_remote "${version_string}"; then
        SELECTED_RUST_TOOLCHAIN="${toolchain_name}"
        CARGO_FRONTEND="rustup run ${toolchain_name} cargo"
        RUSTC_FRONTEND="rustup run ${toolchain_name} rustc"
        SELECTED_CARGO_BIN=$(rustup which --toolchain "${toolchain_name}" cargo)
        SELECTED_RUSTC_BIN=$(rustup which --toolchain "${toolchain_name}" rustc)
        return 0
    fi

    return 1
}

select_remote_toolchain() {
    if [ -n "${PREFERRED_RUSTUP_TOOLCHAIN}" ]; then
        if ! command -v rustup >/dev/null 2>&1; then
            echo "SURREALDB_RUSTUP_TOOLCHAIN is set, but rustup is unavailable" >&2
            exit 1
        fi

        if try_select_rustup_toolchain "${PREFERRED_RUSTUP_TOOLCHAIN}"; then
            return 0
        fi

        echo "SURREALDB_RUSTUP_TOOLCHAIN=${PREFERRED_RUSTUP_TOOLCHAIN} does not provide rustc >= 1.${REMOTE_MIN_RUST_MINOR}.0" >&2
        exit 1
    fi

    current_version=$(rustc_version_string rustc)
    if rustc_supports_remote "${current_version}"; then
        return 0
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        echo "remote surrealdb build needs rustc >= 1.${REMOTE_MIN_RUST_MINOR}.0, but current rustc is ${current_version:-unknown} and rustup is unavailable" >&2
        exit 1
    fi

    if try_select_rustup_toolchain stable; then
        return 0
    fi

    for toolchain_name in $(rustup toolchain list | awk '{print $1}'); do
        if try_select_rustup_toolchain "${toolchain_name}"; then
            return 0
        fi
    done

    echo "remote surrealdb build needs rustc >= 1.${REMOTE_MIN_RUST_MINOR}.0, but no installed rustup toolchain satisfies that requirement" >&2
    echo "install a newer toolchain or set SURREALDB_RUSTUP_TOOLCHAIN=<toolchain>" >&2
    exit 1
}

collect_cargo_features() {
    CARGO_FEATURES=""

    if [ "${REMOTE_ACCESS}" = "1" ]; then
        for transport in $(normalize_csv_to_lines "${REMOTE_TRANSPORTS}"); do
            case "${transport}" in
                http) append_feature "remote-http" ;;
                ws) append_feature "remote-ws" ;;
                *)
                    echo "unsupported SURREALDB_REMOTE_TRANSPORTS entry: ${transport}" >&2
                    exit 1
                    ;;
            esac
        done

        for tls_backend in $(normalize_csv_to_lines "${REMOTE_TLS}"); do
            case "${tls_backend}" in
                rustls) append_feature "remote-rustls" ;;
                native-tls) append_feature "remote-native-tls" ;;
                none) ;;
                *)
                    echo "unsupported SURREALDB_REMOTE_TLS entry: ${tls_backend}" >&2
                    exit 1
                    ;;
            esac
        done
    fi

    for feature_name in $(normalize_csv_to_lines "${EXTRA_CARGO_FEATURES}"); do
        append_feature "${feature_name}"
    done
}

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
remote_access=${REMOTE_ACCESS}
remote_transports=${REMOTE_TRANSPORTS}
remote_tls=${REMOTE_TLS}
cargo_features=${CARGO_FEATURES}
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
collect_cargo_features
if [ "${REMOTE_ACCESS}" = "1" ]; then
    select_remote_toolchain
fi

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

if [ -n "${SELECTED_RUST_TOOLCHAIN}" ]; then
    set -- "${SELECTED_CARGO_BIN}" build --manifest-path "${SDK_ROOT}/Cargo.toml"
else
    set -- cargo build --manifest-path "${SDK_ROOT}/Cargo.toml"
fi
if [ "${PROFILE}" = "release" ]; then
    set -- "$@" --release
fi
if [ -n "${TARGET_TRIPLE}" ]; then
    set -- "$@" --target "${TARGET_TRIPLE}"
fi
if [ -n "${CARGO_FEATURES}" ]; then
    set -- "$@" --features "${CARGO_FEATURES}"
fi

echo "==> building surrealdb.c ${PROFILE} shared library"
if [ -n "${SELECTED_RUST_TOOLCHAIN}" ]; then
    echo "==> rust toolchain: ${SELECTED_RUST_TOOLCHAIN}"
    echo "==> rustc: ${SELECTED_RUSTC_BIN} ($(${SELECTED_RUSTC_BIN} --version))"
fi
if [ -n "${CARGO_FEATURES}" ]; then
    echo "==> cargo features: ${CARGO_FEATURES}"
fi
if [ -n "${SELECTED_RUSTC_BIN}" ]; then
    export RUSTC="${SELECTED_RUSTC_BIN}"
    export CARGO_BUILD_RUSTC="${SELECTED_RUSTC_BIN}"
fi
"$@"

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
