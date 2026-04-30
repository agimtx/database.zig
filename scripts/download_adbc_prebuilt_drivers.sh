#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION="${ADBC_VERSION:-1.11.0}"
DUCKDB_VERSION="${DUCKDB_VERSION:-1.4.1}"
ADBC_NUGET_VERSION="${ADBC_NUGET_VERSION:-0.23.0}"
DEST_DIR="${ROOT}/third_party/adbc/${VERSION}"
LIB_ROOT="${DEST_DIR}/lib"
TMP_ROOT="${ROOT}/.tmp/adbc-prebuilt-drivers"

: "${https_proxy:=http://127.0.0.1:7890}"
: "${http_proxy:=http://127.0.0.1:7890}"
: "${all_proxy:=socks5://127.0.0.1:7890}"
export https_proxy http_proxy all_proxy

DEPENDENCIES_ONLY="${ADBC_DEPENDENCIES_ONLY:-0}"

host_default_subdir() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64) echo "osx-arm64" ;;
        Darwin:x86_64) echo "osx-64" ;;
        Linux:aarch64) echo "linux-aarch64" ;;
        Linux:x86_64) echo "linux-64" ;;
        MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64) echo "win-64" ;;
        *)
            echo "unsupported host platform: $(uname -s):$(uname -m)" >&2
            exit 1
            ;;
    esac
}

host_tag_for_subdir() {
    case "$1" in
        osx-arm64) echo "macos-arm64" ;;
        osx-64) echo "macos-x86_64" ;;
        linux-aarch64) echo "linux-arm64" ;;
        linux-64) echo "linux-x86_64" ;;
        win-64) echo "windows-x86_64" ;;
        *) return 1 ;;
    esac
}

all_supported_subdirs() {
    printf '%s\n' osx-arm64 osx-64 linux-aarch64 linux-64 win-64
}

normalize_driver() {
    case "$1" in
        driver_manager|driver-manager|manager) echo "driver_manager" ;;
        sqlite|sqlite3) echo "sqlite" ;;
        postgresql|postgres|postgresql-driver|postgres-driver) echo "postgresql" ;;
        flightsql|flight-sql|flight_sql) echo "flightsql" ;;
        snowflake) echo "snowflake" ;;
        duckdb) echo "duckdb" ;;
        bigquery) echo "bigquery" ;;
        *) return 1 ;;
    esac
}

package_name_for_driver() {
    case "$1" in
        driver_manager) echo "libadbc-driver-manager=${VERSION}" ;;
        flightsql) echo "libadbc-driver-flightsql=${VERSION}" ;;
        postgresql) echo "libadbc-driver-postgresql=${VERSION}" ;;
        snowflake) echo "libadbc-driver-snowflake=${VERSION}" ;;
        sqlite) echo "libadbc-driver-sqlite=${VERSION}" ;;
        duckdb) echo "duckdb=${DUCKDB_VERSION}" ;;
        *) return 1 ;;
    esac
}

runtime_packages_for_driver() {
    driver="$1"
    conda_subdir="$2"

    case "${driver}:${conda_subdir}" in
        postgresql:win-64) echo "libpq openssl krb5 cyrus-sasl" ;;
        postgresql:*) echo "libpq openssl krb5 openldap cyrus-sasl" ;;
        *) return 1 ;;
    esac
}

library_basename_for_driver() {
    case "$1" in
        duckdb) echo "duckdb" ;;
        flightsql) echo "adbc_driver_flightsql" ;;
        snowflake) echo "adbc_driver_snowflake" ;;
        driver_manager) echo "adbc_driver_manager" ;;
        postgresql) echo "adbc_driver_postgresql" ;;
        sqlite) echo "adbc_driver_sqlite" ;;
        *) return 1 ;;
    esac
}

driver_source_on_subdir() {
    conda_subdir="$1"
    driver="$2"

    case "${conda_subdir}:${driver}" in
        win-64:duckdb) echo "duckdb-release" ;;
        win-64:flightsql|win-64:snowflake) echo "nuget" ;;
        *) echo "conda" ;;
    esac
}

conda_virtual_package_env() {
    conda_subdir="$1"

    case "${conda_subdir}" in
        linux-aarch64|linux-64)
            printf '%s' 'CONDA_OVERRIDE_GLIBC=2.17 '
            ;;
        *)
            printf '%s' ''
            ;;
    esac
}

all_patterns_present() {
    search_dir="$1"
    shift

    for pattern in "$@"; do
        set -- "${search_dir}"/$pattern
        [ -e "$1" ] || return 1
    done

    return 0
}

driver_runtime_filename() {
    host_tag="$1"
    driver="$2"

    case "$driver" in
        duckdb)
            case "${host_tag}" in
                macos-*) echo "libduckdb.dylib" ;;
                linux-*) echo "libduckdb.so" ;;
                windows-*) echo "duckdb.dll" ;;
            esac
            ;;
        *)
            base_name=$(library_basename_for_driver "${driver}")
            case "${host_tag}" in
                macos-*) echo "lib${base_name}.dylib" ;;
                linux-*) echo "lib${base_name}.so" ;;
                windows-*) echo "${base_name}.dll" ;;
            esac
            ;;
    esac
}

driver_has_external_runtime_dependencies() {
    case "$1" in
        postgresql) return 0 ;;
        *) return 1 ;;
    esac
}

driver_dependency_bundle_ready() {
    lib_dir="$1"
    host_tag="$2"
    driver="$3"

    driver_has_external_runtime_dependencies "${driver}" || return 1

    case "$driver" in
        postgresql)
            case "${host_tag}" in
                macos-*)
                    all_patterns_present "${lib_dir}" \
                        'libpq*.dylib' \
                        'libssl*.dylib' \
                        'libcrypto*.dylib' \
                        'libgssapi_krb5*.dylib' \
                        'libldap*.dylib' \
                        'liblber*.dylib' \
                        'libsasl2*.dylib' \
                        'libkrb5*.dylib' \
                        'libk5crypto*.dylib' \
                        'libcom_err*.dylib' \
                        'libkrb5support*.dylib' \
                        'libgssrpc*.dylib' \
                        'libkdb5*.dylib' \
                        'libkadm5*.dylib' \
                        'libkrad*.dylib' \
                        'libverto*.dylib' \
                        'libntlm*.dylib'
                    ;;
                linux-*)
                    all_patterns_present "${lib_dir}" \
                        'libpq.so*' \
                        'libssl.so*' \
                        'libcrypto.so*' \
                        'libgssapi_krb5.so*' \
                        'libldap.so*' \
                        'liblber.so*' \
                        'libsasl2.so*' \
                        'libkrb5.so*' \
                        'libk5crypto.so*' \
                        'libcom_err.so*' \
                        'libkrb5support.so*' \
                        'libgssrpc.so*' \
                        'libkdb5.so*' \
                        'libkadm5*.so*' \
                        'libkrad.so*' \
                        'libverto.so*' \
                        'libntlm.so*'
                    ;;
                windows-*)
                    all_patterns_present "${lib_dir}" \
                        'libpq.dll' \
                        'libssl-3*.dll' \
                        'libcrypto-3*.dll' \
                        'gssapi*.dll' \
                        '*ldap*.dll' \
                        '*lber*.dll' \
                        '*sasl*.dll' \
                        'krb*.dll' \
                        'k5*.dll' \
                        'comerr*.dll' \
                        'kadm*.dll' \
                        'verto*.dll' \
                        'ntlm*.dll'
                    ;;
            esac
            ;;
    esac
}

driver_artifacts_ready() {
    lib_dir="$1"
    host_tag="$2"
    driver="$3"
    runtime_file=$(driver_runtime_filename "${host_tag}" "${driver}")

    [ -f "${lib_dir}/${runtime_file}" ] || return 1

    case "$driver" in
        postgresql)
            case "${host_tag}" in
                macos-*)
                    all_patterns_present "${lib_dir}" \
                        'libpq*.dylib' \
                        'libssl*.dylib' \
                        'libcrypto*.dylib' \
                        'libgssapi_krb5*.dylib' \
                        'libldap*.dylib' \
                        'liblber*.dylib' \
                        'libsasl2*.dylib' \
                        'libkrb5*.dylib' \
                        'libk5crypto*.dylib' \
                        'libcom_err*.dylib' \
                        'libkrb5support*.dylib' \
                        'libgssrpc*.dylib' \
                        'libkdb5*.dylib' \
                        'libkadm5*.dylib' \
                        'libkrad*.dylib' \
                        'libverto*.dylib' \
                        'libntlm*.dylib'
                    ;;
                linux-*)
                    all_patterns_present "${lib_dir}" \
                        'libpq.so*' \
                        'libssl.so*' \
                        'libcrypto.so*' \
                        'libgssapi_krb5.so*' \
                        'libldap.so*' \
                        'liblber.so*' \
                        'libsasl2.so*' \
                        'libkrb5.so*' \
                        'libk5crypto.so*' \
                        'libcom_err.so*' \
                        'libkrb5support.so*' \
                        'libgssrpc.so*' \
                        'libkdb5.so*' \
                        'libkadm5*.so*' \
                        'libkrad.so*' \
                        'libverto.so*' \
                        'libntlm.so*'
                    ;;
                windows-*)
                    all_patterns_present "${lib_dir}" \
                        'libpq.dll' \
                        'libssl-3*.dll' \
                        'libcrypto-3*.dll' \
                        'gssapi*.dll' \
                        '*ldap*.dll' \
                        '*lber*.dll' \
                        '*sasl*.dll' \
                        'krb*.dll' \
                        'k5*.dll' \
                        'comerr*.dll' \
                        'kadm*.dll' \
                        'verto*.dll' \
                        'ntlm*.dll'
                    ;;
            esac
            ;;
    esac
}

copy_runtime_library() {
    temp_prefix="$1"
    lib_dir="$2"
    host_tag="$3"
    driver="$4"
    base_name=$(library_basename_for_driver "${driver}")

    case "${host_tag}" in
        macos-*)
            runtime_path=$(find "${temp_prefix}/lib" -maxdepth 1 -type f -name "lib${base_name}*.dylib" | sort | head -n 1)
            cp "${runtime_path}" "${lib_dir}/lib${base_name}.dylib"
            ;;
        linux-*)
            runtime_path=$(find "${temp_prefix}/lib" -maxdepth 1 -type f -name "lib${base_name}*.so*" | sort | head -n 1)
            cp "${runtime_path}" "${lib_dir}/lib${base_name}.so"
            ;;
        windows-*)
            runtime_path=$(find "${temp_prefix}" -type f -name "${base_name}.dll" | head -n 1)
            cp "${runtime_path}" "${lib_dir}/${base_name}.dll"
            ;;
    esac
}

copy_matching_runtime_files() {
    source_dir="$1"
    lib_dir="$2"
    shift 2

    for pattern in "$@"; do
        for runtime_path in "${source_dir}"/$pattern; do
            [ -f "${runtime_path}" ] || continue
            cp "${runtime_path}" "${lib_dir}/$(basename -- "${runtime_path}")"
        done
    done
}

copy_all_shared_libraries() {
    temp_prefix="$1"
    lib_dir="$2"
    host_tag="$3"

    case "${host_tag}" in
        macos-*|linux-*)
            copy_matching_runtime_files "${temp_prefix}/lib" "${lib_dir}" '*.dylib' '*.so' '*.so.*'
            ;;
        windows-*)
            copy_matching_runtime_files "${temp_prefix}/Library/bin" "${lib_dir}" '*.dll'
            ;;
    esac
}

copy_runtime_dependencies() {
    temp_prefix="$1"
    lib_dir="$2"
    host_tag="$3"
    driver="$4"

    case "$driver" in
        postgresql)
            case "${host_tag}" in
                macos-*)
                    copy_matching_runtime_files "${temp_prefix}/lib" "${lib_dir}" \
                        'libpq*.dylib' \
                        'libssl*.dylib' \
                        'libcrypto*.dylib' \
                        'libgssapi_krb5*.dylib' \
                        'libldap*.dylib' \
                        'liblber*.dylib' \
                        'libsasl2*.dylib' \
                        'libkrb5*.dylib' \
                        'libk5crypto*.dylib' \
                        'libcom_err*.dylib' \
                        'libkrb5support*.dylib' \
                        'libgssrpc*.dylib' \
                        'libkdb5*.dylib' \
                        'libkadm5*.dylib' \
                        'libkrad*.dylib' \
                        'libverto*.dylib' \
                        'libntlm*.dylib'
                    ;;
                linux-*)
                    copy_matching_runtime_files "${temp_prefix}/lib" "${lib_dir}" \
                        'libpq.so*' \
                        'libssl.so*' \
                        'libcrypto.so*' \
                        'libgssapi_krb5.so*' \
                        'libldap.so*' \
                        'liblber.so*' \
                        'libsasl2.so*' \
                        'libkrb5.so*' \
                        'libk5crypto.so*' \
                        'libcom_err.so*' \
                        'libkrb5support.so*' \
                        'libgssrpc.so*' \
                        'libkdb5.so*' \
                        'libkadm5*.so*' \
                        'libkrad.so*' \
                        'libverto.so*' \
                        'libntlm.so*'
                    ;;
                windows-*)
                    copy_matching_runtime_files "${temp_prefix}/Library/bin" "${lib_dir}" \
                        'libpq.dll' \
                        'libssl-3*.dll' \
                        'libcrypto-3*.dll' \
                        'gssapi*.dll' \
                        '*ldap*.dll' \
                        '*lber*.dll' \
                        '*sasl*.dll' \
                        'krb*.dll' \
                        'k5*.dll' \
                        'comerr*.dll' \
                        'kadm*.dll' \
                        'verto*.dll' \
                        'ntlm*.dll'
                    ;;
            esac
            ;;
    esac
}

download_file() {
    download_url="$1"
    download_path="$2"

    mkdir -p "$(dirname -- "${download_path}")"
    curl -L --fail --retry 5 --retry-all-errors --output "${download_path}" "${download_url}"
}

download_file_python() {
    python_download_url="$1"
    python_download_path="$2"

    python3 - "$python_download_url" "$python_download_path" <<'PY'
import pathlib
import shutil
import sys
import urllib.request
from urllib.error import HTTPError, URLError

url, destination = sys.argv[1:3]
path = pathlib.Path(destination)
path.parent.mkdir(parents=True, exist_ok=True)

last_error = None
for _ in range(5):
    try:
        with urllib.request.urlopen(url) as response:
            expected_size = response.headers.get('Content-Length')
            with open(path, 'wb') as target:
                shutil.copyfileobj(response, target)

        if expected_size is not None and path.stat().st_size != int(expected_size):
            raise OSError(f'incomplete download: expected {expected_size} bytes, got {path.stat().st_size}')

        sys.exit(0)
    except (OSError, HTTPError, URLError) as exc:
        last_error = exc
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass

raise SystemExit(f'failed to download {url}: {last_error}')
PY
}

download_zip_file() {
    url="$1"
    destination="$2"

    attempts=0
    while [ "${attempts}" -lt 5 ]; do
        attempts=$((attempts + 1))
        rm -f "${destination}"
        download_file "${url}" "${destination}"

        if python3 - "$destination" <<'PY'
import sys
import zipfile

path = sys.argv[1]
with zipfile.ZipFile(path) as archive:
    archive.testzip()
PY
        then
            return 0
        fi
    done

    rm -f "${destination}"
    echo "failed to download valid zip archive from ${url}" >&2
    exit 1
}

extract_zip_member() {
    zip_archive_path="$1"
    zip_member_path="$2"
    zip_destination_path="$3"

    mkdir -p "$(dirname -- "${zip_destination_path}")"
    unzip -p "${zip_archive_path}" "${zip_member_path}" > "${zip_destination_path}"
}

extract_zip_member_unzip() {
    unzip_archive_path="$1"
    unzip_member_path="$2"
    unzip_destination_path="$3"

    mkdir -p "$(dirname -- "${unzip_destination_path}")"
    unzip -p "${unzip_archive_path}" "${unzip_member_path}" > "${unzip_destination_path}"
}

extract_zip_member_python() {
    python_archive_path="$1"
    python_member_path="$2"
    python_destination_path="$3"

    mkdir -p "$(dirname -- "${python_destination_path}")"
    python3 - "$python_archive_path" "$python_member_path" "$python_destination_path" <<'PY'
import shutil
import sys
import zipfile

archive_path, member_path, destination = sys.argv[1:4]
with zipfile.ZipFile(archive_path) as archive:
    with archive.open(member_path) as source, open(destination, 'wb') as target:
        shutil.copyfileobj(source, target)
PY
}

download_windows_nuget_driver() {
    downloads_dir="$1"
    lib_dir="$2"
    driver="$3"

    package_id="apache.arrow.adbc.drivers.interop.${driver}"
    archive_path="${downloads_dir}/${driver}-${ADBC_NUGET_VERSION}.nupkg"
    member_path="runtimes/win-x64/native/libadbc_driver_${driver}.dll"
    destination="${lib_dir}/adbc_driver_${driver}.dll"
    url="https://api.nuget.org/v3-flatcontainer/${package_id}/${ADBC_NUGET_VERSION}/${package_id}.${ADBC_NUGET_VERSION}.nupkg"

    download_file_python "${url}" "${archive_path}"
    extract_zip_member_python "${archive_path}" "${member_path}" "${destination}"
}

download_windows_duckdb() {
    downloads_dir="$1"
    lib_dir="$2"

    archive_path="${downloads_dir}/libduckdb-windows-amd64-${DUCKDB_VERSION}.zip"
    destination="${lib_dir}/duckdb.dll"
    member_path="duckdb.dll"
    url="https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/libduckdb-windows-amd64.zip"

    download_file_python "${url}" "${archive_path}"
    extract_zip_member_unzip "${archive_path}" "${member_path}" "${destination}"
}

if [ "$#" -gt 0 ]; then
    REQUESTED_RAW=$(printf '%s\n' "$@" | paste -sd, -)
else
    REQUESTED_RAW="${ADBC_PREBUILT_DRIVERS:-driver_manager,sqlite,postgresql,flightsql,snowflake,duckdb}"
fi

if [ -n "${ADBC_TARGETS:-}" ]; then
    TARGETS_RAW="${ADBC_TARGETS}"
elif [ "${ADBC_ALL_PLATFORMS:-0}" = "1" ]; then
    TARGETS_RAW=$(all_supported_subdirs | paste -sd, -)
else
    TARGETS_RAW="${ADBC_CONDA_SUBDIR:-$(host_default_subdir)}"
fi

requested_drivers=""
skipped_messages=""
already_present_messages=""
dependency_skip_messages=""

for raw_driver in $(printf '%s' "${REQUESTED_RAW}" | tr ',' ' '); do
    [ -n "${raw_driver}" ] || continue
    driver=$(normalize_driver "${raw_driver}") || {
        echo "unsupported ADBC driver: ${raw_driver}" >&2
        exit 1
    }

    case "${driver}" in
        bigquery)
            skipped_messages="${skipped_messages}bigquery: no official native C/C++ prebuilt package is published; current upstream packaging only exposes this driver through the C# distribution and the Go implementation via the driver manager\n"
            ;;
        *)
            case " ${requested_drivers} " in
                *" ${driver} "*) ;;
                *) requested_drivers="${requested_drivers} ${driver}" ;;
            esac
            ;;
    esac
done

if [ -z "${requested_drivers# }" ]; then
    printf 'no requested prebuilt ADBC drivers are downloadable for this repository layout\n' >&2
    if [ -n "${skipped_messages}" ]; then
        printf '%b' "${skipped_messages}" >&2
    fi
    exit 1
fi

downloaded_any=0
fulfilled_any=0

for conda_subdir in $(printf '%s' "${TARGETS_RAW}" | tr ',' ' '); do
    [ -n "${conda_subdir}" ] || continue
    host_tag=$(host_tag_for_subdir "${conda_subdir}") || {
        echo "unsupported ADBC target platform: ${conda_subdir}" >&2
        exit 1
    }

    packages=""
    runtime_packages=""
    conda_drivers=""
    nuget_drivers=""
    duckdb_release_required=0
    lib_dir="${LIB_ROOT}/${host_tag}"
    tmp_prefix="${TMP_ROOT}/${host_tag}"
    pkg_cache_dir="${tmp_prefix}/pkgs"
    downloads_dir="${tmp_prefix}/downloads"

    for driver in ${requested_drivers}; do
        source_kind=$(driver_source_on_subdir "${conda_subdir}" "${driver}")

        if [ "${DEPENDENCIES_ONLY}" = "1" ]; then
            if ! driver_has_external_runtime_dependencies "${driver}"; then
                dependency_skip_messages="${dependency_skip_messages}${host_tag}/${driver}: no external shared-library dependencies to download\n"
                fulfilled_any=1
                continue
            fi

            if driver_dependency_bundle_ready "${lib_dir}" "${host_tag}" "${driver}"; then
                already_present_messages="${already_present_messages}${host_tag}/${driver}: shared-library dependencies already present, skipping download\n"
                fulfilled_any=1
                continue
            fi
        fi

        if [ "${DEPENDENCIES_ONLY}" != "1" ] && driver_artifacts_ready "${lib_dir}" "${host_tag}" "${driver}"; then
            already_present_messages="${already_present_messages}${host_tag}/${driver}: already present, skipping download\n"
            fulfilled_any=1
            continue
        fi

        case "${source_kind}" in
            conda)
                if runtime_package=$(runtime_packages_for_driver "${driver}" "${conda_subdir}" 2>/dev/null); then
                    case " ${runtime_packages} " in
                        *" ${runtime_package} "*) ;;
                        *) runtime_packages="${runtime_packages} ${runtime_package}" ;;
                    esac
                fi
                if [ "${DEPENDENCIES_ONLY}" != "1" ]; then
                    package=$(package_name_for_driver "${driver}")
                    packages="${packages} ${package}"
                fi
                conda_drivers="${conda_drivers} ${driver}"
                ;;
            nuget)
                if [ "${DEPENDENCIES_ONLY}" = "1" ]; then
                    dependency_skip_messages="${dependency_skip_messages}${host_tag}/${driver}: no external shared-library dependencies are modeled for this package source\n"
                    fulfilled_any=1
                    continue
                fi
                nuget_drivers="${nuget_drivers} ${driver}"
                ;;
            duckdb-release)
                if [ "${DEPENDENCIES_ONLY}" = "1" ]; then
                    dependency_skip_messages="${dependency_skip_messages}${host_tag}/duckdb: no external shared-library dependencies to download\n"
                    fulfilled_any=1
                    continue
                fi
                duckdb_release_required=1
                ;;
            *)
                skipped_messages="${skipped_messages}${host_tag}/${driver}: no official native package is published for ${conda_subdir}\n"
                ;;
        esac
    done

    if [ -z "${conda_drivers# }" ] && [ -z "${nuget_drivers# }" ] && [ "${duckdb_release_required}" != "1" ]; then
        continue
    fi

    rm -rf "${tmp_prefix}"
    mkdir -p "${tmp_prefix}" "${lib_dir}" "${pkg_cache_dir}" "${downloads_dir}"

    if [ -n "${runtime_packages# }" ] || [ -n "${packages# }" ]; then
        virtual_env=$(conda_virtual_package_env "${conda_subdir}")
        env CONDA_SUBDIR="${conda_subdir}" CONDA_PKGS_DIRS="${pkg_cache_dir}" ${virtual_env} conda create -y -p "${tmp_prefix}" -c conda-forge --override-channels ${packages} ${runtime_packages}

        if [ "${DEPENDENCIES_ONLY}" != "1" ]; then
            copy_all_shared_libraries "${tmp_prefix}" "${lib_dir}" "${host_tag}"
        fi

        for driver in ${conda_drivers}; do
            if [ "${DEPENDENCIES_ONLY}" != "1" ]; then
                copy_runtime_library "${tmp_prefix}" "${lib_dir}" "${host_tag}" "${driver}"
            fi
            copy_runtime_dependencies "${tmp_prefix}" "${lib_dir}" "${host_tag}" "${driver}"
        done
    fi

    for driver in ${nuget_drivers}; do
        download_windows_nuget_driver "${downloads_dir}" "${lib_dir}" "${driver}"
    done

    if [ "${duckdb_release_required}" = "1" ]; then
        download_windows_duckdb "${downloads_dir}" "${lib_dir}"
    fi

    downloaded_any=1
    fulfilled_any=1
    if [ "${DEPENDENCIES_ONLY}" = "1" ]; then
        printf 'downloaded shared-library dependencies for %s into %s:\n' "${host_tag}" "${lib_dir}"
        for driver in ${conda_drivers}; do
            if driver_has_external_runtime_dependencies "${driver}"; then
                printf '  - %s\n' "${driver}"
            fi
        done
    else
        printf 'downloaded prebuilt Arrow ADBC drivers for %s into %s:\n' "${host_tag}" "${lib_dir}"
        for driver in ${conda_drivers} ${nuget_drivers}; do
            printf '  - %s\n' "${driver}"
        done
        if [ "${duckdb_release_required}" = "1" ]; then
            printf '  - duckdb\n'
        fi
    fi
done

if [ "${fulfilled_any}" != "1" ]; then
    printf 'no requested prebuilt ADBC drivers were downloadable for the requested targets\n' >&2
    if [ -n "${skipped_messages}" ]; then
        printf '%b' "${skipped_messages}" >&2
    fi
    exit 1
fi

if [ "${downloaded_any}" != "1" ] && [ -n "${already_present_messages}" ]; then
    if [ "${DEPENDENCIES_ONLY}" = "1" ]; then
        printf 'all requested shared-library dependencies are already present\n'
    else
        printf 'all requested prebuilt ADBC drivers are already present\n'
    fi
fi

if [ -n "${already_present_messages}" ]; then
    printf 'already present:\n%b' "${already_present_messages}"
fi

if [ -n "${dependency_skip_messages}" ]; then
    printf 'dependency-only skips:\n%b' "${dependency_skip_messages}"
fi

if [ -n "${skipped_messages}" ]; then
    printf 'skipped drivers:\n%b' "${skipped_messages}"
fi
