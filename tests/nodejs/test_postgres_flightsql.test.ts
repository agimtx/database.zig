import assert = require("node:assert/strict");
import test = require("node:test");

import {
  assertBooleanValue,
  assertErrorMessage,
  assertNamespaceAccess,
  assertTableQualifiedName,
  bindingLoadError,
  bindingModule,
  executeNonQuery,
  findResultSetRowIndex,
  isRuntimeUnavailableError,
  loadTarget,
  readResultSetValues,
  shouldRunSection,
  uniqueIdentifier,
} from "./support";

const target = loadTarget("postgres_flightsql");

const skipReason = bindingLoadError
  ? `node binding dependencies are not available: ${bindingLoadError.message}`
  : !shouldRunSection("postgres_flightsql")
    ? "DATABASE_ZIG_TEST_SECTION is filtering out postgres_flightsql"
    : "skip" in target
      ? target.skip
      : undefined;

test("test_postgres_flightsql", { skip: skipReason }, async () => {
  if ("skip" in target) {
    throw new Error(target.skip);
  }

  const tableName = uniqueIdentifier("aq_pg_flightsql");
  const manager = new bindingModule.ConnectionManager();
  try {
    let connection: import("../../bindings/nodejs/src/index").Connection;
    try {
      connection = await manager.connect(target.driver, target.dsn());
    } catch (error: unknown) {
      if (isRuntimeUnavailableError(error)) {
        return;
      }
      throw error;
    }

    try {
      assert.equal(await connection.test(), true);

      await executeNonQuery(
        connection,
        `create table ${tableName} (id bigint primary key, enabled boolean not null, name text not null)`,
      );
      try {
        await executeNonQuery(
          connection,
          `insert into ${tableName} (id, enabled, name) values (1, true, 'alpha'), (2, false, 'beta')`,
        );

        const resultSet = await connection.execute(`select id, enabled, name from ${tableName} order by id`);
        try {
          assert.equal(resultSet.rowCount, 2);
          assert.equal(resultSet.affectedRows, 2);

          const columns = resultSet.columns;
          assert.equal(columns.length, 3);
          assert.equal(columns[0].name, "id");
          assert.equal(columns[1].name, "enabled");
          assert.equal(columns[2].name, "name");

          assert.equal(resultSet.value(0, 0), 1n);
          assertBooleanValue(resultSet.value(0, 1));
          assert.equal(resultSet.value(0, 2), "alpha");
          assert.equal(resultSet.value(1, 0), 2n);
          assertBooleanValue(resultSet.value(1, 1));
          assert.equal(resultSet.value(1, 2), "beta");
        } finally {
          await resultSet.close();
        }

        await assert.rejects(
          connection.execute(`select * from ${uniqueIdentifier("missing_table")}`),
          (error) => {
            assert.ok(error instanceof Error);
            assert.ok(error.message.length > 0);
            return true;
          },
        );

        const cursor = await connection.cursor(`select id, enabled, name from ${tableName} order by id`);
        try {
          const columns = cursor.columns;
          assert.equal(columns.length, 3);

          let seenRows = 0;
          while (cursor.next()) {
            seenRows += 1;
          }
          assert.equal(seenRows, 2);
        } finally {
          await cursor.close();
        }

        const databasesResult = await connection.getDatabases();
        try {
          assert.ok(readResultSetValues(databasesResult, 0).includes("public"));
        } finally {
          await databasesResult.close();
        }

        await assert.rejects(
          connection.getCatalogs(),
          (error) => assertErrorMessage(error, /get catalogs is not supported/i),
        );

        const tablesResult = await connection.getTables(null, "public");
        try {
          const tableNames = readResultSetValues(tablesResult, 2);
          assert.ok(tableNames.includes(tableName));
          const rowIndex = findResultSetRowIndex(tablesResult, 2, tableName);
          assertTableQualifiedName(tablesResult, rowIndex);
        } finally {
          await tablesResult.close();
        }

        const namespaceAccess = await connection.inspectNamespaceAccess(null, "public");
        assertNamespaceAccess(namespaceAccess, {
          canGetSchema: false,
          hasCatalogAccess: true,
          hasNamespaceAccess: true,
          namespaceRole: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE,
          parts: [{ role: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, value: "public" }],
        });

        const missingNamespace = uniqueIdentifier("missing_schema");
        const missingAccess = await connection.inspectNamespaceAccess(null, missingNamespace);
        assertNamespaceAccess(missingAccess, {
          canGetSchema: false,
          hasCatalogAccess: true,
          hasNamespaceAccess: false,
          namespaceRole: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE,
          parts: [{ role: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, value: missingNamespace }],
        });
      } finally {
        await executeNonQuery(connection, `drop table if exists ${tableName}`);
      }
    } finally {
      await connection.close();
    }
  } finally {
    await manager.dispose();
  }
});