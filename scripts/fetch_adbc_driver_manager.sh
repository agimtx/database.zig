#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION="${ADBC_VERSION:-1.11.0}"
RELEASE_TAG="${ADBC_RELEASE_TAG:-apache-arrow-adbc-23}"
SOURCE_ARCHIVE="${RELEASE_TAG}.tar.gz"
SOURCE_URL="https://github.com/apache/arrow-adbc/archive/refs/tags/${SOURCE_ARCHIVE}"
DEST_DIR="${ROOT}/third_party/adbc/${VERSION}"
DIST_DIR="${DEST_DIR}/dist"
INCLUDE_DIR="${DEST_DIR}/include"
ARROW_INCLUDE_DIR="${INCLUDE_DIR}/arrow-adbc"
DRIVER_INCLUDE_DIR="${ARROW_INCLUDE_DIR}/driver"
LICENSE_DIR="${DEST_DIR}/licenses"
TMP_ROOT="${ROOT}/.tmp/adbc-header-refresh/${VERSION}"
EXTRACTED_DIR="${TMP_ROOT}/arrow-adbc-${RELEASE_TAG}"

: "${https_proxy:=http://127.0.0.1:7890}"
: "${http_proxy:=http://127.0.0.1:7890}"
: "${all_proxy:=socks5://127.0.0.1:7890}"
export https_proxy http_proxy all_proxy

log_step() {
    step="$1"
    message="$2"
    printf '[%s/5] %s\n' "${step}" "${message}"
}

log_step 1 "preparing destination directories"
mkdir -p "${DIST_DIR}" "${INCLUDE_DIR}" "${ARROW_INCLUDE_DIR}" "${DRIVER_INCLUDE_DIR}" "${LICENSE_DIR}" "${TMP_ROOT}"

archive_path="${DIST_DIR}/${SOURCE_ARCHIVE}"

if [ ! -f "${archive_path}" ]; then
    log_step 2 "downloading ${SOURCE_ARCHIVE}"
    curl --progress-bar -L --fail --retry 3 --output "${archive_path}" "${SOURCE_URL}"
else
    log_step 2 "using cached archive ${archive_path}"
fi

log_step 3 "extracting source archive"
rm -rf "${TMP_ROOT}"
mkdir -p "${TMP_ROOT}"
tar -xzf "${archive_path}" -C "${TMP_ROOT}"

# Copy only the public C headers and license files Zig needs.

log_step 4 "refreshing public headers and licenses"
cp "${EXTRACTED_DIR}/c/include/adbc.h" "${INCLUDE_DIR}/adbc.h"
cp "${EXTRACTED_DIR}/c/include/adbc_driver_manager.h" "${INCLUDE_DIR}/adbc_driver_manager.h"
cp "${EXTRACTED_DIR}/c/include/adbc.h" "${ARROW_INCLUDE_DIR}/adbc.h"
cp "${EXTRACTED_DIR}/c/include/adbc_driver_manager.h" "${ARROW_INCLUDE_DIR}/adbc_driver_manager.h"
cp "${EXTRACTED_DIR}/c/include/arrow-adbc/driver/postgresql.h" "${DRIVER_INCLUDE_DIR}/postgresql.h"
cp "${EXTRACTED_DIR}/c/include/arrow-adbc/driver/sqlite.h" "${DRIVER_INCLUDE_DIR}/sqlite.h"
cp "${EXTRACTED_DIR}/c/include/arrow-adbc/driver/flightsql.h" "${DRIVER_INCLUDE_DIR}/flightsql.h"
cp "${EXTRACTED_DIR}/c/include/arrow-adbc/driver/snowflake.h" "${DRIVER_INCLUDE_DIR}/snowflake.h"
cp "${EXTRACTED_DIR}/c/include/arrow-adbc/driver/bigquery.h" "${DRIVER_INCLUDE_DIR}/bigquery.h"
cp "${EXTRACTED_DIR}/LICENSE.txt" "${LICENSE_DIR}/LICENSE.txt"
cp "${EXTRACTED_DIR}/NOTICE.txt" "${LICENSE_DIR}/NOTICE.txt"

log_step 5 "writing manifest and cleaning temporary files"
rm -rf "${TMP_ROOT}"

cat > "${DEST_DIR}/manifest.txt" <<EOF
version=${VERSION}
release_tag=${RELEASE_TAG}
source_archive=${SOURCE_ARCHIVE}
vendor_layout=headers-and-libraries
header_refresh_source=official-source-archive
official_driver_headers=bigquery,flightsql,postgresql,snowflake,sqlite
downloadable_native_drivers=driver_manager,flightsql,postgresql,snowflake,sqlite
unsupported_native_drivers=bigquery
supported_platforms=macos,linux,windows
EOF

echo "refreshed Arrow ADBC headers and licenses ${VERSION} into ${DEST_DIR}"