import assert = require("node:assert/strict");
import test = require("node:test");

import { bindingLoadError, bindingModule } from "./support";

type ColumnMetadata = import("../../bindings/nodejs/src/index").ColumnMetadata;
type ColumnType = import("../../bindings/nodejs/src/index").ColumnType;
type ConnectionManager = import("../../bindings/nodejs/src/index").ConnectionManager;
type QualifiedName = import("../../bindings/nodejs/src/index").QualifiedName;
type NamespaceAccess = import("../../bindings/nodejs/src/index").NamespaceAccess;
type ResultValue = import("../../bindings/nodejs/src/index").ResultValue;

class FakeManager {
  columns: ColumnMetadata[];
  rawValue: string | null;
  _resultSetTableQualifiedName?: () => QualifiedName;
  _inspectNamespaceAccess?: () => NamespaceAccess;

  constructor(columnType: ColumnType, rawValue: string | null) {
    this.columns = [{ name: "value", columnType, rawType: null, nullable: true }];
    this.rawValue = rawValue;
  }

  _resultSetColumns(): ColumnMetadata[] {
    return this.columns;
  }

  _resultSetValue(): string | null {
    return this.rawValue;
  }
}

function convert(columnType: ColumnType, rawValue: string | null): ResultValue {
  const resultSet = new bindingModule.ResultSet(new FakeManager(columnType, rawValue) as unknown as ConnectionManager, 1);
  return resultSet.value(0, 0);
}

const skipReason = bindingLoadError
  ? `node binding dependencies are not available: ${bindingLoadError.message}`
  : undefined;

function runValueTest(name: string, fn: () => void): void {
  if (skipReason) {
    test(name, { skip: skipReason }, fn);
    return;
  }

  test(name, fn);
}

runValueTest("node binding returns typed table qualified names", () => {
  const manager = new FakeManager(bindingModule.COLUMN_TYPES.TEXT, "ignored");
  manager._resultSetTableQualifiedName = () => new bindingModule.QualifiedName([
    new bindingModule.QualifiedNamePart(bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, "main"),
    new bindingModule.QualifiedNamePart(bindingModule.QUALIFIED_NAME_PART_ROLES.OBJECT, "records"),
  ], "main.records");

  const qualifiedName = new bindingModule.ResultSet(manager as unknown as ConnectionManager, 1).tableQualifiedName(0);
  assert.ok(qualifiedName instanceof bindingModule.QualifiedName);
  assert.equal(String(qualifiedName), "main.records");
  assert.deepEqual(
    qualifiedName.parts.map((part) => ({ role: part.role, value: part.value })),
    [
      { role: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, value: "main" },
      { role: bindingModule.QUALIFIED_NAME_PART_ROLES.OBJECT, value: "records" },
    ],
  );
});

runValueTest("node binding returns namespace access with typed qualified names", () => {
  const manager = new FakeManager(bindingModule.COLUMN_TYPES.TEXT, "ignored");
  manager._inspectNamespaceAccess = () => new bindingModule.NamespaceAccess(
    true,
    true,
    true,
    bindingModule.QUALIFIED_NAME_PART_ROLES.SCHEMA,
    new bindingModule.QualifiedName([
      new bindingModule.QualifiedNamePart(bindingModule.QUALIFIED_NAME_PART_ROLES.CATALOG, "analytics"),
      new bindingModule.QualifiedNamePart(bindingModule.QUALIFIED_NAME_PART_ROLES.SCHEMA, "public"),
    ], "analytics.public"),
  );

  const access = manager._inspectNamespaceAccess();
  assert.ok(access instanceof bindingModule.NamespaceAccess);
  assert.equal(access.canGetSchema, true);
  assert.equal(String(access.qualifiedName), "analytics.public");
});

runValueTest("node binding converts booleans", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.BOOLEAN, "true"), true);
  assert.equal(convert(bindingModule.COLUMN_TYPES.BOOLEAN, "0"), false);
});

runValueTest("node binding converts int64 to bigint", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.INT64, "42"), 42n);
});

runValueTest("node binding converts int32 to number", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.INT32, "42"), 42);
});

runValueTest("node binding converts uint64 to bigint", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.UINT64, "42"), 42n);
});

runValueTest("node binding converts float64 to number", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.FLOAT64, "3.5"), 3.5);
});

runValueTest("node binding converts float32 to number", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.FLOAT32, "3.5"), 3.5);
});

runValueTest("node binding converts binary to buffer", () => {
  assert.deepEqual(convert(bindingModule.COLUMN_TYPES.BINARY, "0102ff"), Buffer.from([0x01, 0x02, 0xff]));
});

runValueTest("node binding converts json to objects", () => {
  assert.deepEqual(convert(bindingModule.COLUMN_TYPES.JSON, '{"enabled":true,"count":1}'), { enabled: true, count: 1 });
});

runValueTest("node binding converts arrays to arrays", () => {
  assert.deepEqual(convert(bindingModule.COLUMN_TYPES.ARRAY, "[1,2,3]"), [1, 2, 3]);
});

runValueTest("node binding keeps decimals as strings", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.DECIMAL, "123.45"), "123.45");
});

runValueTest("node binding preserves null", () => {
  assert.equal(convert(bindingModule.COLUMN_TYPES.TEXT, null), null);
});