from __future__ import annotations

import datetime as dt
import unittest

from _support import ConnectionManager, ColumnType, assert_boolean_value, assert_column_metadata, assert_type_coverage, duckdb_test_dsn, read_result_set_values, remove_file_if_exists, repo_tmp_dir, should_run_section, unique_identifier, vendored_adbc_driver_path


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