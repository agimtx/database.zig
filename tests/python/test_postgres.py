from __future__ import annotations

import datetime as dt
import unittest
import uuid
from decimal import Decimal

from _support import ConnectionManager, ColumnType, assert_boolean_value, assert_column_metadata, assert_hex_value, assert_non_empty_value, assert_type_coverage, execute_non_query, load_test_target, read_result_set_values, should_run_section, unique_identifier


POSTGRES_ADDITIONAL_TYPES_SQL = (
    "select "
    "cast(12.34 as money) as money_value, "
    "cast(B'1010' as bit(4)) as bit_value, "
    "cast(B'101011' as varbit) as varbit_value, "
    "'10.0.0.0/24'::cidr as cidr_value, "
    "'08:00:2b:01:02:03'::macaddr as macaddr_value, "
    "'08:00:2b:01:02:03:04:05'::macaddr8 as macaddr8_value, "
    "to_tsvector('english', 'hello world') as tsv_value, "
    "to_tsquery('english', 'hello & world') as tsq_value, "
    "point(1,2) as point_value, "
    "box(point(0,0), point(1,1)) as box_value, "
    "'int4'::regtype as regtype_value, "
    "time with time zone '03:04:05+02' as timetz_value, "
    "timestamptz '2024-01-02 03:04:05+02' as timestamptz_value"
)

POSTGRES_RANGE_AND_SYSTEM_TYPES_SQL = (
    "select "
    "int4range(1,5) as range_value, "
    "int4multirange(int4range(1,5), int4range(7,9)) as multirange_value, "
    "42::oid as oid_value, "
    "'pg_type'::regclass as regclass_value, "
    "'(1,2)'::tid as tid_value, "
    "'0/16B6C50'::pg_lsn as lsn_value"
)


def build_postgres_type_coverage_case(table_name: str) -> dict[str, object]:
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
            "date_value date not null, "
            "time_value time not null, "
            "interval_value interval not null, "
            "uuid_value uuid not null, "
            "xml_value xml not null, "
            "array_value integer[] not null, "
            "inet_value inet not null, "
            "timestamp_value timestamp not null, "
            "json_value jsonb not null"
            ")"
        ),
        "insert_sql": (
            f"insert into {table_name} ("
            "id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value"
            ") values ("
            "1, true, 42, 3.5, 'alpha', decode('0102ff', 'hex'), 123.45, date '2024-01-02', time '03:04:05', interval '1 day 2 seconds', '550e8400-e29b-41d4-a716-446655440000'::uuid, xmlparse(document '<a>1</a>'), array[1,2,3], inet '127.0.0.1', timestamp '2024-01-02 03:04:05', '{\"enabled\":true,\"count\":1}'::jsonb"
            ")"
        ),
        "select_sql": (
            f"select id, bool_value, int_value, float_value, text_value, binary_value, "
            f"decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value from {table_name} order by id"
        ),
        "expected_columns": [
            {"name": "id", "column_type": ColumnType.INT64},
            {"name": "bool_value", "column_type": ColumnType.BOOLEAN},
            {"name": "int_value", "column_type": ColumnType.INT64},
            {"name": "float_value", "column_type": ColumnType.FLOAT64},
            {"name": "text_value", "column_type": ColumnType.TEXT},
            {"name": "binary_value", "column_type": ColumnType.BINARY},
            {"name": "decimal_value", "column_type": [ColumnType.DECIMAL, ColumnType.TEXT]},
            {"name": "date_value", "column_type": ColumnType.DATE},
            {"name": "time_value", "column_type": ColumnType.TIME},
            {"name": "interval_value", "column_type": ColumnType.INTERVAL},
            {"name": "uuid_value", "column_type": ColumnType.UUID, "raw_type": "uuid"},
            {"name": "xml_value", "column_type": ColumnType.UNKNOWN, "raw_type": "xml"},
            {"name": "array_value", "column_type": ColumnType.ARRAY},
            {"name": "inet_value", "column_type": ColumnType.UNKNOWN, "raw_type": "inet"},
            {"name": "timestamp_value", "column_type": ColumnType.TIMESTAMP},
            {"name": "json_value", "column_type": [ColumnType.JSON, ColumnType.TEXT]},
        ],
    }


def assert_postgres_type_coverage_values(result_set: object) -> None:
    columns = result_set.columns
    assert result_set.value(0, 0) == 1
    assert_boolean_value(result_set.value(0, 1))
    assert result_set.value(0, 2) == 42
    assert result_set.value(0, 3) == 3.5
    assert result_set.value(0, 4) == "alpha"
    assert result_set.value(0, 5) == b"\x01\x02\xff"

    decimal_value = result_set.value(0, 6)
    if columns[6].column_type == ColumnType.DECIMAL:
        assert decimal_value == Decimal("123.45")
    else:
        assert decimal_value == "123.45"

    assert result_set.value(0, 7) == dt.date(2024, 1, 2)
    time_value = result_set.value(0, 8)
    assert isinstance(time_value, dt.time)
    assert time_value.isoformat().startswith("03:04:05")
    interval_value = result_set.value(0, 9)
    assert isinstance(interval_value, str)
    assert interval_value.startswith("P0M1DT00:00:02")
    assert result_set.value(0, 10) == uuid.UUID("550e8400-e29b-41d4-a716-446655440000")
    assert result_set.value(0, 11) == "<a>1</a>"
    assert result_set.value(0, 12) == [1, 2, 3]
    assert result_set.value(0, 13) == "127.0.0.1"
    timestamp_value = result_set.value(0, 14)
    assert timestamp_value == dt.datetime(2024, 1, 2, 3, 4, 5)

    json_value = result_set.value(0, 15)
    if columns[15].column_type == ColumnType.JSON:
        assert json_value == {"enabled": True, "count": 1}
    else:
        assert isinstance(json_value, str)
        assert '"enabled"' in json_value


async def assert_postgres_additional_type_coverage(connection: object) -> None:
    enum_name = unique_identifier("status_enum")
    create_type = await connection.execute_async(f"create type {enum_name} as enum ('new', 'done')")
    await create_type.close_async()
    try:
        result_set = await connection.execute_async(f"select 'new'::{enum_name} as enum_value")
        try:
            assert len(result_set.columns) == 1
            assert result_set.columns[0].name == "enum_value"
            assert result_set.columns[0].column_type == ColumnType.BINARY
            assert result_set.value(0, 0) == b"new"
        finally:
            await result_set.close_async()
    finally:
        drop_type = await connection.execute_async(f"drop type if exists {enum_name}")
        await drop_type.close_async()

    result_set = await connection.execute_async(POSTGRES_ADDITIONAL_TYPES_SQL)
    try:
        assert_column_metadata(result_set.columns, [
            {"name": "money_value", "column_type": ColumnType.INT64},
            {"name": "bit_value", "column_type": ColumnType.BINARY},
            {"name": "varbit_value", "column_type": ColumnType.BINARY},
            {"name": "cidr_value", "column_type": ColumnType.UNKNOWN, "raw_type": "cidr"},
            {"name": "macaddr_value", "column_type": ColumnType.UNKNOWN, "raw_type": "macaddr"},
            {"name": "macaddr8_value", "column_type": ColumnType.UNKNOWN, "raw_type": "macaddr8"},
            {"name": "tsv_value", "column_type": ColumnType.UNKNOWN, "raw_type": "tsvector"},
            {"name": "tsq_value", "column_type": ColumnType.UNKNOWN, "raw_type": "tsquery"},
            {"name": "point_value", "column_type": ColumnType.UNKNOWN, "raw_type": "point"},
            {"name": "box_value", "column_type": ColumnType.UNKNOWN, "raw_type": "box"},
            {"name": "regtype_value", "column_type": ColumnType.BINARY, "raw_type": "regtype"},
            {"name": "timetz_value", "column_type": ColumnType.TIME},
            {"name": "timestamptz_value", "column_type": ColumnType.TIMESTAMP},
        ])
        assert result_set.value(0, 0) == 1234
        assert result_set.value(0, 3) == "10.0.0.0/24"
        assert result_set.value(0, 4) == "08:00:2b:01:02:03"
        assert result_set.value(0, 5) == "08:00:2b:01:02:03:04:05"
        assert result_set.value(0, 6) == "'hello':1 'world':2"
        assert result_set.value(0, 7) == "'hello' & 'world'"
        assert result_set.value(0, 8) == "(1,2)"
        assert result_set.value(0, 9) == "(1,1),(0,0)"
        assert result_set.value(0, 10) == b"#"
        assert result_set.value(0, 12) == dt.datetime(2024, 1, 2, 1, 4, 5)

        for index, label in ((1, "bit_value"), (2, "varbit_value"), (11, "timetz_value")):
            assert_hex_value(result_set.value(0, index), label)
    finally:
        await result_set.close_async()

    result_set = await connection.execute_async(POSTGRES_RANGE_AND_SYSTEM_TYPES_SQL)
    try:
        assert_column_metadata(result_set.columns, [
            {"name": "range_value", "column_type": ColumnType.BINARY},
            {"name": "multirange_value", "column_type": ColumnType.BINARY},
            {"name": "oid_value", "column_type": ColumnType.INT32},
            {"name": "regclass_value", "column_type": ColumnType.BINARY, "raw_type": "regclass"},
            {"name": "tid_value", "column_type": ColumnType.UNKNOWN, "raw_type": "tid"},
            {"name": "lsn_value", "column_type": ColumnType.UNKNOWN, "raw_type": "pg_lsn"},
        ])
        assert result_set.value(0, 0) == b"\x02\x00\x00\x00\x04\x00\x00\x00\x01\x00\x00\x00\x04\x00\x00\x00\x05"
        assert result_set.value(0, 1) == (
            b"\x00\x00\x00\x02\x00\x00\x00\x11\x02\x00\x00\x00\x04\x00\x00\x00"
            b"\x01\x00\x00\x00\x04\x00\x00\x00\x05\x00\x00\x00\x11\x02\x00\x00"
            b"\x00\x04\x00\x00\x00\x07\x00\x00\x00\x04\x00\x00\x00\t"
        )
        assert result_set.value(0, 2) == 42
        assert result_set.value(0, 3) == b"\x12G"
        assert result_set.value(0, 4) == "(1,2)"
        assert result_set.value(0, 5) == "0/16B6C50"
    finally:
        await result_set.close_async()

    result_set = await connection.execute_async("select null::anyelement as pseudo_value")
    try:
        assert_column_metadata(result_set.columns, [{"name": "pseudo_value", "column_type": ColumnType.TEXT}])
        assert result_set.value(0, 0) is None
    finally:
        await result_set.close_async()

    with_runtime_error = False
    try:
        row_result = await connection.execute_async("select row(1, 'alpha') as row_value")
    except RuntimeError:
        with_runtime_error = True
    else:
        await row_result.close_async()
    assert with_runtime_error, "anonymous PostgreSQL row values should currently raise until composite decoding is supported end-to-end"


class PostgresBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_postgres(self) -> None:
        section = "postgres"
        if not should_run_section(section):
            self.skipTest(f"DATABASE_ZIG_TEST_SECTION is filtering out {section}")

        target = load_test_target(section)
        database_name = unique_identifier("aq_pg")
        table_name = unique_identifier("records")
        missing_database = unique_identifier("missing_db")

        async with ConnectionManager() as manager:
            with self.assertRaisesRegex(RuntimeError, missing_database):
                await manager.connect_async(target.driver, target.dsn(missing_database))

            admin_connection = await manager.connect_async(target.driver, target.dsn())
            try:
                await execute_non_query(admin_connection, f"create database {database_name}")

                database_connection = await manager.connect_async(target.driver, target.dsn(database_name))
                try:
                    self.assertTrue(await database_connection.test_async())

                    type_coverage = await assert_type_coverage(database_connection, build_postgres_type_coverage_case(table_name), assert_postgres_type_coverage_values)
                    await assert_postgres_additional_type_coverage(database_connection)

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

                    tables_result = await database_connection.get_tables_async(database="public")
                    try:
                        self.assertIn(table_name, read_result_set_values(tables_result, 2))
                        self.assertIn(type_coverage["metadata_database"], read_result_set_values(tables_result, 1))
                    finally:
                        await tables_result.close_async()
                finally:
                    await database_connection.close_async()
            finally:
                try:
                    await execute_non_query(admin_connection, f"drop database if exists {database_name}")
                finally:
                    await admin_connection.close_async()


if __name__ == "__main__":
    unittest.main()