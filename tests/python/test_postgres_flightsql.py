from __future__ import annotations

import unittest

from _support import ConnectionManager, QualifiedNamePartRole, assert_boolean_value, assert_namespace_access, assert_table_qualified_name, execute_non_query, find_result_set_row_index, is_runtime_unavailable_error, load_test_target, read_result_set_values, should_run_section, unique_identifier


class PostgresFlightSqlBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_postgres_flightsql(self) -> None:
        if not should_run_section("postgres_flightsql"):
            self.skipTest("DATABASE_ZIG_TEST_SECTION is filtering out postgres_flightsql")

        target = load_test_target("postgres_flightsql")
        table_name = unique_identifier("aq_pg_flightsql")

        async with ConnectionManager() as manager:
            try:
                connection = await manager.connect_async(target.driver, target.dsn())
            except Exception as error:
                if is_runtime_unavailable_error(error):
                    self.skipTest(str(error))
                raise

            try:
                self.assertTrue(await connection.test_async())

                await execute_non_query(
                    connection,
                    f"create table {table_name} (id bigint primary key, enabled boolean not null, name text not null)",
                )
                try:
                    await execute_non_query(
                        connection,
                        f"insert into {table_name} (id, enabled, name) values (1, true, 'alpha'), (2, false, 'beta')",
                    )

                    result_set = await connection.execute_async(
                        f"select id, enabled, name from {table_name} order by id"
                    )
                    try:
                        self.assertEqual(result_set.row_count, 2)
                        self.assertEqual(result_set.affected_rows, 2)

                        columns = result_set.columns
                        self.assertEqual(len(columns), 3)
                        self.assertEqual(columns[0].name, "id")
                        self.assertEqual(columns[1].name, "enabled")
                        self.assertEqual(columns[2].name, "name")

                        self.assertEqual(result_set.value(0, 0), 1)
                        assert_boolean_value(result_set.value(0, 1))
                        self.assertEqual(result_set.value(0, 2), "alpha")
                        self.assertEqual(result_set.value(1, 0), 2)
                        assert_boolean_value(result_set.value(1, 1))
                        self.assertEqual(result_set.value(1, 2), "beta")
                    finally:
                        await result_set.close_async()

                    with self.assertRaises(Exception) as missing_table_error:
                        await connection.execute_async(f"select * from {unique_identifier('missing_table')}")
                    self.assertTrue(str(missing_table_error.exception))

                    cursor = await connection.cursor_async(
                        f"select id, enabled, name from {table_name} order by id"
                    )
                    try:
                        self.assertEqual(len(cursor.columns), 3)
                        seen_rows = 0
                        while cursor.next():
                            seen_rows += 1
                        self.assertEqual(seen_rows, 2)
                    finally:
                        await cursor.close_async()

                    databases_result = await connection.get_databases_async()
                    try:
                        self.assertIn("public", read_result_set_values(databases_result, 0))
                    finally:
                        await databases_result.close_async()

                    with self.assertRaisesRegex(RuntimeError, "get catalogs is not supported"):
                        await connection.get_catalogs_async()

                    tables_result = await connection.get_tables_async(database="public")
                    try:
                        table_names = read_result_set_values(tables_result, 2)
                        self.assertIn(table_name, table_names)
                        row_index = find_result_set_row_index(tables_result, 2, table_name)
                        assert_table_qualified_name(tables_result, row_index)
                    finally:
                        await tables_result.close_async()

                    namespace_access = await connection.inspect_namespace_access_async(database="public")
                    assert_namespace_access(
                        namespace_access,
                        can_get_schema=False,
                        has_catalog_access=True,
                        has_namespace_access=True,
                        namespace_role=QualifiedNamePartRole.DATABASE,
                        expected_parts=[(QualifiedNamePartRole.DATABASE, "public")],
                    )

                    missing_namespace = unique_identifier("missing_schema")
                    missing_access = await connection.inspect_namespace_access_async(database=missing_namespace)
                    assert_namespace_access(
                        missing_access,
                        can_get_schema=False,
                        has_catalog_access=True,
                        has_namespace_access=False,
                        namespace_role=QualifiedNamePartRole.DATABASE,
                        expected_parts=[(QualifiedNamePartRole.DATABASE, missing_namespace)],
                    )
                finally:
                    await execute_non_query(connection, f"drop table if exists {table_name}")
            finally:
                await connection.close_async()