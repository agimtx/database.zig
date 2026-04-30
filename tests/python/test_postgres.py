from __future__ import annotations

import unittest

from _support import assert_database_binding


class PostgresBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_postgres(self) -> None:
        await assert_database_binding("postgres")


if __name__ == "__main__":
    unittest.main()