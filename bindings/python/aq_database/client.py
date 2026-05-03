from __future__ import annotations

from collections.abc import Mapping
import asyncio
import ctypes
import datetime as dt
import json
import os
import platform
import uuid
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from enum import IntEnum
from pathlib import Path
from typing import Any
from urllib.parse import quote


_DRIVER_MAP = {
    "adbc": 1,
}

_STATUS_MESSAGES = {
    1: "invalid argument",
    2: "driver not registered",
    3: "connection not found",
    4: "result set not found",
    5: "cursor not found",
    6: "column index out of bounds",
    7: "row index out of bounds",
    8: "operation not found",
    255: "internal error",
}


class DriverKind(IntEnum):
    ADBC = 1


class ColumnType(IntEnum):
    UNKNOWN = 0
    BOOLEAN = 1
    INT64 = 2
    FLOAT64 = 3
    TEXT = 4
    BINARY = 5
    DECIMAL = 6
    TIMESTAMP = 7
    JSON = 8
    DATE = 9
    TIME = 10
    INTERVAL = 11
    UUID = 12
    ARRAY = 13
    MAP = 14
    STRUCT = 15
    INT8 = 16
    UINT8 = 17
    INT16 = 18
    UINT16 = 19
    INT32 = 20
    UINT32 = 21
    UINT64 = 22
    FLOAT16 = 23
    FLOAT32 = 24
    DURATION = 25


class QualifiedNamePartRole(IntEnum):
    CATALOG = 0
    DATABASE = 1
    SCHEMA = 2
    DATASET = 3
    NAMESPACE = 4
    OBJECT = 5


class _CColumnMetadata(ctypes.Structure):
    _fields_ = [
        ("name_ptr", ctypes.c_void_p),
        ("name_len", ctypes.c_size_t),
        ("raw_type_ptr", ctypes.c_void_p),
        ("raw_type_len", ctypes.c_size_t),
        ("column_type", ctypes.c_int32),
        ("nullable", ctypes.c_uint8),
    ]


class _CQualifiedNamePart(ctypes.Structure):
    _fields_ = [
        ("role", ctypes.c_int32),
        ("value_ptr", ctypes.c_void_p),
        ("value_len", ctypes.c_size_t),
    ]


class _CQualifiedName(ctypes.Structure):
    _fields_ = [
        ("part_count", ctypes.c_size_t),
        ("formatted_ptr", ctypes.c_void_p),
        ("formatted_len", ctypes.c_size_t),
        ("parts", _CQualifiedNamePart * 3),
    ]


class _CNamespaceAccess(ctypes.Structure):
    _fields_ = [
        ("namespace_role", ctypes.c_int32),
        ("can_get_schema", ctypes.c_uint8),
        ("has_catalog_access", ctypes.c_uint8),
        ("has_namespace_access", ctypes.c_uint8),
        ("qualified_name", _CQualifiedName),
    ]


class _COperationResult(ctypes.Structure):
    _fields_ = [
        ("state", ctypes.c_uint8),
        ("_padding", ctypes.c_uint8 * 3),
        ("status", ctypes.c_int32),
        ("value", ctypes.c_uint64),
    ]


class _CResultCell(ctypes.Structure):
    _fields_ = [
        ("text_ptr", ctypes.c_void_p),
        ("text_len", ctypes.c_size_t),
        ("is_null", ctypes.c_uint8),
    ]


class _CErrorMessage(ctypes.Structure):
    _fields_ = [
        ("message_ptr", ctypes.c_void_p),
        ("message_len", ctypes.c_size_t),
    ]


@dataclass(frozen=True)
class ColumnMetadata:
    name: str
    raw_type: str | None
    column_type: ColumnType
    nullable: bool


@dataclass(frozen=True)
class QualifiedNamePart:
    role: QualifiedNamePartRole
    value: str


@dataclass(frozen=True)
class QualifiedName:
    parts: tuple[QualifiedNamePart, ...]
    formatted: str

    def __str__(self) -> str:
        return self.formatted


@dataclass(frozen=True)
class NamespaceAccess:
    can_get_schema: bool
    has_catalog_access: bool
    has_namespace_access: bool
    namespace_role: QualifiedNamePartRole
    qualified_name: QualifiedName


ResultValue = bool | int | float | str | bytes | Decimal | dt.date | dt.time | dt.datetime | uuid.UUID | list[Any] | dict[str, Any]


_DSN_URI_FIELD_NAMES = frozenset({"scheme", "host", "port", "user", "password", "database"})
_DSN_OPTION_FIELD_ORDER = ("driver", "entrypoint", "additional_manifest_search_path_list")


def build_dsn(
    *,
    dsn: str | None = None,
    uri: str | None = None,
    driver: str | None = None,
    entrypoint: str | None = None,
    additional_manifest_search_path_list: str | None = None,
    scheme: str | None = None,
    host: str | None = None,
    port: str | None = None,
    user: str | None = None,
    password: str | None = None,
    database: str | None = None,
    extra_options: Mapping[str, str] | None = None,
) -> str:
    explicit_dsn = dsn
    if explicit_dsn:
        return explicit_dsn

    resolved_extra_options = dict(extra_options or {})

    if _should_build_option_string_dsn(uri=uri, driver=driver, entrypoint=entrypoint, additional_manifest_search_path_list=additional_manifest_search_path_list):
        return _build_option_string_dsn(
            uri=uri,
            driver=driver,
            entrypoint=entrypoint,
            additional_manifest_search_path_list=additional_manifest_search_path_list,
            scheme=scheme,
            host=host,
            port=port,
            user=user,
            password=password,
            database=database,
            extra_options=resolved_extra_options,
        )

    return _build_uri_dsn(
        uri=uri,
        scheme=scheme,
        host=host,
        port=port,
        user=user,
        password=password,
        database=database,
        extra_options=resolved_extra_options,
    )


def _should_build_option_string_dsn(
    *,
    uri: str | None,
    driver: str | None,
    entrypoint: str | None,
    additional_manifest_search_path_list: str | None,
) -> bool:
    return uri is not None or any(
        value is not None for value in (driver, entrypoint, additional_manifest_search_path_list)
    )


def _build_option_string_dsn(
    *,
    uri: str | None,
    driver: str | None,
    entrypoint: str | None,
    additional_manifest_search_path_list: str | None,
    scheme: str | None,
    host: str | None,
    port: str | None,
    user: str | None,
    password: str | None,
    database: str | None,
    extra_options: Mapping[str, str],
) -> str:
    parts: list[str] = []
    for key, value in (
        ("driver", driver),
        ("entrypoint", entrypoint),
        ("additional_manifest_search_path_list", additional_manifest_search_path_list),
    ):
        if value is not None:
            parts.append(f"{key}={value}")

    if uri is not None or _has_uri_components(
        scheme=scheme,
        host=host,
        port=port,
        user=user,
        password=password,
        database=database,
    ):
        parts.append(
            "uri="
            + _build_uri_dsn(
                uri=uri,
                scheme=scheme,
                host=host,
                port=port,
                user=user,
                password=password,
                database=database,
                extra_options=extra_options,
            )
        )
    else:
        parts.extend(_build_extra_option_pairs(extra_options))

    return ";".join(parts)


def _build_uri_dsn(
    *,
    uri: str | None,
    scheme: str | None,
    host: str | None,
    port: str | None,
    user: str | None,
    password: str | None,
    database: str | None,
    extra_options: Mapping[str, str],
) -> str:
    explicit_uri = uri
    if explicit_uri is not None:
        return explicit_uri

    if scheme is None:
        raise ValueError("scheme is required when dsn and uri are not provided")

    resolved_scheme = scheme
    resolved_host = host or "127.0.0.1"
    resolved_port = port
    username = user or ""
    resolved_password = password
    resolved_database = database

    credentials = ""
    if username:
        credentials = quote(username, safe="")
        if resolved_password is not None:
            credentials += f":{quote(resolved_password, safe='')}"
        credentials += "@"

    port_part = f":{resolved_port}" if resolved_port else ""
    database_part = f"/{quote(resolved_database, safe='')}" if resolved_database else ""
    dsn = f"{resolved_scheme}://{credentials}{resolved_host}{port_part}{database_part}"
    query_pairs = _build_uri_query_pairs(extra_options)
    if query_pairs:
        dsn += "?" + "&".join(
            f"{quote(key, safe='')}={quote(value, safe='')}" for key, value in query_pairs
        )
    return dsn


def _has_uri_components(
    *,
    scheme: str | None,
    host: str | None,
    port: str | None,
    user: str | None,
    password: str | None,
    database: str | None,
) -> bool:
    return any(value is not None for value in (scheme, host, port, user, password, database))


def _build_uri_query_pairs(extra_options: Mapping[str, str]) -> list[tuple[str, str]]:
    return sorted(extra_options.items())


def _build_extra_option_pairs(extra_options: Mapping[str, str]) -> list[str]:
    return [f"{key}={value}" for key, value in sorted(extra_options.items())]


def _format_qualified_name_parts(parts: tuple[QualifiedNamePart, ...] | list[QualifiedNamePart]) -> str:
    return ".".join(part.value for part in parts if part.value)


def _decode_result_value(raw_value: str | None, column_type: ColumnType) -> ResultValue | None:
    if raw_value is None:
        return None

    try:
        if column_type == ColumnType.BOOLEAN:
            normalized = raw_value.lower()
            if normalized == "true" or raw_value == "1":
                return True
            if normalized == "false" or raw_value == "0":
                return False
            return raw_value

        if column_type in (ColumnType.INT8, ColumnType.UINT8, ColumnType.INT16, ColumnType.UINT16, ColumnType.INT32, ColumnType.UINT32, ColumnType.INT64, ColumnType.UINT64):
            return int(raw_value)

        if column_type in (ColumnType.FLOAT16, ColumnType.FLOAT32, ColumnType.FLOAT64):
            return float(raw_value)

        if column_type == ColumnType.BINARY:
            return bytes.fromhex(raw_value)

        if column_type == ColumnType.DECIMAL:
            return Decimal(raw_value)

        if column_type == ColumnType.TIMESTAMP:
            return dt.datetime.fromisoformat(raw_value)

        if column_type == ColumnType.JSON or column_type == ColumnType.ARRAY or column_type == ColumnType.MAP or column_type == ColumnType.STRUCT:
            return json.loads(raw_value)

        if column_type == ColumnType.DATE:
            return dt.date.fromisoformat(raw_value)

        if column_type == ColumnType.TIME:
            return dt.time.fromisoformat(raw_value)

        if column_type == ColumnType.UUID:
            return uuid.UUID(raw_value)
    except (ValueError, TypeError, json.JSONDecodeError, InvalidOperation):
        return raw_value

    return raw_value


class ResultSet:
    def __init__(self, manager: ConnectionManager, result_set_id: int) -> None:
        self._manager = manager
        self.id = result_set_id
        self._columns: list[ColumnMetadata] | None = None

    @property
    def row_count(self) -> int:
        return self._manager._result_set_row_count(self.id)

    @property
    def affected_rows(self) -> int:
        return self._manager._result_set_affected_rows(self.id)

    @property
    def columns(self) -> list[ColumnMetadata]:
        if self._columns is None:
            self._columns = self._manager._result_set_columns(self.id)
        return self._columns

    def value(self, row_index: int, column_index: int) -> ResultValue | None:
        raw_value = self._manager._result_set_value(self.id, row_index, column_index)
        return _decode_result_value(raw_value, self.columns[column_index].column_type)

    def table_qualified_name(self, row_index: int) -> QualifiedName:
        return self._manager._result_set_table_qualified_name(self.id, row_index)

    def close(self) -> None:
        self._manager._result_set_close(self.id)

    async def close_async(self) -> None:
        await asyncio.to_thread(self.close)


class Cursor:
    def __init__(self, manager: ConnectionManager, cursor_id: int) -> None:
        self._manager = manager
        self.id = cursor_id

    @property
    def columns(self) -> list[ColumnMetadata]:
        return self._manager._cursor_columns(self.id)

    def next(self) -> bool:
        return self._manager._cursor_next(self.id)

    def close(self) -> None:
        self._manager._cursor_close(self.id)

    async def close_async(self) -> None:
        await asyncio.to_thread(self.close)


class Connection:
    def __init__(self, manager: ConnectionManager, connection_id: int, driver: str, dsn: str) -> None:
        self._manager = manager
        self.id = connection_id
        self.driver = driver
        self.dsn = dsn

    def execute(self, sql: str) -> ResultSet:
        return self._manager._execute(self.id, sql)

    async def execute_async(self, sql: str) -> ResultSet:
        return await self._manager._execute_async(self.id, sql)

    def cursor(self, sql: str) -> Cursor:
        return self._manager._open_cursor(self.id, sql)

    async def cursor_async(self, sql: str) -> Cursor:
        return await self._manager._open_cursor_async(self.id, sql)

    def test(self) -> bool:
        return self._manager._connection_test(self.id)

    async def test_async(self) -> bool:
        return await self._manager._connection_test_async(self.id)

    def get_catalogs(self) -> ResultSet:
        return self._manager._get_catalogs(self.id)

    async def get_catalogs_async(self) -> ResultSet:
        return await self._manager._get_catalogs_async(self.id)

    def get_databases(self) -> ResultSet:
        return self._manager._get_databases(self.id)

    async def get_databases_async(self) -> ResultSet:
        return await self._manager._get_databases_async(self.id)

    def get_tables(self, catalog: str | None = None, database: str | None = None) -> ResultSet:
        return self._manager._get_tables(self.id, catalog, database)

    async def get_tables_async(self, catalog: str | None = None, database: str | None = None) -> ResultSet:
        return await self._manager._get_tables_async(self.id, catalog, database)

    def inspect_namespace_access(self, catalog: str | None = None, database: str | None = None) -> NamespaceAccess:
        return self._manager._inspect_namespace_access(self.id, catalog, database)

    async def inspect_namespace_access_async(self, catalog: str | None = None, database: str | None = None) -> NamespaceAccess:
        return await self._manager._inspect_namespace_access_async(self.id, catalog, database)

    def close(self) -> None:
        self._manager.close_connection(self.id)

    async def close_async(self) -> None:
        await self._manager.close_connection_async(self.id)


class ConnectionManager:
    def __init__(self, library_path: str | None = None) -> None:
        resolved_path = self._resolve_library_path(library_path)
        self._lib = ctypes.CDLL(str(resolved_path))
        self._configure_abi()
        self._manager = self._lib.aq_manager_create()

        if not self._manager:
            raise RuntimeError("failed to create aq_database connection manager")

    def connect(self, driver: str, dsn: str) -> Connection:
        driver_kind = _DRIVER_MAP.get(driver.lower())
        if driver_kind is None:
            raise ValueError(f"unsupported driver: {driver}")

        handle = self._lib.aq_connection_open(self._manager, driver_kind, dsn.encode("utf-8"))
        if handle == 0:
            self._raise_on_zero_result("aq_connection_open")

        return Connection(self, int(handle), driver, dsn)

    async def connect_async(self, driver: str, dsn: str) -> Connection:
        driver_kind = _DRIVER_MAP.get(driver.lower())
        if driver_kind is None:
            raise ValueError(f"unsupported driver: {driver}")

        operation_id = self._lib.aq_connection_open_async(self._manager, driver_kind, dsn.encode("utf-8"))
        if operation_id == 0:
            self._raise_on_zero_result("aq_connection_open_async")

        handle = await self._await_operation_value(operation_id, "aq_connection_open_async")
        return Connection(self, handle, driver, dsn)

    def open(self, driver: str, dsn: str) -> int:
        return self.connect(driver, dsn).id

    async def open_async(self, driver: str, dsn: str) -> int:
        return (await self.connect_async(driver, dsn)).id

    def close_connection(self, connection_id: int) -> None:
        self._raise_on_status(
            self._lib.aq_connection_close(self._manager, connection_id),
            "aq_connection_close",
        )

    async def close_connection_async(self, connection_id: int) -> None:
        await asyncio.to_thread(self.close_connection, connection_id)

    def close(self) -> None:
        manager = getattr(self, "_manager", None)
        if manager:
            self._lib.aq_manager_destroy(manager)
            self._manager = None

    async def close_async(self) -> None:
        await asyncio.to_thread(self.close)

    def __enter__(self) -> "ConnectionManager":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    async def __aenter__(self) -> "ConnectionManager":
        return self

    async def __aexit__(self, *_args: object) -> None:
        await self.close_async()

    def _configure_abi(self) -> None:
        self._lib.aq_manager_create.restype = ctypes.c_void_p
        self._lib.aq_manager_destroy.argtypes = [ctypes.c_void_p]
        self._lib.aq_connection_open.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.aq_connection_open.restype = ctypes.c_uint64
        self._lib.aq_connection_open_async.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.aq_connection_open_async.restype = ctypes.c_uint64
        self._lib.aq_connection_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.aq_connection_close.restype = ctypes.c_int32
        self._lib.aq_connection_test.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint8)]
        self._lib.aq_connection_test.restype = ctypes.c_int32
        self._lib.aq_connection_execute.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.aq_connection_execute.restype = ctypes.c_uint64
        self._lib.aq_connection_execute_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.aq_connection_execute_async.restype = ctypes.c_uint64
        self._lib.aq_connection_get_tables.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_char_p]
        self._lib.aq_connection_get_tables.restype = ctypes.c_uint64
        self._lib.aq_connection_get_catalogs.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.aq_connection_get_catalogs.restype = ctypes.c_uint64
        self._lib.aq_connection_get_databases.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.aq_connection_get_databases.restype = ctypes.c_uint64
        self._lib.aq_connection_inspect_namespace_access.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(_CNamespaceAccess)]
        self._lib.aq_connection_inspect_namespace_access.restype = ctypes.c_int32
        self._lib.aq_result_set_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.aq_result_set_close.restype = ctypes.c_int32
        self._lib.aq_result_set_row_count.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
        self._lib.aq_result_set_row_count.restype = ctypes.c_int32
        self._lib.aq_result_set_affected_rows.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
        self._lib.aq_result_set_affected_rows.restype = ctypes.c_int32
        self._lib.aq_result_set_column_count.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_size_t)]
        self._lib.aq_result_set_column_count.restype = ctypes.c_int32
        self._lib.aq_result_set_column_metadata.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.POINTER(_CColumnMetadata)]
        self._lib.aq_result_set_column_metadata.restype = ctypes.c_int32
        self._lib.aq_result_set_value.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(_CResultCell)]
        self._lib.aq_result_set_value.restype = ctypes.c_int32
        self._lib.aq_result_set_table_qualified_name.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.POINTER(_CQualifiedName)]
        self._lib.aq_result_set_table_qualified_name.restype = ctypes.c_int32
        self._lib.aq_cursor_open.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.aq_cursor_open.restype = ctypes.c_uint64
        self._lib.aq_cursor_open_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.aq_cursor_open_async.restype = ctypes.c_uint64
        self._lib.aq_cursor_next.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint8)]
        self._lib.aq_cursor_next.restype = ctypes.c_int32
        self._lib.aq_cursor_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.aq_cursor_close.restype = ctypes.c_int32
        self._lib.aq_cursor_column_count.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_size_t)]
        self._lib.aq_cursor_column_count.restype = ctypes.c_int32
        self._lib.aq_cursor_column_metadata.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.POINTER(_CColumnMetadata)]
        self._lib.aq_cursor_column_metadata.restype = ctypes.c_int32
        self._lib.aq_manager_open.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.aq_manager_open.restype = ctypes.c_uint64
        self._lib.aq_manager_open_async.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.aq_manager_open_async.restype = ctypes.c_uint64
        self._lib.aq_manager_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.aq_manager_close.restype = ctypes.c_int32
        self._lib.aq_operation_await.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(_COperationResult)]
        self._lib.aq_operation_await.restype = ctypes.c_int32
        self._lib.aq_last_error_message.argtypes = [ctypes.c_void_p, ctypes.POINTER(_CErrorMessage)]
        self._lib.aq_last_error_message.restype = ctypes.c_int32

    def _execute(self, connection_id: int, sql: str) -> ResultSet:
        result_set_id = self._lib.aq_connection_execute(self._manager, connection_id, sql.encode("utf-8"))
        if result_set_id == 0:
            self._raise_on_zero_result("aq_connection_execute")
        return ResultSet(self, int(result_set_id))

    async def _execute_async(self, connection_id: int, sql: str) -> ResultSet:
        operation_id = self._lib.aq_connection_execute_async(self._manager, connection_id, sql.encode("utf-8"))
        if operation_id == 0:
            self._raise_on_zero_result("aq_connection_execute_async")

        result_set_id = await self._await_operation_value(operation_id, "aq_connection_execute_async")
        return ResultSet(self, result_set_id)

    def _connection_test(self, connection_id: int) -> bool:
        out_value = ctypes.c_uint8()
        self._raise_on_status(
            self._lib.aq_connection_test(self._manager, connection_id, ctypes.byref(out_value)),
            "aq_connection_test",
        )
        return bool(out_value.value)

    async def _connection_test_async(self, connection_id: int) -> bool:
        return await asyncio.to_thread(self._connection_test, connection_id)

    def _get_catalogs(self, connection_id: int) -> ResultSet:
        result_set_id = self._lib.aq_connection_get_catalogs(self._manager, connection_id)
        if result_set_id == 0:
            self._raise_on_zero_result("aq_connection_get_catalogs")
        return ResultSet(self, int(result_set_id))

    async def _get_catalogs_async(self, connection_id: int) -> ResultSet:
        return await asyncio.to_thread(self._get_catalogs, connection_id)

    def _get_databases(self, connection_id: int) -> ResultSet:
        result_set_id = self._lib.aq_connection_get_databases(self._manager, connection_id)
        if result_set_id == 0:
            self._raise_on_zero_result("aq_connection_get_databases")
        return ResultSet(self, int(result_set_id))

    async def _get_databases_async(self, connection_id: int) -> ResultSet:
        return await asyncio.to_thread(self._get_databases, connection_id)

    def _get_tables(self, connection_id: int, catalog: str | None, database: str | None) -> ResultSet:
        result_set_id = self._lib.aq_connection_get_tables(
            self._manager,
            connection_id,
            catalog.encode("utf-8") if catalog is not None else None,
            database.encode("utf-8") if database is not None else None,
        )
        if result_set_id == 0:
            self._raise_on_zero_result("aq_connection_get_tables")
        return ResultSet(self, int(result_set_id))

    async def _get_tables_async(self, connection_id: int, catalog: str | None, database: str | None) -> ResultSet:
        return await asyncio.to_thread(self._get_tables, connection_id, catalog, database)

    def _inspect_namespace_access(self, connection_id: int, catalog: str | None, database: str | None) -> NamespaceAccess:
        raw_access = _CNamespaceAccess()
        self._raise_on_status(
            self._lib.aq_connection_inspect_namespace_access(
                self._manager,
                connection_id,
                catalog.encode("utf-8") if catalog is not None else None,
                database.encode("utf-8") if database is not None else None,
                ctypes.byref(raw_access),
            ),
            "aq_connection_inspect_namespace_access",
        )

        parts: list[QualifiedNamePart] = []
        for index in range(raw_access.qualified_name.part_count):
            raw_part = raw_access.qualified_name.parts[index]
            value = ctypes.string_at(raw_part.value_ptr, raw_part.value_len).decode("utf-8") if raw_part.value_ptr and raw_part.value_len > 0 else ""
            parts.append(QualifiedNamePart(role=QualifiedNamePartRole(raw_part.role), value=value))

        formatted = ctypes.string_at(raw_access.qualified_name.formatted_ptr, raw_access.qualified_name.formatted_len).decode("utf-8") if raw_access.qualified_name.formatted_ptr and raw_access.qualified_name.formatted_len > 0 else _format_qualified_name_parts(parts)
        return NamespaceAccess(
            can_get_schema=bool(raw_access.can_get_schema),
            has_catalog_access=bool(raw_access.has_catalog_access),
            has_namespace_access=bool(raw_access.has_namespace_access),
            namespace_role=QualifiedNamePartRole(raw_access.namespace_role),
            qualified_name=QualifiedName(parts=tuple(parts), formatted=formatted),
        )

    async def _inspect_namespace_access_async(self, connection_id: int, catalog: str | None, database: str | None) -> NamespaceAccess:
        return await asyncio.to_thread(self._inspect_namespace_access, connection_id, catalog, database)

    def _result_set_close(self, result_set_id: int) -> None:
        self._raise_on_status(
            self._lib.aq_result_set_close(self._manager, result_set_id),
            "aq_result_set_close",
        )

    def _result_set_row_count(self, result_set_id: int) -> int:
        out_value = ctypes.c_uint64()
        self._raise_on_status(
            self._lib.aq_result_set_row_count(self._manager, result_set_id, ctypes.byref(out_value)),
            "aq_result_set_row_count",
        )
        return int(out_value.value)

    def _result_set_affected_rows(self, result_set_id: int) -> int:
        out_value = ctypes.c_uint64()
        self._raise_on_status(
            self._lib.aq_result_set_affected_rows(self._manager, result_set_id, ctypes.byref(out_value)),
            "aq_result_set_affected_rows",
        )
        return int(out_value.value)

    def _result_set_columns(self, result_set_id: int) -> list[ColumnMetadata]:
        count = ctypes.c_size_t()
        self._raise_on_status(
            self._lib.aq_result_set_column_count(self._manager, result_set_id, ctypes.byref(count)),
            "aq_result_set_column_count",
        )

        columns: list[ColumnMetadata] = []
        for index in range(count.value):
            columns.append(self._read_column_metadata("aq_result_set_column_metadata", result_set_id, index, self._lib.aq_result_set_column_metadata))

        return columns

    def _result_set_value(self, result_set_id: int, row_index: int, column_index: int) -> str | None:
        raw_cell = _CResultCell()
        self._raise_on_status(
            self._lib.aq_result_set_value(self._manager, result_set_id, row_index, column_index, ctypes.byref(raw_cell)),
            "aq_result_set_value",
        )
        if raw_cell.is_null:
            return None
        return ctypes.string_at(raw_cell.text_ptr, raw_cell.text_len).decode("utf-8")

    def _result_set_table_qualified_name(self, result_set_id: int, row_index: int) -> QualifiedName:
        raw_name = _CQualifiedName()
        self._raise_on_status(
            self._lib.aq_result_set_table_qualified_name(self._manager, result_set_id, row_index, ctypes.byref(raw_name)),
            "aq_result_set_table_qualified_name",
        )

        parts: list[QualifiedNamePart] = []
        for index in range(raw_name.part_count):
            raw_part = raw_name.parts[index]
            value = ctypes.string_at(raw_part.value_ptr, raw_part.value_len).decode("utf-8") if raw_part.value_ptr and raw_part.value_len > 0 else ""
            parts.append(QualifiedNamePart(role=QualifiedNamePartRole(raw_part.role), value=value))

        formatted = ctypes.string_at(raw_name.formatted_ptr, raw_name.formatted_len).decode("utf-8") if raw_name.formatted_ptr and raw_name.formatted_len > 0 else _format_qualified_name_parts(parts)
        return QualifiedName(parts=tuple(parts), formatted=formatted)

    def _open_cursor(self, connection_id: int, sql: str) -> Cursor:
        cursor_id = self._lib.aq_cursor_open(self._manager, connection_id, sql.encode("utf-8"))
        if cursor_id == 0:
            self._raise_on_zero_result("aq_cursor_open")
        return Cursor(self, int(cursor_id))

    async def _open_cursor_async(self, connection_id: int, sql: str) -> Cursor:
        operation_id = self._lib.aq_cursor_open_async(self._manager, connection_id, sql.encode("utf-8"))
        if operation_id == 0:
            self._raise_on_zero_result("aq_cursor_open_async")

        cursor_id = await self._await_operation_value(operation_id, "aq_cursor_open_async")
        return Cursor(self, cursor_id)

    def _await_operation(self, operation_id: int) -> _COperationResult:
        result = _COperationResult()
        self._raise_on_status(
            self._lib.aq_operation_await(self._manager, operation_id, ctypes.byref(result)),
            "aq_operation_await",
        )
        return result

    async def _await_operation_value(self, operation_id: int, operation: str) -> int:
        result = await asyncio.to_thread(self._await_operation, operation_id)
        self._raise_on_status(result.status, operation)
        if result.value == 0:
            self._raise_on_zero_result(operation)
        return int(result.value)

    def _cursor_next(self, cursor_id: int) -> bool:
        out_value = ctypes.c_uint8()
        self._raise_on_status(
            self._lib.aq_cursor_next(self._manager, cursor_id, ctypes.byref(out_value)),
            "aq_cursor_next",
        )
        return bool(out_value.value)

    def _cursor_close(self, cursor_id: int) -> None:
        self._raise_on_status(
            self._lib.aq_cursor_close(self._manager, cursor_id),
            "aq_cursor_close",
        )

    def _cursor_columns(self, cursor_id: int) -> list[ColumnMetadata]:
        count = ctypes.c_size_t()
        self._raise_on_status(
            self._lib.aq_cursor_column_count(self._manager, cursor_id, ctypes.byref(count)),
            "aq_cursor_column_count",
        )

        columns: list[ColumnMetadata] = []
        for index in range(count.value):
            columns.append(self._read_column_metadata("aq_cursor_column_metadata", cursor_id, index, self._lib.aq_cursor_column_metadata))

        return columns

    def _read_column_metadata(self, label: str, handle_id: int, index: int, func: ctypes._CFuncPtr) -> ColumnMetadata:
        raw_metadata = _CColumnMetadata()
        self._raise_on_status(func(self._manager, handle_id, index, ctypes.byref(raw_metadata)), label)
        return ColumnMetadata(
            name=ctypes.string_at(raw_metadata.name_ptr, raw_metadata.name_len).decode("utf-8"),
            raw_type=(ctypes.string_at(raw_metadata.raw_type_ptr, raw_metadata.raw_type_len).decode("utf-8") if raw_metadata.raw_type_ptr and raw_metadata.raw_type_len > 0 else None),
            column_type=ColumnType(raw_metadata.column_type),
            nullable=bool(raw_metadata.nullable),
        )

    def _raise_on_status(self, status: int, operation: str) -> None:
        if status == 0:
            return
        raw_message = self._last_error_message()
        if raw_message:
            raise RuntimeError(f"{operation} failed: {raw_message}")
        message = _STATUS_MESSAGES.get(status, f"unknown status={status}")
        raise RuntimeError(f"{operation} failed: {message}")

    def _raise_on_zero_result(self, operation: str) -> None:
        raw_message = self._last_error_message()
        if raw_message:
            raise RuntimeError(f"{operation} failed: {raw_message}")
        raise RuntimeError(f"{operation} returned 0")

    def _last_error_message(self) -> str | None:
        raw_error = _CErrorMessage()
        status = self._lib.aq_last_error_message(self._manager, ctypes.byref(raw_error))
        if status != 0 or not raw_error.message_ptr or raw_error.message_len == 0:
            return None
        return ctypes.string_at(raw_error.message_ptr, raw_error.message_len).decode("utf-8")

    def _resolve_library_path(self, library_path: str | None) -> Path:
        if library_path:
            return Path(library_path)

        env_path = os.getenv("AQ_DATABASE_LIBRARY") or os.getenv("DATABASE_ZIG_LIBRARY")
        if env_path:
            return Path(env_path)

        filename = {
            "Darwin": "libaq_database.dylib",
            "Linux": "libaq_database.so",
            "Windows": "aq_database.dll",
        }.get(platform.system())

        if filename is None:
            raise RuntimeError(f"unsupported platform: {platform.system()}")

        return Path(__file__).resolve().parents[3] / "zig-out" / "lib" / filename
