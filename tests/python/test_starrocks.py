from __future__ import annotations

import datetime as dt
import unittest
from decimal import Decimal

from _support import ConnectionManager, ColumnType, QualifiedNamePartRole, assert_boolean_value, assert_column_metadata, assert_namespace_access, assert_non_empty_value, assert_table_qualified_name, assert_type_coverage, execute_non_query, find_result_set_row_index, is_runtime_unavailable_error, load_test_target, read_result_set_values, should_run_section, unique_identifier


STARROCKS_ADDITIONAL_TYPES_SQL = """\
select
    cast(1 as tinyint) as tiny_value,
    cast(2 as smallint) as small_value,
    cast(3 as int) as int_value,
    cast(4 as bigint) as big_value,
    cast(5.5 as float) as float_value,
    cast(6.5 as double) as double_value,
    cast('[1,2,3]' as array<int>) as array_value,
    map('a',1,'b',2) as map_value,
    row(1, 'alpha') as struct_value
"""

STARROCKS_SKETCH_TYPES_SQL = """\
select
    to_bitmap(42) as bitmap_value,
    hll_hash('alpha') as hll_value,
    percentile_hash(42) as percentile_value
"""


def build_starrocks_type_coverage_case(table_name: str) -> dict[str, object]:
    return {
        "metadata_database": None,
        "create_table_sql": f"""\
create table {table_name} (
    id bigint not null,
    bool_value boolean not null,
    int_value bigint not null,
    float_value double not null,
    text_value string not null,
    fixed_text_value char(5) not null,
    decimal_value decimal(10, 2) not null,
    date_value date not null,
    timestamp_value datetime not null,
    largeint_value largeint not null,
    json_value json not null
) duplicate key(id) distributed by hash(id) buckets 1
properties ("replication_num" = "1")""",
        "insert_sql": f"""\
insert into {table_name} (
    id, bool_value, int_value, float_value, text_value, fixed_text_value, decimal_value, date_value,
    timestamp_value, largeint_value, json_value
) values (
    1, true, 42, 3.5, 'alpha', 'omega', 123.45, '2024-01-02', '2024-01-02 03:04:05',
    123456789012345678901234567890, parse_json('{"enabled": true, "count": 1}')
)""",
        "select_sql": f"""\
select id, bool_value, int_value, float_value, text_value, fixed_text_value,
    decimal_value, date_value, timestamp_value, largeint_value, json_value
from {table_name}
order by id""",
        "expected_columns": [
            {"name": "id", "column_type": ColumnType.INT64},
            {"name": "bool_value", "column_type": [ColumnType.BOOLEAN, ColumnType.INT8]},
            {"name": "int_value", "column_type": ColumnType.INT64},
            {"name": "float_value", "column_type": ColumnType.FLOAT64},
            {"name": "text_value", "column_type": ColumnType.TEXT},
            {"name": "fixed_text_value", "column_type": ColumnType.TEXT},
            {"name": "decimal_value", "column_type": ColumnType.DECIMAL},
            {"name": "date_value", "column_type": ColumnType.DATE},
            {"name": "timestamp_value", "column_type": ColumnType.TIMESTAMP},
            {"name": "largeint_value", "column_type": ColumnType.TEXT},
            {"name": "json_value", "column_type": [ColumnType.JSON, ColumnType.TEXT]},
        ],
    }


def assert_starrocks_type_coverage_values(result_set: object) -> None:
    columns = result_set.columns
    assert result_set.value(0, 0) == 1

    bool_value = result_set.value(0, 1)
    if columns[1].column_type == ColumnType.BOOLEAN:
        assert_boolean_value(bool_value)
    else:
        assert bool_value == 1

    assert result_set.value(0, 2) == 42
    assert result_set.value(0, 3) == 3.5
    assert result_set.value(0, 4) == "alpha"
    assert result_set.value(0, 5) == "omega"
    assert result_set.value(0, 6) == Decimal("123.45")
    assert result_set.value(0, 7) == dt.date(2024, 1, 2)
    timestamp_value = result_set.value(0, 8)
    assert timestamp_value == dt.datetime(2024, 1, 2, 3, 4, 5)
    assert result_set.value(0, 9) == "123456789012345678901234567890"

    json_value = result_set.value(0, 10)
    if columns[10].column_type == ColumnType.JSON:
        assert json_value == {"enabled": True, "count": 1}
    else:
        assert isinstance(json_value, str)
        assert '"enabled"' in json_value


async def assert_starrocks_additional_type_coverage(connection: object) -> None:
    result_set = await connection.execute_async(STARROCKS_ADDITIONAL_TYPES_SQL)
    try:
        assert_column_metadata(result_set.columns, [
            {"name": "tiny_value", "column_type": ColumnType.INT8},
            {"name": "small_value", "column_type": ColumnType.INT16},
            {"name": "int_value", "column_type": ColumnType.INT32},
            {"name": "big_value", "column_type": ColumnType.INT64},
            {"name": "float_value", "column_type": ColumnType.FLOAT32},
            {"name": "double_value", "column_type": ColumnType.FLOAT64},
            {"name": "array_value", "column_type": ColumnType.TEXT},
            {"name": "map_value", "column_type": ColumnType.TEXT},
            {"name": "struct_value", "column_type": ColumnType.TEXT},
        ])
        assert all(column.raw_type is None for column in result_set.columns)
        assert result_set.value(0, 0) == 1
        assert result_set.value(0, 1) == 2
        assert result_set.value(0, 2) == 3
        assert result_set.value(0, 3) == 4
        assert result_set.value(0, 4) == 5.5
        assert result_set.value(0, 5) == 6.5
        assert result_set.value(0, 6) == "[1,2,3]"
        assert result_set.value(0, 7) == '{"a":1,"b":2}'
        assert result_set.value(0, 8) == '{"col1":1,"col2":"alpha"}'
    finally:
        await result_set.close_async()

    result_set = await connection.execute_async(STARROCKS_SKETCH_TYPES_SQL)
    try:
        assert_column_metadata(result_set.columns, [
            {"name": "bitmap_value", "column_type": ColumnType.TEXT},
            {"name": "hll_value", "column_type": ColumnType.TEXT},
            {"name": "percentile_value", "column_type": ColumnType.BINARY},
        ])
        assert result_set.value(0, 0) is None
        assert result_set.value(0, 1) is None
        assert result_set.value(0, 2) is None
    finally:
        await result_set.close_async()


class StarRocksBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_starrocks(self) -> None:
        section = "starrocks"
        if not should_run_section(section):
            self.skipTest(f"DATABASE_ZIG_TEST_SECTION is filtering out {section}")

        target = load_test_target(section)
        database_name = unique_identifier("aq_sr")
        table_name = unique_identifier("records")
        missing_database = unique_identifier("missing_db")

        async with ConnectionManager() as manager:
            try:
                admin_connection = await manager.connect_async(target.driver, target.dsn())
            except RuntimeError as error:
                if is_runtime_unavailable_error(error):
                    self.skipTest(str(error))
                raise

            with self.assertRaises(RuntimeError):
                await manager.connect_async(target.driver, target.dsn(missing_database))
            try:
                await execute_non_query(admin_connection, f"create database if not exists {database_name}")

                database_connection = await manager.connect_async(target.driver, target.dsn(database_name))
                try:
                    self.assertTrue(await database_connection.test_async())

                    await assert_type_coverage(database_connection, build_starrocks_type_coverage_case(table_name), assert_starrocks_type_coverage_values)
                    await assert_starrocks_additional_type_coverage(database_connection)

                    missing_table = unique_identifier("missing")
                    with self.assertRaisesRegex(RuntimeError, missing_table):
                        await database_connection.execute_async(f"select * from {missing_table}")

                    missing_column = unique_identifier("missing_column")
                    with self.assertRaisesRegex(RuntimeError, missing_column):
                        await database_connection.execute_async(f"select {missing_column} from {table_name}")

                    databases_result = await database_connection.get_databases_async()
                    try:
                        self.assertIn(database_name, read_result_set_values(databases_result, 0))
                    finally:
                        await databases_result.close_async()

                    with self.assertRaisesRegex(RuntimeError, "get catalogs is not supported"):
                        await database_connection.get_catalogs_async()

                    tables_result = await database_connection.get_tables_async(database=database_name)
                    try:
                        self.assertIn(table_name, read_result_set_values(tables_result, 2))
                        catalog_names = read_result_set_values(tables_result, 0)
                        self.assertTrue(any(name not in (None, "") for name in catalog_names))
                        assert_table_qualified_name(tables_result, find_result_set_row_index(tables_result, 2, table_name))
                    finally:
                        await tables_result.close_async()

                    namespace_access = await database_connection.inspect_namespace_access_async(database=database_name)
                    assert_namespace_access(
                        namespace_access,
                        can_get_schema=False,
                        has_catalog_access=True,
                        has_namespace_access=True,
                        namespace_role=QualifiedNamePartRole.DATABASE,
                        expected_parts=[(QualifiedNamePartRole.DATABASE, database_name)],
                    )

                    missing_access = await database_connection.inspect_namespace_access_async(database=missing_database)
                    assert_namespace_access(
                        missing_access,
                        can_get_schema=False,
                        has_catalog_access=True,
                        has_namespace_access=False,
                        namespace_role=QualifiedNamePartRole.DATABASE,
                        expected_parts=[(QualifiedNamePartRole.DATABASE, missing_database)],
                    )
                finally:
                    await database_connection.close_async()
            finally:
                try:
                    await execute_non_query(admin_connection, f"drop database if exists {database_name}")
                finally:
                    await admin_connection.close_async()


if __name__ == "__main__":
    unittest.main()