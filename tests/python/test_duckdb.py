from __future__ import annotations

import datetime as dt
from decimal import Decimal
import unittest

from _support import ConnectionManager, ColumnType, assert_boolean_value, assert_column_metadata, assert_table_qualified_name, assert_type_coverage, duckdb_test_dsn, find_result_set_row_index, read_result_set_values, remove_file_if_exists, repo_tmp_dir, should_run_section, unique_identifier, vendored_adbc_driver_path


def build_duckdb_type_coverage_case(table_name: str) -> dict[str, object]:
    return {
        "metadata_database": "main",
        "create_table_sql": (
            f"create table {table_name} ("
            "id bigint primary key, "
            "bool_value boolean not null, "
            "int_value bigint not null, "
            "float_value double not null, "
            "text_value varchar not null, "
            "date_value date not null, "
            "time_value time not null, "
            "timestamp_value timestamp not null"
            ")"
        ),
        "insert_sql": (
            f"insert into {table_name} ("
            "id, bool_value, int_value, float_value, text_value, date_value, time_value, timestamp_value"
            ") values ("
            "1, true, 42, 3.5, 'alpha', date '2024-01-02', time '03:04:05', timestamp '2024-01-02 03:04:05'"
            ")"
        ),
        "select_sql": (
            f"select id, bool_value, int_value, float_value, text_value, date_value, time_value, timestamp_value "
            f"from {table_name} order by id"
        ),
        "expected_columns": [
            {"name": "id", "column_type": ColumnType.INT64},
            {"name": "bool_value", "column_type": ColumnType.BOOLEAN},
            {"name": "int_value", "column_type": ColumnType.INT64},
            {"name": "float_value", "column_type": ColumnType.FLOAT64},
            {"name": "text_value", "column_type": ColumnType.TEXT},
            {"name": "date_value", "column_type": ColumnType.DATE},
            {"name": "time_value", "column_type": ColumnType.TIME},
            {"name": "timestamp_value", "column_type": ColumnType.TIMESTAMP},
        ],
    }


def assert_duckdb_type_coverage_values(result_set: object) -> None:
    assert result_set.value(0, 0) == 1
    assert_boolean_value(result_set.value(0, 1))
    assert result_set.value(0, 2) == 42
    assert result_set.value(0, 3) == 3.5
    assert result_set.value(0, 4) == "alpha"
    assert result_set.value(0, 5) == dt.date(2024, 1, 2)
    assert result_set.value(0, 6) == dt.time(3, 4, 5)
    assert result_set.value(0, 7) == dt.datetime(2024, 1, 2, 3, 4, 5)


async def assert_duckdb_additional_type_coverage(connection: object) -> None:
    result_set = await connection.execute_async(
        "select "
        "cast(123.45 as decimal(10, 2)) as decimal_value, "
        "'0102ff'::blob as binary_value, "
        "'550e8400-e29b-41d4-a716-446655440000'::uuid as uuid_value, "
        "json('{\"enabled\":true,\"count\":1}') as json_value, "
        "interval '1 day 2 seconds' as interval_value, "
        "[1,2,3] as array_value, "
        "{'name': 'alpha', 'enabled': true} as struct_value, "
        "map(['a','b'], [1,2]) as map_value, "
        "'alpha'::enum ('alpha', 'beta') as enum_value, "
        "170141183460469231731687303715884105727::hugeint as hugeint_value, "
        "18446744073709551615::ubigint as ubigint_value, "
        "timestamptz '2024-01-02 03:04:05+02' as timestamptz_value"
    )
    try:
        assert_column_metadata(result_set.columns, [
            {"name": "decimal_value", "column_type": ColumnType.DECIMAL},
            {"name": "binary_value", "column_type": ColumnType.BINARY},
            {"name": "uuid_value", "column_type": ColumnType.TEXT},
            {"name": "json_value", "column_type": ColumnType.TEXT},
            {"name": "interval_value", "column_type": ColumnType.INTERVAL},
            {"name": "array_value", "column_type": ColumnType.ARRAY},
            {"name": "struct_value", "column_type": ColumnType.STRUCT},
            {"name": "map_value", "column_type": ColumnType.MAP},
            {"name": "enum_value", "column_type": ColumnType.TEXT},
            {"name": "hugeint_value", "column_type": ColumnType.DECIMAL},
            {"name": "ubigint_value", "column_type": ColumnType.UINT64},
            {"name": "timestamptz_value", "column_type": ColumnType.TIMESTAMP},
        ])
        assert all(column.raw_type is None for column in result_set.columns)
        assert result_set.value(0, 0) == Decimal("123.45")
        assert result_set.value(0, 1) == b"0102ff"
        assert result_set.value(0, 2) == "550e8400-e29b-41d4-a716-446655440000"
        assert result_set.value(0, 3) == '{"enabled":true,"count":1}'
        assert result_set.value(0, 4) == "P0M1DT00:00:02.000000000"
        assert result_set.value(0, 5) == [1, 2, 3]
        assert result_set.value(0, 6) == {"name": "alpha", "enabled": True}
        assert result_set.value(0, 7) == [{"key": "a", "value": 1}, {"key": "b", "value": 2}]
        assert result_set.value(0, 8) == "alpha"
        assert result_set.value(0, 9) == Decimal("170141183460469231731687303715884105727")
        assert result_set.value(0, 10) == 18446744073709551615
        assert result_set.value(0, 11) == dt.datetime(2024, 1, 2, 1, 4, 5)
    finally:
        await result_set.close_async()


class DuckDBBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_duckdb(self) -> None:
        section = "duckdb"
        if not should_run_section(section):
            self.skipTest(f"DATABASE_ZIG_TEST_SECTION is filtering out {section}")

        driver_path = vendored_adbc_driver_path("duckdb")
        if not driver_path.exists():
            self.skipTest(f"duckdb driver not found: {driver_path}")

        database_path = repo_tmp_dir("duckdb") / f"{unique_identifier('aq_duckdb')}.duckdb"
        table_name = unique_identifier("records")
        dsn = duckdb_test_dsn(database_path)

        remove_file_if_exists(database_path)
        try:
            async with ConnectionManager() as manager:
                try:
                    connection = await manager.connect_async("adbc", dsn)
                except RuntimeError as error:
                    message = str(error)
                    if "Could not load" in message or "Library not loaded" in message:
                        self.skipTest(message)
                    raise
                try:
                    self.assertTrue(await connection.test_async())

                    type_coverage = await assert_type_coverage(connection, build_duckdb_type_coverage_case(table_name), assert_duckdb_type_coverage_values)
                    await assert_duckdb_additional_type_coverage(connection)

                    missing_table = unique_identifier("missing")
                    with self.assertRaisesRegex(RuntimeError, missing_table):
                        await connection.execute_async(f"select * from {missing_table}")

                    missing_column = unique_identifier("missing_column")
                    with self.assertRaisesRegex(RuntimeError, missing_column):
                        await connection.execute_async(f"select {missing_column} from {table_name}")

                    tables_result = await connection.get_tables_async(database="main")
                    try:
                        self.assertIn(table_name, read_result_set_values(tables_result, 2))
                        self.assertIn(type_coverage["metadata_database"], read_result_set_values(tables_result, 1))
                        assert_table_qualified_name(tables_result, find_result_set_row_index(tables_result, 2, table_name))
                    finally:
                        await tables_result.close_async()

                    databases_result = await connection.get_databases_async()
                    try:
                        self.assertIn("main", read_result_set_values(databases_result, 0))
                    finally:
                        await databases_result.close_async()
                finally:
                    await connection.close_async()

                self.assertTrue(database_path.exists())

                try:
                    reopened = await manager.connect_async("adbc", dsn)
                except RuntimeError as error:
                    message = str(error)
                    if "Could not load" in message or "Library not loaded" in message:
                        self.skipTest(message)
                    raise
                try:
                    persisted = await reopened.execute_async(f"select count(*) as row_count from {table_name}")
                    try:
                        assert_column_metadata(persisted.columns, [{"name": "row_count", "column_type": ColumnType.INT64}])
                        self.assertEqual(persisted.value(0, 0), 1)
                    finally:
                        await persisted.close_async()
                finally:
                    await reopened.close_async()
        finally:
            remove_file_if_exists(database_path)


if __name__ == "__main__":
    unittest.main()