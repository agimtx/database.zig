from __future__ import annotations

import configparser
import importlib
import os
import sys
import unittest
import uuid
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_BINDING_ROOT = REPO_ROOT / "bindings" / "python"
DEFAULT_ENV_FILE = REPO_ROOT / ".env"
TEST_SQL = "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value"

if str(PYTHON_BINDING_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_BINDING_ROOT))

_binding_module = importlib.import_module("database_zig")
ConnectionManager = _binding_module.ConnectionManager
ColumnType = _binding_module.ColumnType


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


def read_result_set_values(result_set: object, column_index: int) -> list[str | None]:
    return [result_set.value(row_index, column_index) for row_index in range(result_set.row_count)]


def build_type_coverage_case(section: str, table_name: str) -> dict[str, object]:
    if section == "postgres":
        return {
            "metadata_database": "public",
            "create_table_sql": (
                f"create table {table_name} ("
                "id bigint primary key, "
                "bool_value boolean not null, "
                "int_value bigint not null, "
                "float_value double precision not null, "
                "text_value text not null, "
                "binary_value bytea not null, "
                "decimal_value numeric(10, 2) not null, "
                "timestamp_value timestamp not null, "
                "json_value jsonb not null"
                ")"
            ),
            "insert_sql": (
                f"insert into {table_name} ("
                "id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, timestamp_value, json_value"
                ") values ("
                "1, true, 42, 3.5, 'alpha', decode('0102ff', 'hex'), 123.45, timestamp '2024-01-02 03:04:05', '{\"enabled\":true,\"count\":1}'::jsonb"
                ")"
            ),
            "select_sql": (
                f"select id, bool_value, int_value, float_value, text_value, binary_value, "
                f"decimal_value, timestamp_value, json_value from {table_name} order by id"
            ),
            "expected_columns": [
                {"name": "id", "column_type": ColumnType.INT64},
                {"name": "bool_value", "column_type": ColumnType.BOOLEAN},
                {"name": "int_value", "column_type": ColumnType.INT64},
                {"name": "float_value", "column_type": ColumnType.FLOAT64},
                {"name": "text_value", "column_type": ColumnType.TEXT},
                {"name": "binary_value", "column_type": ColumnType.BINARY},
                {"name": "decimal_value", "column_type": [ColumnType.DECIMAL, ColumnType.TEXT]},
                {"name": "timestamp_value", "column_type": ColumnType.TIMESTAMP},
                {"name": "json_value", "column_type": [ColumnType.JSON, ColumnType.TEXT]},
            ],
        }

    if section == "starrocks":
        return {
            "metadata_database": None,
            "create_table_sql": (
                f"create table {table_name} ("
                "id bigint not null, "
                "bool_value boolean not null, "
                "int_value bigint not null, "
                "float_value double not null, "
                "text_value string not null, "
                "decimal_value decimal(10, 2) not null, "
                "timestamp_value datetime not null, "
                "json_value json not null"
                ") duplicate key(id) distributed by hash(id) buckets 1 "
                'properties ("replication_num" = "1")'
            ),
            "insert_sql": (
                f"insert into {table_name} ("
                "id, bool_value, int_value, float_value, text_value, decimal_value, timestamp_value, json_value"
                ") values ("
                "1, true, 42, 3.5, 'alpha', 123.45, '2024-01-02 03:04:05', parse_json('{\"enabled\": true, \"count\": 1}')"
                ")"
            ),
            "select_sql": (
                f"select id, bool_value, int_value, float_value, text_value, "
                f"decimal_value, timestamp_value, json_value from {table_name} order by id"
            ),
            "expected_columns": [
                {"name": "id", "column_type": ColumnType.INT64},
                {"name": "bool_value", "column_type": [ColumnType.BOOLEAN, ColumnType.INT64]},
                {"name": "int_value", "column_type": ColumnType.INT64},
                {"name": "float_value", "column_type": ColumnType.FLOAT64},
                {"name": "text_value", "column_type": ColumnType.TEXT},
                {"name": "decimal_value", "column_type": ColumnType.DECIMAL},
                {"name": "timestamp_value", "column_type": ColumnType.TIMESTAMP},
                {"name": "json_value", "column_type": [ColumnType.JSON, ColumnType.TEXT]},
            ],
        }

    raise ValueError(f"unsupported type coverage database: {section}")


def assert_non_empty_value(value: str | None, label: str) -> None:
    assert isinstance(value, str), f"{label} should be returned as text"
    assert value, f"{label} should not be empty"


def assert_boolean_value(value: str | None) -> None:
    assert value in {"true", "false", "1", "0"}, f"unexpected boolean text: {value}"


def assert_column_metadata(columns: list[object], expected_columns: list[dict[str, object]]) -> None:
    assert len(columns) == len(expected_columns)
    for actual, expected in zip(columns, expected_columns):
        assert actual.name == expected["name"]
        expected_types = expected["column_type"]
        if not isinstance(expected_types, list):
            expected_types = [expected_types]
        assert actual.column_type in expected_types


def assert_type_coverage_values(section: str, result_set: object) -> None:
    assert result_set.value(0, 0) == "1"
    assert_boolean_value(result_set.value(0, 1))
    assert result_set.value(0, 2) == "42"
    float_value = result_set.value(0, 3)
    assert isinstance(float_value, str)
    assert float_value.startswith("3.5")
    assert result_set.value(0, 4) == "alpha"

    if section == "postgres":
        assert result_set.value(0, 5) == "0102ff"
        assert_non_empty_value(result_set.value(0, 6), "decimal_value")
        timestamp_value = result_set.value(0, 7)
        assert isinstance(timestamp_value, str)
        assert timestamp_value.lstrip("-").isdigit()
        json_value = result_set.value(0, 8)
        assert isinstance(json_value, str)
        assert '"enabled"' in json_value
        return

    if section == "starrocks":
        assert_non_empty_value(result_set.value(0, 5), "decimal_value")
        timestamp_value = result_set.value(0, 6)
        assert isinstance(timestamp_value, str)
        assert timestamp_value.lstrip("-").isdigit()
        json_value = result_set.value(0, 7)
        assert isinstance(json_value, str)
        assert '"enabled"' in json_value
        return

    raise ValueError(f"unsupported type coverage database: {section}")


async def assert_type_coverage(connection: object, section: str, table_name: str) -> dict[str, object]:
    type_coverage = build_type_coverage_case(section, table_name)
    await execute_non_query(connection, type_coverage["create_table_sql"])
    await execute_non_query(connection, type_coverage["insert_sql"])

    result_set = await connection.execute_async(type_coverage["select_sql"])
    try:
        assert result_set.row_count == 1
        assert_column_metadata(result_set.columns, type_coverage["expected_columns"])
        assert_type_coverage_values(section, result_set)
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