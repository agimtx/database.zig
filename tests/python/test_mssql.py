from __future__ import annotations

import unittest

from _support import ConnectionManager, is_runtime_unavailable_error, load_test_target, read_result_set_values, should_run_section


class MssqlBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_mssql(self) -> None:
        if not should_run_section("mssql"):
            self.skipTest("DATABASE_ZIG_TEST_SECTION is filtering out mssql")

        target = load_test_target("mssql")

        async with ConnectionManager() as manager:
            try:
                connection = await manager.connect_async(target.driver, target.dsn())
            except Exception as error:
                if is_runtime_unavailable_error(error):
                    self.skipTest(str(error))
                raise

            try:
                self.assertTrue(await connection.test_async())

                databases_result = await connection.get_databases_async()
                try:
                    self.assertTrue(any(name not in (None, "") for name in read_result_set_values(databases_result, 0)))
                finally:
                    await databases_result.close_async()

                catalogs_result = await connection.get_catalogs_async()
                try:
                    self.assertTrue(any(name not in (None, "") for name in read_result_set_values(catalogs_result, 0)))
                finally:
                    await catalogs_result.close_async()
            finally:
                await connection.close_async()


if __name__ == "__main__":
    unittest.main()