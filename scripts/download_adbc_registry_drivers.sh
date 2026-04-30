#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION="${ADBC_VERSION:-1.11.0}"
DEST_DIR="${ROOT}/third_party/adbc/${VERSION}"
LIB_ROOT="${DEST_DIR}/lib"
LICENSE_ROOT="${DEST_DIR}/licenses"

: "${https_proxy:=http://127.0.0.1:7890}"
: "${http_proxy:=http://127.0.0.1:7890}"
: "${all_proxy:=socks5://127.0.0.1:7890}"
export https_proxy http_proxy all_proxy

if [ "$#" -gt 0 ]; then
    set -- "$@"
else
    # shellcheck disable=SC2086
    set -- ${ADBC_REGISTRY_DRIVERS:-mysql mssql redshift bigquery trino databricks clickhouse exasol singlestore}
fi

python3 - "$LIB_ROOT" "$LICENSE_ROOT" "$@" <<'PY'
import pathlib
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from urllib.error import HTTPError, URLError

lib_root = pathlib.Path(sys.argv[1])
license_root = pathlib.Path(sys.argv[2])
drivers = sys.argv[3:]
base_url = "https://dbc-cdn.columnar.tech/"
platform_map = {
    "macos_arm64": "macos-arm64",
    "macos_amd64": "macos-x86_64",
    "linux_arm64": "linux-arm64",
    "linux_amd64": "linux-x86_64",
    "windows_amd64": "windows-x86_64",
}

driver_aliases = {
    "mysql-driver": "mysql",
    "mssqlserver": "mssql",
    "mssql-server": "mssql",
    "sqlserver": "mssql",
    "sql-server": "mssql",
}


def fetch_text(url: str) -> str:
    with urllib.request.urlopen(url) as response:
        return response.read().decode("utf-8", "replace")


def normalize_driver(driver: str) -> str:
    return driver_aliases.get(driver.lower(), driver.lower())


def download_archive(url: str, destination: pathlib.Path):
    last_error = None

    for _ in range(5):
        try:
            with urllib.request.urlopen(url) as response, open(destination, "wb") as archive_file:
                shutil.copyfileobj(response, archive_file)

            with tarfile.open(destination, "r:gz") as tar:
                tar.getmembers()

            return
        except (OSError, EOFError, tarfile.TarError, HTTPError, URLError) as exc:
            last_error = exc
            destination.unlink(missing_ok=True)

    raise SystemExit(f"failed to download valid archive from {url}: {last_error}")


def latest_packages(index_text: str, driver: str):
    match = re.search(
        rf"(?ms)^- name: .*?^  path: {re.escape(driver)}\n(.*?)(?=^- name: |\Z)",
        index_text,
    )
    if not match:
        raise SystemExit(f"missing driver in index: {driver}")

    block = match.group(1)
    versions = list(re.finditer(r"(?ms)^  - packages:\n(.*?)(^    version: (v[^\n]+))", block))
    if not versions:
        raise SystemExit(f"missing versions for {driver}")

    packages_block, _, version = versions[-1].groups()
    packages = {
        platform: relative_url.strip()
        for platform, relative_url in re.findall(
            r"^    - platform: ([^\n]+)\n      url:\s*(?:\n\s+)?([^\n]+)",
            packages_block,
            flags=re.M,
        )
    }
    return version, packages


def extract_member(archive: pathlib.Path, member_name: str, destination: pathlib.Path):
    with tarfile.open(archive, "r:gz") as tar:
        with tar.extractfile(member_name) as source, open(destination, "wb") as target:
            shutil.copyfileobj(source, target)


def shared_library_members(names, platform: str):
    suffixes = (".dll",) if platform.startswith("windows_") else (".dylib", ".so")
    return [
        name
        for name in names
        if pathlib.Path(name).suffix.lower() in suffixes
    ]


requested_drivers = []
for raw_driver in drivers:
    driver = normalize_driver(raw_driver)
    if driver not in requested_drivers:
        requested_drivers.append(driver)

index_text = fetch_text(base_url + "index.yaml")
license_root.mkdir(parents=True, exist_ok=True)

for driver in requested_drivers:
    version, packages = latest_packages(index_text, driver)
    print(f"==> {driver} {version}")
    license_written = False
    notice_written = False

    for platform, subdir in platform_map.items():
        relative_url = packages.get(platform)
        if relative_url is None:
            print(f"  skip {platform}: no published package")
            continue

        with tempfile.TemporaryDirectory(prefix=f"adbc-{driver}-") as temp_dir:
            archive_path = pathlib.Path(temp_dir) / "driver.tar.gz"
            download_archive(base_url + relative_url, archive_path)

            with tarfile.open(archive_path, "r:gz") as tar:
                names = [member.name for member in tar.getmembers()]

            library_members = shared_library_members(names, platform)
            if not library_members:
                raise SystemExit(f"library not found for {driver} on {platform}")

            destination_dir = lib_root / subdir
            destination_dir.mkdir(parents=True, exist_ok=True)
            extracted = []
            for library_member in library_members:
                destination_path = destination_dir / pathlib.Path(library_member).name
                extract_member(archive_path, library_member, destination_path)
                extracted.append(destination_path.relative_to(lib_root.parent.parent.parent))

            print(f"  downloaded {platform} -> {', '.join(str(path) for path in extracted)}")

            if not license_written:
                license_member = next((name for name in names if pathlib.Path(name).name == "LICENSE"), None)
                if license_member is not None:
                    extract_member(archive_path, license_member, license_root / f"LICENSE.{driver}-driver.txt")
                    license_written = True

            if not notice_written:
                notice_member = next((name for name in names if pathlib.Path(name).name == "NOTICE"), None)
                if notice_member is not None:
                    extract_member(archive_path, notice_member, license_root / f"NOTICE.{driver}-driver.txt")
                    notice_written = True
PY