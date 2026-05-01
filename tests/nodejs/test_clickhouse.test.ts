import assert = require("node:assert/strict");
import test = require("node:test");

import {
  assertErrorMessage,
  bindingLoadError,
  bindingModule,
  isRuntimeUnavailableError,
  loadTarget,
  readResultSetValues,
  shouldRunSection,
} from "./support";

const target = loadTarget("clickhouse");

const skipReason = bindingLoadError
  ? `node binding dependencies are not available: ${bindingLoadError.message}`
  : !shouldRunSection("clickhouse")
    ? "DATABASE_ZIG_TEST_SECTION is filtering out clickhouse"
    : "skip" in target
      ? target.skip
      : undefined;

test("test_clickhouse", { skip: skipReason }, async () => {
  if ("skip" in target) {
    throw new Error(target.skip);
  }

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

      const databasesResult = await connection.getDatabases();
      try {
        assert.ok(readResultSetValues(databasesResult, 0).some((value) => value !== null && value !== ""));
      } finally {
        await databasesResult.close();
      }

      await assert.rejects(
        connection.getCatalogs(),
        (error) => assertErrorMessage(error, /get catalogs is not supported/i),
      );
    } finally {
      await connection.close();
    }
  } finally {
    await manager.dispose();
  }
});