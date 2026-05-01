from __future__ import annotations

import datetime as dt
import unittest
import uuid
from decimal import Decimal

from _support import ColumnType, _binding_module

ColumnMetadata = _binding_module.ColumnMetadata
ResultSet = _binding_module.ResultSet


class _FakeManager:
    def __init__(self, column_type: ColumnType, raw_value: str | None) -> None:
        self._columns = [ColumnMetadata(name="value", raw_type=None, column_type=column_type, nullable=True)]
        self._raw_value = raw_value

    def _result_set_columns(self, result_set_id: int) -> list[ColumnMetadata]:
        del result_set_id
        return self._columns

    def _result_set_value(self, result_set_id: int, row_index: int, column_index: int) -> str | None:
        del result_set_id, row_index, column_index
        return self._raw_value


class ResultValueConversionTests(unittest.TestCase):
    def _value(self, column_type: ColumnType, raw_value: str | None) -> object | None:
        result_set = ResultSet(_FakeManager(column_type, raw_value), 1)
        return result_set.value(0, 0)

    def test_boolean_values_become_bool(self) -> None:
        self.assertIs(self._value(ColumnType.BOOLEAN, "true"), True)
        self.assertIs(self._value(ColumnType.BOOLEAN, "0"), False)

    def test_int64_values_become_int(self) -> None:
        self.assertEqual(self._value(ColumnType.INT64, "42"), 42)

    def test_int32_values_become_int(self) -> None:
        self.assertEqual(self._value(ColumnType.INT32, "42"), 42)

    def test_uint64_values_become_int(self) -> None:
        self.assertEqual(self._value(ColumnType.UINT64, "42"), 42)

    def test_float64_values_become_float(self) -> None:
        self.assertEqual(self._value(ColumnType.FLOAT64, "3.5"), 3.5)

    def test_float32_values_become_float(self) -> None:
        self.assertEqual(self._value(ColumnType.FLOAT32, "3.5"), 3.5)

    def test_binary_values_become_bytes(self) -> None:
        self.assertEqual(self._value(ColumnType.BINARY, "0102ff"), b"\x01\x02\xff")

    def test_decimal_values_become_decimal(self) -> None:
        self.assertEqual(self._value(ColumnType.DECIMAL, "123.45"), Decimal("123.45"))

    def test_date_values_become_date(self) -> None:
        self.assertEqual(self._value(ColumnType.DATE, "2024-01-02"), dt.date(2024, 1, 2))

    def test_time_values_become_time(self) -> None:
        self.assertEqual(self._value(ColumnType.TIME, "03:04:05.123456"), dt.time(3, 4, 5, 123456))

    def test_timestamp_values_become_datetime(self) -> None:
        self.assertEqual(self._value(ColumnType.TIMESTAMP, "2024-01-02T03:04:05.123456"), dt.datetime(2024, 1, 2, 3, 4, 5, 123456))

    def test_uuid_values_become_uuid(self) -> None:
        self.assertEqual(self._value(ColumnType.UUID, "550e8400-e29b-41d4-a716-446655440000"), uuid.UUID("550e8400-e29b-41d4-a716-446655440000"))

    def test_json_values_become_objects(self) -> None:
        self.assertEqual(self._value(ColumnType.JSON, '{"enabled": true, "count": 1}'), {"enabled": True, "count": 1})

    def test_array_values_become_lists(self) -> None:
        self.assertEqual(self._value(ColumnType.ARRAY, "[1,2,3]"), [1, 2, 3])

    def test_null_values_remain_none(self) -> None:
        self.assertIsNone(self._value(ColumnType.TEXT, None))


if __name__ == "__main__":
    unittest.main()