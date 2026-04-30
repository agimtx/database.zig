from __future__ import annotations

import unittest

from _support import ConnectionManager, assert_type_coverage, execute_non_query, load_test_target, read_result_set_values, should_run_section, unique_identifier


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
            with self.assertRaisesRegex(RuntimeError, missing_database):
                await manager.connect_async(target.driver, target.dsn(missing_database))

            admin_connection = await manager.connect_async(target.driver, target.dsn())
            try:
                await execute_non_query(admin_connection, f"create database if not exists {database_name}")

                database_connection = await manager.connect_async(target.driver, target.dsn(database_name))
                try:
                    self.assertTrue(await database_connection.test_async())

                    await assert_type_coverage(database_connection, "starrocks", table_name)

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

                    tables_result = await database_connection.get_tables_async(database=database_name)
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