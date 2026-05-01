import assert = require("node:assert/strict");
import test = require("node:test");

import {
  bindingLoadError,
  bindingModule,
  isRuntimeUnavailableError,
  loadTarget,
  readResultSetValues,
  shouldRunSection,
} from "./support";

const target = loadTarget("trino");

const skipReason = bindingLoadError
  ? `node binding dependencies are not available: ${bindingLoadError.message}`
  : !shouldRunSection("trino")
    ? "DATABASE_ZIG_TEST_SECTION is filtering out trino"
    : "skip" in target
      ? target.skip
      : undefined;

test("test_trino", { skip: skipReason }, async () => {
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

      const catalogsResult = await connection.getCatalogs();
      try {
        assert.ok(readResultSetValues(catalogsResult, 0).some((value) => value !== null && value !== ""));
      } finally {
        await catalogsResult.close();
      }
    } finally {
      await connection.close();
    }
  } finally {
    await manager.dispose();
  }
});