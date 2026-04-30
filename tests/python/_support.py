from __future__ import annotations

import configparser
import importlib
import os
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PYTHON_BINDING_ROOT = REPO_ROOT / "bindings" / "python"
DEFAULT_ENV_FILE = REPO_ROOT / ".env"
TEST_SQL = "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value"

if str(PYTHON_BINDING_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_BINDING_ROOT))

ConnectionManager = importlib.import_module("database_zig").ConnectionManager


def load_test_target(section: str) -> tuple[str, str]:
    env_file = Path(os.getenv("DATABASE_ZIG_TEST_ENV_FILE", str(DEFAULT_ENV_FILE)))
    if not env_file.exists():
        raise unittest.SkipTest(f"test config not found: {env_file}")

    parser = configparser.ConfigParser()
    parser.read(env_file)

    resolved_section = resolve_section_name(parser, section)
    if resolved_section is None:
        raise unittest.SkipTest(f"test section not found: {section}")

    config = {key: value for key, value in parser.items(resolved_section)}
    return "adbc", build_dsn(resolved_section, config)


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


def build_dsn(section: str, config: dict[str, str]) -> str:
    explicit_dsn = config.get("dsn")
    if explicit_dsn:
        return explicit_dsn

    scheme = config.get("scheme") or default_scheme(section)
    host = config.get("host", "127.0.0.1")
    port = config.get("port")
    username = config.get("user", "")
    password = config.get("password")
    database = config.get("database") or default_database(section)

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

    driver, dsn = load_test_target(section)

    async with ConnectionManager() as manager:
        connection = await manager.connect_async(driver, dsn)
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