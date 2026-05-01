import assert = require("node:assert/strict");
import crypto = require("node:crypto");
import fs = require("node:fs");
import path = require("node:path");

type BindingModule = typeof import("../../bindings/nodejs/src/index");
type Connection = import("../../bindings/nodejs/src/index").Connection;
type ResultSet = import("../../bindings/nodejs/src/index").ResultSet;
type ColumnMetadata = import("../../bindings/nodejs/src/index").ColumnMetadata;
type ColumnType = import("../../bindings/nodejs/src/index").ColumnType;
type ResultValue = import("../../bindings/nodejs/src/index").ResultValue;
type QualifiedNamePartRole = import("../../bindings/nodejs/src/index").QualifiedNamePartRole;
type NamespaceAccess = import("../../bindings/nodejs/src/index").NamespaceAccess;

type DriverName = "adbc";
type SectionConfig = Record<string, string>;
type IniSections = Record<string, SectionConfig>;

interface SkippedTarget {
  skip: string;
}

interface LoadedSections {
  sections: IniSections;
}

export interface LoadedTarget {
  driver: DriverName;
  section: string;
  config: SectionConfig;
  dsn(databaseOverride?: string): string;
}

export interface ExpectedColumn {
  name: string;
  type: ColumnType | ColumnType[];
  rawType?: string | null;
}

export interface TypeCoverageCase {
  metadataDatabase: string | null;
  createTableSql: string;
  insertSql: string;
  selectSql: string;
  expectedColumns: ExpectedColumn[];
}

const repoRoot = path.resolve(__dirname, "../..");
const defaultEnvFile = path.join(repoRoot, ".env");
const repoTmpRoot = path.join(repoRoot, ".tmp");
export const testSql = "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value";

export let bindingModule!: BindingModule;
export let bindingLoadError: Error | undefined;

try {
  bindingModule = require(path.join(repoRoot, "bindings/nodejs/src/index.js")) as BindingModule;
} catch (error: unknown) {
  bindingLoadError = error instanceof Error ? error : new Error(String(error));
}

function parseIniSections(filePath: string): IniSections {
  const content = fs.readFileSync(filePath, "utf8");
  const sections: IniSections = {};
  let current: string | null = null;

  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) {
      continue;
    }
    if (line.startsWith("[") && line.endsWith("]")) {
      current = line.slice(1, -1).trim();
      sections[current] = {};
      continue;
    }
    if (!current) {
      continue;
    }

    const index = line.indexOf("=");
    if (index === -1) {
      continue;
    }

    const key = line.slice(0, index).trim();
    const value = line.slice(index + 1).trim();
    sections[current][key] = value;
  }

  return sections;
}

function loadSections(): LoadedSections | SkippedTarget {
  const envFile = process.env.DATABASE_ZIG_TEST_ENV_FILE || defaultEnvFile;
  if (!fs.existsSync(envFile)) {
    return { skip: `test config not found: ${envFile}` };
  }

  return {
    sections: parseIniSections(envFile),
  };
}

function resolveSectionName(sections: IniSections, sectionName: string): string | null {
  const aliases: Record<string, string> = {
    postgresql: "postgres",
  };
  const candidates = [sectionName, aliases[sectionName.toLowerCase()] || sectionName];
  for (const candidate of candidates) {
    if (Object.prototype.hasOwnProperty.call(sections, candidate)) {
      return candidate;
    }
  }
  return null;
}

export function shouldRunSection(sectionName: string): boolean {
  const requested = process.env.DATABASE_ZIG_TEST_SECTION;
  return !requested || requested.toLowerCase() === sectionName.toLowerCase();
}

export function loadTarget(sectionName: string): LoadedTarget | SkippedTarget {
  const loaded = loadSections();
  if ("skip" in loaded) {
    return loaded;
  }

  const resolvedSectionName = resolveSectionName(loaded.sections, sectionName);
  if (resolvedSectionName === null) {
    return { skip: `test section not found: ${sectionName}` };
  }
  const section = loaded.sections[resolvedSectionName];

  return {
    driver: "adbc",
    section: resolvedSectionName,
    config: section,
    dsn(databaseOverride = undefined) {
      return buildDsn(resolvedSectionName, section, databaseOverride);
    },
  };
}

function buildDsn(sectionName: string, config: SectionConfig, databaseOverride: string | undefined = undefined): string {
  if (config.dsn && databaseOverride === undefined) {
    return config.dsn;
  }

  const scheme = config.scheme || defaultScheme(sectionName);
  const host = config.host || "127.0.0.1";
  const port = config.port ? `:${config.port}` : "";
  const username = config.user || "";
  const password = Object.prototype.hasOwnProperty.call(config, "password") ? config.password : null;
  const database = databaseOverride !== undefined ? databaseOverride : (config.database || defaultDatabase(sectionName));

  let credentials = "";
  if (username) {
    credentials = encodeURIComponent(username);
    if (password !== null) {
      credentials += `:${encodeURIComponent(password)}`;
    }
    credentials += "@";
  }

  const databasePart = database ? `/${encodeURIComponent(database)}` : "";
  return `${scheme}://${credentials}${host}${port}${databasePart}`;
}

function defaultScheme(sectionName: string): string {
  const lowered = sectionName.toLowerCase();
  if (lowered === "postgres" || lowered === "postgresql") {
    return "postgresql";
  }
  if (lowered === "starrocks" || lowered === "mysql" || lowered === "singlestore") {
    return "mysql";
  }
  return lowered;
}

function defaultDatabase(sectionName: string): string {
  const lowered = sectionName.toLowerCase();
  if (lowered === "postgres" || lowered === "postgresql") {
    return "postgres";
  }
  if (lowered === "starrocks" || lowered === "mysql" || lowered === "singlestore") {
    return "information_schema";
  }
  return "";
}

export function vendoredDriverPath(name: string): string {
  let host: string;
  let fileName: string;

  if (process.platform === "darwin") {
    host = process.arch === "arm64" ? "macos-arm64" : "macos-x86_64";
    fileName = name === "duckdb" ? "libduckdb.dylib" : `libadbc_driver_${name}.dylib`;
  } else if (process.platform === "linux") {
    host = process.arch === "arm64" ? "linux-arm64" : "linux-x86_64";
    fileName = name === "duckdb" ? "libduckdb.so" : `libadbc_driver_${name}.so`;
  } else if (process.platform === "win32") {
    host = "windows-x86_64";
    fileName = name === "duckdb" ? "duckdb.dll" : `adbc_driver_${name}.dll`;
  } else {
    throw new Error(`unsupported platform for vendored ADBC driver lookup: ${process.platform}`);
  }

  return path.join(repoRoot, "third_party", "adbc", "1.11.0", "lib", host, fileName);
}

export function repoTmpDir(...parts: string[]): string {
  const target = path.join(repoTmpRoot, ...parts);
  fs.mkdirSync(target, { recursive: true });
  return target;
}

export function duckDbTestDsn(filePath: string): string {
  return `driver=${vendoredDriverPath("duckdb")};entrypoint=duckdb_adbc_init;path=${filePath}`;
}

export function removeFileIfExists(filePath: string): void {
  fs.rmSync(filePath, { force: true });
}

export function uniqueIdentifier(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, "").slice(0, 8)}`;
}

export async function executeNonQuery(connection: Connection, sql: string): Promise<void> {
  const resultSet = await connection.execute(sql);
  await resultSet.close();
}

export function readResultSetValues(resultSet: ResultSet, columnIndex: number): ResultValue[] {
  const values: ResultValue[] = [];
  for (let rowIndex = 0; rowIndex < resultSet.rowCount; rowIndex += 1) {
    values.push(resultSet.value(rowIndex, columnIndex));
  }
  return values;
}

export function findResultSetRowIndex(resultSet: ResultSet, columnIndex: number, expectedValue: ResultValue): number {
  for (let rowIndex = 0; rowIndex < resultSet.rowCount; rowIndex += 1) {
    if (resultSet.value(rowIndex, columnIndex) === expectedValue) {
      return rowIndex;
    }
  }

  throw new Error(`value not found in result set column ${columnIndex}: ${expectedValue}`);
}

function qualifiedNameRoleFromNamespaceKind(namespaceKind: string): QualifiedNamePartRole {
  return {
    catalog: bindingModule.QUALIFIED_NAME_PART_ROLES.CATALOG,
    database: bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE,
    schema: bindingModule.QUALIFIED_NAME_PART_ROLES.SCHEMA,
    dataset: bindingModule.QUALIFIED_NAME_PART_ROLES.DATASET,
    namespace: bindingModule.QUALIFIED_NAME_PART_ROLES.NAMESPACE,
    object: bindingModule.QUALIFIED_NAME_PART_ROLES.OBJECT,
  }[namespaceKind] as QualifiedNamePartRole;
}

export function assertStringValue(value: ResultValue, label: string): asserts value is string {
  assert.equal(typeof value, "string", `${label} should be returned as text`);
}

export function assertTableQualifiedName(resultSet: ResultSet, rowIndex: number) {
  const qualifiedName = resultSet.tableQualifiedName(rowIndex);
  assert.ok(qualifiedName instanceof bindingModule.QualifiedName);

  const expectedParts: Array<{ role: QualifiedNamePartRole; value: string }> = [];
  const catalog = resultSet.value(rowIndex, 0);
  const namespace = resultSet.value(rowIndex, 1);
  const objectName = resultSet.value(rowIndex, 2);
  const namespaceKind = resultSet.value(rowIndex, 4);
  const formatted = resultSet.value(rowIndex, 5);

  if (catalog !== null && catalog !== "") {
    assertStringValue(catalog, "catalog_name");
    expectedParts.push({ role: bindingModule.QUALIFIED_NAME_PART_ROLES.CATALOG, value: catalog });
  }
  if (namespace !== null && namespace !== "") {
    assertStringValue(namespace, "database_name");
    assertStringValue(namespaceKind, "namespace_kind");
    expectedParts.push({ role: qualifiedNameRoleFromNamespaceKind(namespaceKind), value: namespace });
  }
  if (objectName !== null && objectName !== "") {
    assertStringValue(objectName, "table_name");
    expectedParts.push({ role: bindingModule.QUALIFIED_NAME_PART_ROLES.OBJECT, value: objectName });
  }
  assertStringValue(formatted, "qualified_name");

  assert.deepEqual(
    qualifiedName.parts.map((part) => ({ role: part.role, value: part.value })),
    expectedParts,
  );
  assert.equal(qualifiedName.formatted, formatted);
  return qualifiedName;
}

export function assertNamespaceAccess(
  access: NamespaceAccess,
  expected: {
    canGetSchema: boolean;
    hasCatalogAccess: boolean;
    hasNamespaceAccess: boolean;
    namespaceRole: QualifiedNamePartRole;
    parts: Array<{ role: QualifiedNamePartRole; value: string }>;
  },
) {
  assert.ok(access instanceof bindingModule.NamespaceAccess);
  assert.equal(access.canGetSchema, expected.canGetSchema);
  assert.equal(access.hasCatalogAccess, expected.hasCatalogAccess);
  assert.equal(access.hasNamespaceAccess, expected.hasNamespaceAccess);
  assert.equal(access.namespaceRole, expected.namespaceRole);
  assert.deepEqual(
    access.qualifiedName.parts.map((part) => ({ role: part.role, value: part.value })),
    expected.parts,
  );
  assert.equal(
    access.qualifiedName.formatted,
    expected.parts.map((part) => part.value).filter((value) => value.length !== 0).join("."),
  );
  return access;
}

export function assertNonEmptyValue(value: ResultValue, label: string): asserts value is string {
  assertStringValue(value, label);
  assert.ok(value.length > 0, `${label} should not be empty`);
}

export function assertHexValue(value: ResultValue, label: string): void {
  if (Buffer.isBuffer(value)) {
    assert.ok(value.length > 0, `${label} should not be empty`);
    return;
  }

  assertStringValue(value, label);
  assert.ok(value.length > 0, `${label} should not be empty`);
  assert.equal(value.length % 2, 0, `${label} should contain an even number of hex characters`);
  assert.match(value, /^[0-9a-f]+$/i, `${label} should be hexadecimal`);
}

export function assertBooleanValue(value: ResultValue): asserts value is boolean {
  assert.equal(typeof value, "boolean", `unexpected boolean value: ${value}`);
}

export function assertColumnMetadata(columns: ColumnMetadata[], expectedColumns: ExpectedColumn[]): void {
  assert.equal(columns.length, expectedColumns.length, `expected ${expectedColumns.length} columns, got ${columns.length}`);
  for (let index = 0; index < expectedColumns.length; index += 1) {
    const actual = columns[index];
    const expected = expectedColumns[index];
    assert.equal(actual.name, expected.name, `column ${index} name mismatch`);
    const expectedTypes = Array.isArray(expected.type) ? expected.type : [expected.type];
    assert.ok(expectedTypes.includes(actual.columnType), `column ${actual.name} type mismatch: got ${actual.columnType}, expected one of ${expectedTypes.join(", ")}`);
    if (Object.prototype.hasOwnProperty.call(expected, "rawType")) {
      assert.equal(actual.rawType, expected.rawType, `column ${actual.name} rawType mismatch`);
    }
  }
}

export function assertErrorMessage(error: unknown, pattern: RegExp): true {
  assert.ok(error instanceof Error);
  assert.match(error.message, pattern);
  return true;
}

export function isRuntimeUnavailableError(error: unknown): error is Error {
  return error instanceof Error && (
    error.message.includes("Could not load") ||
    error.message.includes("Library not loaded") ||
    error.message.includes("connection refused") ||
    error.message.includes("timed out") ||
    error.message.includes("aq_connection_open failed:") ||
    error.message.includes("aq_connection_open_async failed:")
  );
}

export async function assertTypeCoverage(
  connection: Connection,
  typeCoverage: TypeCoverageCase,
  assertValues: (resultSet: ResultSet) => void,
): Promise<TypeCoverageCase> {
  await executeNonQuery(connection, typeCoverage.createTableSql);
  await executeNonQuery(connection, typeCoverage.insertSql);

  const resultSet = await connection.execute(typeCoverage.selectSql);
  try {
    assert.equal(resultSet.rowCount, 1);
    assertColumnMetadata(resultSet.columns, typeCoverage.expectedColumns);
    assertValues(resultSet);
  } finally {
    await resultSet.close();
  }

  const cursor = await connection.cursor(typeCoverage.selectSql);
  try {
    assertColumnMetadata(cursor.columns, typeCoverage.expectedColumns);
    assert.equal(cursor.next(), true);
    assert.equal(cursor.next(), false);
  } finally {
    await cursor.close();
  }

  return typeCoverage;
}