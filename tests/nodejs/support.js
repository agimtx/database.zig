const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "../..");
const defaultEnvFile = path.join(repoRoot, ".env");
const repoTmpRoot = path.join(repoRoot, ".tmp");
const testSql = "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value";

let bindingModule;
let bindingLoadError;

try {
  bindingModule = require(path.join(repoRoot, "bindings/nodejs/src/index.js"));
} catch (error) {
  bindingLoadError = error;
}

function parseIniSections(filePath) {
  const content = fs.readFileSync(filePath, "utf8");
  const sections = {};
  let current = null;

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

function loadSections() {
  const envFile = process.env.DATABASE_ZIG_TEST_ENV_FILE || defaultEnvFile;
  if (!fs.existsSync(envFile)) {
    return { skip: `test config not found: ${envFile}` };
  }

  return {
    sections: parseIniSections(envFile),
  };
}

function resolveSectionName(sections, sectionName) {
  const aliases = {
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

function shouldRunSection(sectionName) {
  const requested = process.env.DATABASE_ZIG_TEST_SECTION;
  return !requested || requested.toLowerCase() === sectionName.toLowerCase();
}

function loadTarget(sectionName) {
  const loaded = loadSections();
  if (loaded.skip) {
    return loaded;
  }

  const resolvedSectionName = resolveSectionName(loaded.sections, sectionName);
  const section = resolvedSectionName ? loaded.sections[resolvedSectionName] : null;
  if (!section) {
    return { skip: `test section not found: ${sectionName}` };
  }

  return {
    driver: "adbc",
    section: resolvedSectionName,
    config: section,
    dsn(databaseOverride = undefined) {
      return buildDsn(resolvedSectionName, section, databaseOverride);
    },
  };
}

function buildDsn(sectionName, config, databaseOverride = undefined) {
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

function defaultScheme(sectionName) {
  const lowered = sectionName.toLowerCase();
  if (lowered === "postgres" || lowered === "postgresql") {
    return "postgresql";
  }
  if (lowered === "starrocks" || lowered === "mysql" || lowered === "singlestore") {
    return "mysql";
  }
  return lowered;
}

function defaultDatabase(sectionName) {
  const lowered = sectionName.toLowerCase();
  if (lowered === "postgres" || lowered === "postgresql") {
    return "postgres";
  }
  if (lowered === "starrocks" || lowered === "mysql" || lowered === "singlestore") {
    return "information_schema";
  }
  return "";
}

function vendoredDriverPath(name) {
  let host;
  let fileName;

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

function repoTmpDir(...parts) {
  const target = path.join(repoTmpRoot, ...parts);
  fs.mkdirSync(target, { recursive: true });
  return target;
}

function duckDbTestDsn(filePath) {
  return `driver=${vendoredDriverPath("duckdb")};entrypoint=duckdb_adbc_init;path=${filePath}`;
}

function removeFileIfExists(filePath) {
  fs.rmSync(filePath, { force: true });
}

function uniqueIdentifier(prefix) {
  return `${prefix}_${crypto.randomUUID().replace(/-/g, "").slice(0, 8)}`;
}

async function executeNonQuery(connection, sql) {
  const resultSet = await connection.execute(sql);
  await resultSet.close();
}

function readResultSetValues(resultSet, columnIndex) {
  const values = [];
  for (let rowIndex = 0; rowIndex < resultSet.rowCount; rowIndex += 1) {
    values.push(resultSet.value(rowIndex, columnIndex));
  }
  return values;
}

function assertNonEmptyValue(value, label) {
  assert.equal(typeof value, "string", `${label} should be returned as text`);
  assert.ok(value.length > 0, `${label} should not be empty`);
}

function assertHexValue(value, label) {
  if (Buffer.isBuffer(value)) {
    assert.ok(value.length > 0, `${label} should not be empty`);
    return;
  }

  assert.equal(typeof value, "string", `${label} should be returned as bytes or hexadecimal text`);
  assert.ok(value.length > 0, `${label} should not be empty`);
  assert.equal(value.length % 2, 0, `${label} should contain an even number of hex characters`);
  assert.match(value, /^[0-9a-f]+$/i, `${label} should be hexadecimal`);
}

function assertBooleanValue(value) {
  assert.equal(typeof value, "boolean", `unexpected boolean value: ${value}`);
}

function assertColumnMetadata(columns, expectedColumns) {
  assert.equal(columns.length, expectedColumns.length, `expected ${expectedColumns.length} columns, got ${columns.length}`);
  for (let index = 0; index < expectedColumns.length; index += 1) {
    const actual = columns[index];
    const expected = expectedColumns[index];
    assert.equal(actual.name, expected.name, `column ${index} name mismatch`);
    const expectedTypes = Array.isArray(expected.type) ? expected.type : [expected.type];
    assert.ok(expectedTypes.includes(actual.columnType), `column ${actual.name} type mismatch: got ${actual.columnType}, expected one of ${expectedTypes.join(", ")}`);
  }
}

async function assertTypeCoverage(connection, typeCoverage, assertValues) {
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

module.exports = {
  bindingLoadError,
  bindingModule,
  loadTarget,
  shouldRunSection,
  vendoredDriverPath,
  repoTmpDir,
  duckDbTestDsn,
  removeFileIfExists,
  uniqueIdentifier,
  executeNonQuery,
  readResultSetValues,
  assertNonEmptyValue,
  assertHexValue,
  assertBooleanValue,
  assertColumnMetadata,
  assertTypeCoverage,
};