from __future__ import annotations

from collections.abc import Callable
import configparser
import importlib
import os
import platform
import sys
import unittest
import uuid
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_BINDING_ROOT = REPO_ROOT / "bindings" / "python"
DEFAULT_ENV_FILE = REPO_ROOT / ".env"
REPO_TMP_ROOT = REPO_ROOT / ".tmp"
TEST_SQL = "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value"

if str(PYTHON_BINDING_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_BINDING_ROOT))

_binding_module = importlib.import_module("aq_database")
ConnectionManager = _binding_module.ConnectionManager
ColumnType = _binding_module.ColumnType
QualifiedName = _binding_module.QualifiedName
QualifiedNamePartRole = _binding_module.QualifiedNamePartRole


@dataclass(frozen=True)
class TestTarget:
    driver: str
    section: str
    config: dict[str, str]

    def dsn(self, database_override: str | None = None) -> str:
        return build_dsn(self.section, self.config, database_override)


def load_test_target(section: str) -> TestTarget:
    env_file = Path(os.getenv("DATABASE_ZIG_TEST_ENV_FILE", str(DEFAULT_ENV_FILE)))
    if not env_file.exists():
        raise unittest.SkipTest(f"test config not found: {env_file}")

    parser = configparser.ConfigParser()
    parser.read(env_file)

    resolved_section = resolve_section_name(parser, section)
    if resolved_section is None:
        raise unittest.SkipTest(f"test section not found: {section}")

    config = {key: value for key, value in parser.items(resolved_section)}
    return TestTarget(driver="adbc", section=resolved_section, config=config)


def resolve_section_name(parser: configparser.ConfigParser, section: str) -> str | None:
    aliases = {
        "postgresql": "postgres",
    }
    candidates = [section, aliases.get(section.lower(), section)]
    for candidate in candidates:
        if parser.has_section(candidate):
            return candidate
    return None


def should_run_section(section: str) -> bool:
    requested = os.getenv("DATABASE_ZIG_TEST_SECTION")
    return requested is None or requested.lower() == section.lower()


def build_dsn(section: str, config: dict[str, str], database_override: str | None = None) -> str:
    explicit_dsn = config.get("dsn")
    if explicit_dsn and database_override is None:
        return explicit_dsn

    scheme = config.get("scheme") or default_scheme(section)
    host = config.get("host", "127.0.0.1")
    port = config.get("port")
    username = config.get("user", "")
    password = config.get("password")
    database = database_override if database_override is not None else (config.get("database") or default_database(section))

    credentials = ""
    if username:
        credentials = escape_uri_part(username)
        if password is not None:
            credentials += f":{escape_uri_part(password)}"
        credentials += "@"

    port_part = f":{port}" if port else ""
    database_part = f"/{escape_path_part(database)}" if database else ""
    return f"{scheme}://{credentials}{host}{port_part}{database_part}"


def default_scheme(section: str) -> str:
    lowered = section.lower()
    if lowered in {"postgres", "postgresql"}:
        return "postgresql"
    if lowered in {"starrocks", "mysql", "singlestore"}:
        return "mysql"
    return lowered


def default_database(section: str) -> str:
    lowered = section.lower()
    if lowered in {"postgres", "postgresql"}:
        return "postgres"
    if lowered in {"starrocks", "mysql", "singlestore"}:
        return "information_schema"
    return ""


def escape_uri_part(value: str) -> str:
    from urllib.parse import quote

    return quote(value, safe="")


def escape_path_part(value: str) -> str:
    from urllib.parse import quote

    return quote(value, safe="")


def repo_tmp_dir(*parts: str) -> Path:
    target = REPO_TMP_ROOT.joinpath(*parts)
    target.mkdir(parents=True, exist_ok=True)
    return target


def vendored_adbc_driver_path(name: str) -> Path:
    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "darwin":
        host = "macos-arm64" if machine in {"arm64", "aarch64"} else "macos-x86_64"
        suffix = ".dylib"
        file_name = f"lib{name}{suffix}" if name == "duckdb" else f"libadbc_driver_{name}{suffix}"
    elif system == "linux":
        host = "linux-arm64" if machine in {"arm64", "aarch64"} else "linux-x86_64"
        suffix = ".so"
        file_name = f"lib{name}{suffix}" if name == "duckdb" else f"libadbc_driver_{name}{suffix}"
    elif system == "windows":
        host = "windows-x86_64"
        file_name = f"{name}.dll" if name == "duckdb" else f"adbc_driver_{name}.dll"
    else:
        raise RuntimeError(f"unsupported platform for vendored ADBC driver lookup: {system}")

    return REPO_ROOT / "third_party" / "adbc" / "1.11.0" / "lib" / host / file_name


def duckdb_test_dsn(database_path: Path) -> str:
    driver_path = vendored_adbc_driver_path("duckdb")
    return f"driver={driver_path};entrypoint=duckdb_adbc_init;path={database_path}"


def remove_file_if_exists(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


async def assert_database_binding(section: str) -> None:
    if not should_run_section(section):
        raise unittest.SkipTest(f"DATABASE_ZIG_TEST_SECTION is filtering out {section}")

    target = load_test_target(section)

    async with ConnectionManager() as manager:
        connection = await manager.connect_async(target.driver, target.dsn())
        try:
            result_set = await connection.execute_async(TEST_SQL)
            try:
                assert result_set.row_count == 2
                assert result_set.affected_rows == 2

                columns = result_set.columns
                assert len(columns) == 2
                assert columns[0].name == "id"
                assert columns[1].name == "value"
            finally:
                await result_set.close_async()

            cursor = await connection.cursor_async(TEST_SQL)
            try:
                cursor_columns = cursor.columns
                assert len(cursor_columns) == 2

                seen_rows = 0
                while cursor.next():
                    seen_rows += 1
                assert seen_rows == 2
            finally:
                await cursor.close_async()
        finally:
            await connection.close_async()


def unique_identifier(prefix: str) -> str:
    suffix = uuid.uuid4().hex[:8]
    return f"{prefix}_{suffix}"


async def execute_non_query(connection: object, sql: str) -> None:
    result_set = await connection.execute_async(sql)
    await result_set.close_async()


def read_result_set_values(result_set: object, column_index: int) -> list[object | None]:
    return [result_set.value(row_index, column_index) for row_index in range(result_set.row_count)]


def find_result_set_row_index(result_set: object, column_index: int, expected_value: object) -> int:
    for row_index in range(result_set.row_count):
        if result_set.value(row_index, column_index) == expected_value:
            return row_index

    raise AssertionError(f"value not found in result set column {column_index}: {expected_value!r}")


def _qualified_name_role_from_namespace_kind(namespace_kind: str) -> object:
    mapping = {
        "catalog": QualifiedNamePartRole.CATALOG,
        "database": QualifiedNamePartRole.DATABASE,
        "schema": QualifiedNamePartRole.SCHEMA,
        "dataset": QualifiedNamePartRole.DATASET,
        "namespace": QualifiedNamePartRole.NAMESPACE,
        "object": QualifiedNamePartRole.OBJECT,
    }
    return mapping[namespace_kind]


def assert_table_qualified_name(result_set: object, row_index: int) -> object:
    qualified_name = result_set.table_qualified_name(row_index)
    assert isinstance(qualified_name, QualifiedName)

    expected_parts: list[tuple[object, str]] = []
    catalog = result_set.value(row_index, 0)
    namespace = result_set.value(row_index, 1)
    object_name = result_set.value(row_index, 2)
    namespace_kind = result_set.value(row_index, 4)
    formatted = result_set.value(row_index, 5)

    if catalog not in (None, ""):
        expected_parts.append((QualifiedNamePartRole.CATALOG, catalog))
    if namespace not in (None, ""):
        expected_parts.append((_qualified_name_role_from_namespace_kind(namespace_kind), namespace))
    if object_name not in (None, ""):
        expected_parts.append((QualifiedNamePartRole.OBJECT, object_name))

    assert [(part.role, part.value) for part in qualified_name.parts] == expected_parts
    assert qualified_name.formatted == formatted
    return qualified_name


def assert_non_empty_value(value: object | None, label: str) -> None:
    assert value not in (None, b"", ""), f"{label} should not be empty"


def is_runtime_unavailable_error(error: BaseException) -> bool:
    message = str(error)
    return (
        "Could not load" in message
        or "Library not loaded" in message
        or "connection refused" in message.lower()
        or "timed out" in message.lower()
        or "aq_connection_open failed:" in message
        or "aq_connection_open_async failed:" in message
    )


def assert_hex_value(value: object | None, label: str) -> None:
    if isinstance(value, bytes):
        assert value, f"{label} should not be empty"
        return

    assert isinstance(value, str), f"{label} should be returned as bytes or hexadecimal text"
    assert value, f"{label} should not be empty"
    assert len(value) % 2 == 0, f"{label} should have an even number of hex characters"
    assert all(character in "0123456789abcdef" for character in value.lower()), f"{label} should be lowercase hexadecimal"


def assert_boolean_value(value: object | None) -> None:
    assert isinstance(value, bool), f"unexpected boolean value: {value!r}"


def assert_column_metadata(columns: list[object], expected_columns: list[dict[str, object]]) -> None:
    assert len(columns) == len(expected_columns)
    for actual, expected in zip(columns, expected_columns):
        assert actual.name == expected["name"]
        expected_types = expected["column_type"]
        if not isinstance(expected_types, list):
            expected_types = [expected_types]
        assert actual.column_type in expected_types
        if "raw_type" in expected:
            assert actual.raw_type == expected["raw_type"]


async def assert_type_coverage(
    connection: object,
    type_coverage: dict[str, object],
    assert_values: Callable[[object], None],
) -> dict[str, object]:
    await execute_non_query(connection, type_coverage["create_table_sql"])
    await execute_non_query(connection, type_coverage["insert_sql"])

    result_set = await connection.execute_async(type_coverage["select_sql"])
    try:
        assert result_set.row_count == 1
        assert_column_metadata(result_set.columns, type_coverage["expected_columns"])
        assert_values(result_set)
    finally:
        await result_set.close_async()

    cursor = await connection.cursor_async(type_coverage["select_sql"])
    try:
        assert_column_metadata(cursor.columns, type_coverage["expected_columns"])
        assert cursor.next() is True
        assert cursor.next() is False
    finally:
        await cursor.close_async()

    return type_coverage