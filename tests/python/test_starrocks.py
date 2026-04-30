from __future__ import annotations

import unittest

from _support import assert_database_binding


class StarRocksBindingIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_starrocks(self) -> None:
        await assert_database_binding("starrocks")


if __name__ == "__main__":
    unittest.main()