from __future__ import annotations

import asyncio
import ctypes
import os
import platform
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path


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


class _CColumnMetadata(ctypes.Structure):
    _fields_ = [
        ("name_ptr", ctypes.c_void_p),
        ("name_len", ctypes.c_size_t),
        ("column_type", ctypes.c_int32),
        ("nullable", ctypes.c_uint8),
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
    column_type: ColumnType
    nullable: bool


class ResultSet:
    def __init__(self, manager: ConnectionManager, result_set_id: int) -> None:
        self._manager = manager
        self.id = result_set_id

    @property
    def row_count(self) -> int:
        return self._manager._result_set_row_count(self.id)

    @property
    def affected_rows(self) -> int:
        return self._manager._result_set_affected_rows(self.id)

    @property
    def columns(self) -> list[ColumnMetadata]:
        return self._manager._result_set_columns(self.id)

    def value(self, row_index: int, column_index: int) -> str | None:
        return self._manager._result_set_value(self.id, row_index, column_index)

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

    def get_databases(self) -> ResultSet:
        return self._manager._get_databases(self.id)

    async def get_databases_async(self) -> ResultSet:
        return await self._manager._get_databases_async(self.id)

    def get_tables(self, catalog: str | None = None, database: str | None = None) -> ResultSet:
        return self._manager._get_tables(self.id, catalog, database)

    async def get_tables_async(self, catalog: str | None = None, database: str | None = None) -> ResultSet:
        return await self._manager._get_tables_async(self.id, catalog, database)

    def close(self) -> None:
        self._manager.close_connection(self.id)

    async def close_async(self) -> None:
        await self._manager.close_connection_async(self.id)


class ConnectionManager:
    def __init__(self, library_path: str | None = None) -> None:
        resolved_path = self._resolve_library_path(library_path)
        self._lib = ctypes.CDLL(str(resolved_path))
        self._configure_abi()
        self._manager = self._lib.dbz_manager_create()

        if not self._manager:
            raise RuntimeError("failed to create database.zig connection manager")

    def connect(self, driver: str, dsn: str) -> Connection:
        driver_kind = _DRIVER_MAP.get(driver.lower())
        if driver_kind is None:
            raise ValueError(f"unsupported driver: {driver}")

        handle = self._lib.dbz_connection_open(self._manager, driver_kind, dsn.encode("utf-8"))
        if handle == 0:
            self._raise_on_zero_result("dbz_connection_open")

        return Connection(self, int(handle), driver, dsn)

    async def connect_async(self, driver: str, dsn: str) -> Connection:
        driver_kind = _DRIVER_MAP.get(driver.lower())
        if driver_kind is None:
            raise ValueError(f"unsupported driver: {driver}")

        operation_id = self._lib.dbz_connection_open_async(self._manager, driver_kind, dsn.encode("utf-8"))
        if operation_id == 0:
            self._raise_on_zero_result("dbz_connection_open_async")

        handle = await self._await_operation_value(operation_id, "dbz_connection_open_async")
        return Connection(self, handle, driver, dsn)

    def open(self, driver: str, dsn: str) -> int:
        return self.connect(driver, dsn).id

    async def open_async(self, driver: str, dsn: str) -> int:
        return (await self.connect_async(driver, dsn)).id

    def close_connection(self, connection_id: int) -> None:
        self._raise_on_status(
            self._lib.dbz_connection_close(self._manager, connection_id),
            "dbz_connection_close",
        )

    async def close_connection_async(self, connection_id: int) -> None:
        await asyncio.to_thread(self.close_connection, connection_id)

    def close(self) -> None:
        manager = getattr(self, "_manager", None)
        if manager:
            self._lib.dbz_manager_destroy(manager)
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
        self._lib.dbz_manager_create.restype = ctypes.c_void_p
        self._lib.dbz_manager_destroy.argtypes = [ctypes.c_void_p]
        self._lib.dbz_connection_open.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.dbz_connection_open.restype = ctypes.c_uint64
        self._lib.dbz_connection_open_async.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.dbz_connection_open_async.restype = ctypes.c_uint64
        self._lib.dbz_connection_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.dbz_connection_close.restype = ctypes.c_int32
        self._lib.dbz_connection_test.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint8)]
        self._lib.dbz_connection_test.restype = ctypes.c_int32
        self._lib.dbz_connection_execute.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.dbz_connection_execute.restype = ctypes.c_uint64
        self._lib.dbz_connection_execute_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.dbz_connection_execute_async.restype = ctypes.c_uint64
        self._lib.dbz_connection_get_tables.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_char_p]
        self._lib.dbz_connection_get_tables.restype = ctypes.c_uint64
        self._lib.dbz_connection_get_databases.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.dbz_connection_get_databases.restype = ctypes.c_uint64
        self._lib.dbz_result_set_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.dbz_result_set_close.restype = ctypes.c_int32
        self._lib.dbz_result_set_row_count.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
        self._lib.dbz_result_set_row_count.restype = ctypes.c_int32
        self._lib.dbz_result_set_affected_rows.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
        self._lib.dbz_result_set_affected_rows.restype = ctypes.c_int32
        self._lib.dbz_result_set_column_count.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_size_t)]
        self._lib.dbz_result_set_column_count.restype = ctypes.c_int32
        self._lib.dbz_result_set_column_metadata.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.POINTER(_CColumnMetadata)]
        self._lib.dbz_result_set_column_metadata.restype = ctypes.c_int32
        self._lib.dbz_result_set_value.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(_CResultCell)]
        self._lib.dbz_result_set_value.restype = ctypes.c_int32
        self._lib.dbz_cursor_open.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.dbz_cursor_open.restype = ctypes.c_uint64
        self._lib.dbz_cursor_open_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
        self._lib.dbz_cursor_open_async.restype = ctypes.c_uint64
        self._lib.dbz_cursor_next.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint8)]
        self._lib.dbz_cursor_next.restype = ctypes.c_int32
        self._lib.dbz_cursor_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.dbz_cursor_close.restype = ctypes.c_int32
        self._lib.dbz_cursor_column_count.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_size_t)]
        self._lib.dbz_cursor_column_count.restype = ctypes.c_int32
        self._lib.dbz_cursor_column_metadata.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_size_t, ctypes.POINTER(_CColumnMetadata)]
        self._lib.dbz_cursor_column_metadata.restype = ctypes.c_int32
        self._lib.dbz_manager_open.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.dbz_manager_open.restype = ctypes.c_uint64
        self._lib.dbz_manager_open_async.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_char_p]
        self._lib.dbz_manager_open_async.restype = ctypes.c_uint64
        self._lib.dbz_manager_close.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self._lib.dbz_manager_close.restype = ctypes.c_int32
        self._lib.dbz_operation_await.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(_COperationResult)]
        self._lib.dbz_operation_await.restype = ctypes.c_int32
        self._lib.dbz_last_error_message.argtypes = [ctypes.c_void_p, ctypes.POINTER(_CErrorMessage)]
        self._lib.dbz_last_error_message.restype = ctypes.c_int32

    def _execute(self, connection_id: int, sql: str) -> ResultSet:
        result_set_id = self._lib.dbz_connection_execute(self._manager, connection_id, sql.encode("utf-8"))
        if result_set_id == 0:
            self._raise_on_zero_result("dbz_connection_execute")
        return ResultSet(self, int(result_set_id))

    async def _execute_async(self, connection_id: int, sql: str) -> ResultSet:
        operation_id = self._lib.dbz_connection_execute_async(self._manager, connection_id, sql.encode("utf-8"))
        if operation_id == 0:
            self._raise_on_zero_result("dbz_connection_execute_async")

        result_set_id = await self._await_operation_value(operation_id, "dbz_connection_execute_async")
        return ResultSet(self, result_set_id)

    def _connection_test(self, connection_id: int) -> bool:
        out_value = ctypes.c_uint8()
        self._raise_on_status(
            self._lib.dbz_connection_test(self._manager, connection_id, ctypes.byref(out_value)),
            "dbz_connection_test",
        )
        return bool(out_value.value)

    async def _connection_test_async(self, connection_id: int) -> bool:
        return await asyncio.to_thread(self._connection_test, connection_id)

    def _get_databases(self, connection_id: int) -> ResultSet:
        result_set_id = self._lib.dbz_connection_get_databases(self._manager, connection_id)
        if result_set_id == 0:
            self._raise_on_zero_result("dbz_connection_get_databases")
        return ResultSet(self, int(result_set_id))

    async def _get_databases_async(self, connection_id: int) -> ResultSet:
        return await asyncio.to_thread(self._get_databases, connection_id)

    def _get_tables(self, connection_id: int, catalog: str | None, database: str | None) -> ResultSet:
        result_set_id = self._lib.dbz_connection_get_tables(
            self._manager,
            connection_id,
            catalog.encode("utf-8") if catalog is not None else None,
            database.encode("utf-8") if database is not None else None,
        )
        if result_set_id == 0:
            self._raise_on_zero_result("dbz_connection_get_tables")
        return ResultSet(self, int(result_set_id))

    async def _get_tables_async(self, connection_id: int, catalog: str | None, database: str | None) -> ResultSet:
        return await asyncio.to_thread(self._get_tables, connection_id, catalog, database)

    def _result_set_close(self, result_set_id: int) -> None:
        self._raise_on_status(
            self._lib.dbz_result_set_close(self._manager, result_set_id),
            "dbz_result_set_close",
        )

    def _result_set_row_count(self, result_set_id: int) -> int:
        out_value = ctypes.c_uint64()
        self._raise_on_status(
            self._lib.dbz_result_set_row_count(self._manager, result_set_id, ctypes.byref(out_value)),
            "dbz_result_set_row_count",
        )
        return int(out_value.value)

    def _result_set_affected_rows(self, result_set_id: int) -> int:
        out_value = ctypes.c_uint64()
        self._raise_on_status(
            self._lib.dbz_result_set_affected_rows(self._manager, result_set_id, ctypes.byref(out_value)),
            "dbz_result_set_affected_rows",
        )
        return int(out_value.value)

    def _result_set_columns(self, result_set_id: int) -> list[ColumnMetadata]:
        count = ctypes.c_size_t()
        self._raise_on_status(
            self._lib.dbz_result_set_column_count(self._manager, result_set_id, ctypes.byref(count)),
            "dbz_result_set_column_count",
        )

        columns: list[ColumnMetadata] = []
        for index in range(count.value):
            columns.append(self._read_column_metadata("dbz_result_set_column_metadata", result_set_id, index, self._lib.dbz_result_set_column_metadata))

        return columns

    def _result_set_value(self, result_set_id: int, row_index: int, column_index: int) -> str | None:
        raw_cell = _CResultCell()
        self._raise_on_status(
            self._lib.dbz_result_set_value(self._manager, result_set_id, row_index, column_index, ctypes.byref(raw_cell)),
            "dbz_result_set_value",
        )
        if raw_cell.is_null:
            return None
        return ctypes.string_at(raw_cell.text_ptr, raw_cell.text_len).decode("utf-8")

    def _open_cursor(self, connection_id: int, sql: str) -> Cursor:
        cursor_id = self._lib.dbz_cursor_open(self._manager, connection_id, sql.encode("utf-8"))
        if cursor_id == 0:
            self._raise_on_zero_result("dbz_cursor_open")
        return Cursor(self, int(cursor_id))

    async def _open_cursor_async(self, connection_id: int, sql: str) -> Cursor:
        operation_id = self._lib.dbz_cursor_open_async(self._manager, connection_id, sql.encode("utf-8"))
        if operation_id == 0:
            self._raise_on_zero_result("dbz_cursor_open_async")

        cursor_id = await self._await_operation_value(operation_id, "dbz_cursor_open_async")
        return Cursor(self, cursor_id)

    def _await_operation(self, operation_id: int) -> _COperationResult:
        result = _COperationResult()
        self._raise_on_status(
            self._lib.dbz_operation_await(self._manager, operation_id, ctypes.byref(result)),
            "dbz_operation_await",
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
            self._lib.dbz_cursor_next(self._manager, cursor_id, ctypes.byref(out_value)),
            "dbz_cursor_next",
        )
        return bool(out_value.value)

    def _cursor_close(self, cursor_id: int) -> None:
        self._raise_on_status(
            self._lib.dbz_cursor_close(self._manager, cursor_id),
            "dbz_cursor_close",
        )

    def _cursor_columns(self, cursor_id: int) -> list[ColumnMetadata]:
        count = ctypes.c_size_t()
        self._raise_on_status(
            self._lib.dbz_cursor_column_count(self._manager, cursor_id, ctypes.byref(count)),
            "dbz_cursor_column_count",
        )

        columns: list[ColumnMetadata] = []
        for index in range(count.value):
            columns.append(self._read_column_metadata("dbz_cursor_column_metadata", cursor_id, index, self._lib.dbz_cursor_column_metadata))

        return columns

    def _read_column_metadata(self, label: str, handle_id: int, index: int, func: ctypes._CFuncPtr) -> ColumnMetadata:
        raw_metadata = _CColumnMetadata()
        self._raise_on_status(func(self._manager, handle_id, index, ctypes.byref(raw_metadata)), label)
        return ColumnMetadata(
            name=ctypes.string_at(raw_metadata.name_ptr, raw_metadata.name_len).decode("utf-8"),
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
        status = self._lib.dbz_last_error_message(self._manager, ctypes.byref(raw_error))
        if status != 0 or not raw_error.message_ptr or raw_error.message_len == 0:
            return None
        return ctypes.string_at(raw_error.message_ptr, raw_error.message_len).decode("utf-8")

    def _resolve_library_path(self, library_path: str | None) -> Path:
        if library_path:
            return Path(library_path)

        env_path = os.getenv("DATABASE_ZIG_LIBRARY")
        if env_path:
            return Path(env_path)

        filename = {
            "Darwin": "libdatabase_zig.dylib",
            "Linux": "libdatabase_zig.so",
            "Windows": "database_zig.dll",
        }.get(platform.system())

        if filename is None:
            raise RuntimeError(f"unsupported platform: {platform.system()}")

        return Path(__file__).resolve().parents[3] / "zig-out" / "lib" / filename
