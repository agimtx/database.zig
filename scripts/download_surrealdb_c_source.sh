#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REF_NAME="${SURREALDB_C_REF_NAME:-main}"
COMMIT_SHA="${SURREALDB_C_COMMIT_SHA:-039481e0c46fcd9c4096a9eaf85ec3a8fadf80ec}"
DEST_DIR="${ROOT}/third_party/surrealdb"
SOURCE_ROOT="${DEST_DIR}/source"
TREE_ROOT="${DEST_DIR}/tree"
TMP_ROOT="${ROOT}/.tmp/surrealdb-c/${COMMIT_SHA}"

: "${https_proxy:=http://127.0.0.1:7890}"
: "${http_proxy:=http://127.0.0.1:7890}"
: "${all_proxy:=socks5://127.0.0.1:7890}"
export https_proxy http_proxy all_proxy

download_file() {
    url="$1"
    destination="$2"

    mkdir -p "$(dirname -- "$destination")"
    curl -fL --retry 3 --connect-timeout 30 -o "$destination" "$url"
}

write_manifest() {
    manifest_path="${DEST_DIR}/manifest.txt"

    cat > "$manifest_path" <<EOF
repo=surrealdb/surrealdb.c
ref_name=${REF_NAME}
commit_sha=${COMMIT_SHA}
source=github-archive
vendor_layout=full-source-tree
source_archive=surrealdb.c-${COMMIT_SHA}.tar.gz
extracted_tree_root=tree
public_header=tree/include/surrealdb.h
build_systems=cargo,cmake,make
crate_types=lib,staticlib,cdylib
EOF
}

mkdir -p "$SOURCE_ROOT" "$TREE_ROOT" "$TMP_ROOT"

archive_path="${SOURCE_ROOT}/surrealdb.c-${COMMIT_SHA}.tar.gz"
extract_dir="${TMP_ROOT}/extract"

rm -rf "$extract_dir"
mkdir -p "$extract_dir"

download_file "https://github.com/surrealdb/surrealdb.c/archive/${COMMIT_SHA}.tar.gz" "$archive_path"
tar -xzf "$archive_path" -C "$extract_dir"

extracted_root=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -z "$extracted_root" ]; then
    echo "failed to locate extracted surrealdb.c source tree" >&2
    exit 1
fi

rm -rf "$TREE_ROOT"
mkdir -p "$TREE_ROOT"
cp -R "$extracted_root"/. "$TREE_ROOT"

write_manifest

printf 'downloaded surrealdb.c %s (%s) -> %s\n' "$REF_NAME" "$COMMIT_SHA" "$TREE_ROOT"
printf 'wrote %s\n' "${DEST_DIR}/manifest.txt"
