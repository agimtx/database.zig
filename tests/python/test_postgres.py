from __future__ import annotations

import unittest

from _support import ConnectionManager, execute_non_query, load_test_target, read_result_set_values, should_run_section, unique_identifier


class PostgresBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_postgres(self) -> None:
        section = "postgres"
        if not should_run_section(section):
            self.skipTest(f"DATABASE_ZIG_TEST_SECTION is filtering out {section}")

        target = load_test_target(section)
        database_name = unique_identifier("dbz_pg")
        table_name = unique_identifier("records")

        async with ConnectionManager() as manager:
            admin_connection = await manager.connect_async(target.driver, target.dsn())
            try:
                await execute_non_query(admin_connection, f"create database {database_name}")

                database_connection = await manager.connect_async(target.driver, target.dsn(database_name))
                try:
                    await execute_non_query(
                        database_connection,
                        f"create table {table_name} (id bigint primary key, value text not null)",
                    )
                    await execute_non_query(
                        database_connection,
                        f"insert into {table_name} (id, value) values (1, 'alpha'), (2, 'beta')",
                    )

                    self.assertTrue(await database_connection.test_async())

                    result_set = await database_connection.execute_async(f"select id, value from {table_name} order by id")
                    try:
                        self.assertEqual(result_set.row_count, 2)
                        self.assertEqual(result_set.value(0, 1), "alpha")
                        self.assertEqual(result_set.value(1, 1), "beta")
                    finally:
                        await result_set.close_async()

                    databases_result = await database_connection.get_databases_async()
                    try:
                        self.assertIn(database_name, read_result_set_values(databases_result, 0))
                    finally:
                        await databases_result.close_async()

                    tables_result = await database_connection.get_tables_async(database="public")
                    try:
                        self.assertIn(table_name, read_result_set_values(tables_result, 2))
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