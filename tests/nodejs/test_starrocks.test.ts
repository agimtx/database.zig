import assert = require("node:assert/strict");
import test = require("node:test");

import {
  assertBooleanValue,
  assertColumnMetadata,
  assertErrorMessage,
  assertNamespaceAccess,
  assertNonEmptyValue,
  assertTableQualifiedName,
  assertTypeCoverage,
  bindingLoadError,
  bindingModule,
  executeNonQuery,
  findResultSetRowIndex,
  isRuntimeUnavailableError,
  loadTarget,
  readResultSetValues,
  shouldRunSection,
  type TypeCoverageCase,
  uniqueIdentifier,
} from "./support";

type Connection = import("../../bindings/nodejs/src/index").Connection;
type ResultSet = import("../../bindings/nodejs/src/index").ResultSet;

const target = loadTarget("starrocks");

function buildStarRocksTypeCoverageCase(tableName: string): TypeCoverageCase {
  return {
    metadataDatabase: null,
    createTableSql:
      `create table ${tableName} (` +
      "id bigint not null, " +
      "bool_value boolean not null, " +
      "int_value bigint not null, " +
      "float_value double not null, " +
      "text_value string not null, " +
      "fixed_text_value char(5) not null, " +
      "decimal_value decimal(10, 2) not null, " +
      "date_value date not null, " +
      "timestamp_value datetime not null, " +
      "largeint_value largeint not null, " +
      "json_value json not null" +
      `) duplicate key(id) distributed by hash(id) buckets 1 properties ("replication_num" = "1")`,
    insertSql:
      `insert into ${tableName} (` +
      "id, bool_value, int_value, float_value, text_value, fixed_text_value, decimal_value, date_value, timestamp_value, largeint_value, json_value" +
      ") values (" +
      "1, true, 42, 3.5, 'alpha', 'omega', 123.45, '2024-01-02', '2024-01-02 03:04:05', 123456789012345678901234567890, parse_json('{\"enabled\": true, \"count\": 1}')" +
      ")",
    selectSql:
      `select id, bool_value, int_value, float_value, text_value, fixed_text_value, decimal_value, date_value, timestamp_value, largeint_value, json_value from ${tableName} order by id`,
    expectedColumns: [
      { name: "id", type: bindingModule.COLUMN_TYPES.INT64 },
      { name: "bool_value", type: [bindingModule.COLUMN_TYPES.BOOLEAN, bindingModule.COLUMN_TYPES.INT8] },
      { name: "int_value", type: bindingModule.COLUMN_TYPES.INT64 },
      { name: "float_value", type: bindingModule.COLUMN_TYPES.FLOAT64 },
      { name: "text_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "fixed_text_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "decimal_value", type: bindingModule.COLUMN_TYPES.DECIMAL },
      { name: "date_value", type: bindingModule.COLUMN_TYPES.DATE },
      { name: "timestamp_value", type: bindingModule.COLUMN_TYPES.TIMESTAMP },
      { name: "largeint_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "json_value", type: [bindingModule.COLUMN_TYPES.JSON, bindingModule.COLUMN_TYPES.TEXT] },
    ],
  };
}

function assertStarRocksTypeCoverageValues(resultSet: ResultSet): void {
  const columns = resultSet.columns;
  assert.equal(resultSet.value(0, 0), 1n);
  if (columns[1].columnType === bindingModule.COLUMN_TYPES.BOOLEAN) {
    assertBooleanValue(resultSet.value(0, 1));
  } else {
    assert.equal(resultSet.value(0, 1), 1);
  }
  assert.equal(resultSet.value(0, 2), 42n);
  assert.equal(resultSet.value(0, 3), 3.5);
  assert.equal(resultSet.value(0, 4), "alpha");
  assert.equal(resultSet.value(0, 5), "omega");
  assert.equal(resultSet.value(0, 6), "123.45");
  assert.equal(resultSet.value(0, 7), "2024-01-02");
  const timestampValue = resultSet.value(0, 8);
  assertNonEmptyValue(timestampValue, "timestamp_value");
  assert.match(timestampValue, /^2024-01-02T03:04:05(?:\.\d+)?$/);
  assert.equal(resultSet.value(0, 9), "123456789012345678901234567890");
  if (columns[10].columnType === bindingModule.COLUMN_TYPES.JSON) {
    assert.deepEqual(resultSet.value(0, 10), { enabled: true, count: 1 });
  } else {
    const jsonValue = resultSet.value(0, 10);
    assertNonEmptyValue(jsonValue, "json_value");
    assert.match(jsonValue, /"enabled"/);
  }
}

const STARROCKS_ADDITIONAL_TYPES_SQL =
  "select " +
  "cast(1 as tinyint) as tiny_value, " +
  "cast(2 as smallint) as small_value, " +
  "cast(3 as int) as int_value, " +
  "cast(4 as bigint) as big_value, " +
  "cast(5.5 as float) as float_value, " +
  "cast(6.5 as double) as double_value, " +
  "cast('[1,2,3]' as array<int>) as array_value, " +
  "map('a',1,'b',2) as map_value, " +
  "row(1, 'alpha') as struct_value";

const STARROCKS_SKETCH_TYPES_SQL =
  "select " +
  "to_bitmap(42) as bitmap_value, " +
  "hll_hash('alpha') as hll_value, " +
  "percentile_hash(42) as percentile_value";

async function assertStarRocksAdditionalTypeCoverage(connection: Connection): Promise<void> {
  const resultSet = await connection.execute(STARROCKS_ADDITIONAL_TYPES_SQL);
  try {
    assertColumnMetadata(resultSet.columns, [
      { name: "tiny_value", type: bindingModule.COLUMN_TYPES.INT8 },
      { name: "small_value", type: bindingModule.COLUMN_TYPES.INT16 },
      { name: "int_value", type: bindingModule.COLUMN_TYPES.INT32 },
      { name: "big_value", type: bindingModule.COLUMN_TYPES.INT64 },
      { name: "float_value", type: bindingModule.COLUMN_TYPES.FLOAT32 },
      { name: "double_value", type: bindingModule.COLUMN_TYPES.FLOAT64 },
      { name: "array_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "map_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "struct_value", type: bindingModule.COLUMN_TYPES.TEXT },
    ]);
    assert.ok(resultSet.columns.every((column) => column.rawType === null));
    assert.equal(resultSet.value(0, 0), 1);
    assert.equal(resultSet.value(0, 1), 2);
    assert.equal(resultSet.value(0, 2), 3);
    assert.equal(resultSet.value(0, 3), 4n);
    assert.equal(resultSet.value(0, 4), 5.5);
    assert.equal(resultSet.value(0, 5), 6.5);
    assert.equal(resultSet.value(0, 6), "[1,2,3]");
    assert.equal(resultSet.value(0, 7), '{"a":1,"b":2}');
    assert.equal(resultSet.value(0, 8), '{"col1":1,"col2":"alpha"}');
  } finally {
    await resultSet.close();
  }

  const sketchResult = await connection.execute(STARROCKS_SKETCH_TYPES_SQL);
  try {
    assertColumnMetadata(sketchResult.columns, [
      { name: "bitmap_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "hll_value", type: bindingModule.COLUMN_TYPES.TEXT },
      { name: "percentile_value", type: bindingModule.COLUMN_TYPES.BINARY },
    ]);
    assert.equal(sketchResult.value(0, 0), null);
    assert.equal(sketchResult.value(0, 1), null);
    assert.equal(sketchResult.value(0, 2), null);
  } finally {
    await sketchResult.close();
  }
}

async function runStarRocksLifecycleTest(): Promise<void> {
  if ("skip" in target) {
    throw new Error(target.skip);
  }

  const databaseName = uniqueIdentifier("aq_sr");
  const tableName = uniqueIdentifier("records");
  const missingDatabase = uniqueIdentifier("missing_db");
  const manager = new bindingModule.ConnectionManager();

  try {
    let adminConnection: Connection;
    try {
      adminConnection = await manager.connect(target.driver, target.dsn());
    } catch (error: unknown) {
      if (isRuntimeUnavailableError(error)) {
        return;
      }
      throw error;
    }

    await assert.rejects(
      manager.connect(target.driver, target.dsn(missingDatabase)),
      (error) => {
        assert.ok(error instanceof Error);
        assert.ok(error.message.length > 0);
        return true;
      },
    );

    try {
      await executeNonQuery(adminConnection, `create database if not exists ${databaseName}`);

      const databaseConnection = await manager.connect(target.driver, target.dsn(databaseName));
      try {
        assert.equal(await databaseConnection.test(), true);

        await assertTypeCoverage(databaseConnection, buildStarRocksTypeCoverageCase(tableName), assertStarRocksTypeCoverageValues);
        await assertStarRocksAdditionalTypeCoverage(databaseConnection);

        const missingTable = uniqueIdentifier("missing");
        await assert.rejects(
          databaseConnection.execute(`select * from ${missingTable}`),
          (error) => assertErrorMessage(error, new RegExp(missingTable)),
        );

        const missingColumn = uniqueIdentifier("missing_column");
        await assert.rejects(
          databaseConnection.execute(`select ${missingColumn} from ${tableName}`),
          (error) => assertErrorMessage(error, new RegExp(missingColumn)),
        );

        const databasesResult = await databaseConnection.getDatabases();
        try {
          assert.ok(readResultSetValues(databasesResult, 0).includes(databaseName));
        } finally {
          await databasesResult.close();
        }

        const tablesResult = await databaseConnection.getTables(null, databaseName);
        try {
          assert.ok(readResultSetValues(tablesResult, 2).includes(tableName));
          assert.ok(
            readResultSetValues(tablesResult, 0).some((catalogName) => catalogName !== null && catalogName !== ""),
          );
          assertTableQualifiedName(tablesResult, findResultSetRowIndex(tablesResult, 2, tableName));
        } finally {
          await tablesResult.close();
        }

        const namespaceAccess = await databaseConnection.inspectNamespaceAccess(null, databaseName);
        assertNamespaceAccess(namespaceAccess, {
          canGetSchema: false,
          hasCatalogAccess: true,
          hasNamespaceAccess: true,
          namespaceRole: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE,
          parts: [{ role: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, value: databaseName }],
        });

        const missingAccess = await databaseConnection.inspectNamespaceAccess(null, missingDatabase);
        assertNamespaceAccess(missingAccess, {
          canGetSchema: false,
          hasCatalogAccess: true,
          hasNamespaceAccess: false,
          namespaceRole: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE,
          parts: [{ role: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, value: missingDatabase }],
        });
      } finally {
        await databaseConnection.close();
      }
    } finally {
      try {
        await executeNonQuery(adminConnection, `drop database if exists ${databaseName}`);
      } finally {
        await adminConnection.close();
      }
    }
  } finally {
    await manager.dispose();
  }
}

const skipReason = bindingLoadError
  ? `node binding dependencies are not available: ${bindingLoadError.message}`
  : !shouldRunSection("starrocks")
    ? "DATABASE_ZIG_TEST_SECTION is filtering out starrocks"
    : "skip" in target
      ? target.skip
      : undefined;

test("test_starrocks", { skip: skipReason }, async () => {
  await runStarRocksLifecycleTest();
});