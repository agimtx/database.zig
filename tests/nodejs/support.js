const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const repoRoot = path.resolve(__dirname, "../..");
const defaultEnvFile = path.join(repoRoot, ".env");
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

async function runPostgresLifecycleTest(target) {
  const databaseName = uniqueIdentifier("aq_pg");
  const tableName = uniqueIdentifier("records");
  const missingDatabase = uniqueIdentifier("missing_db");
  const manager = new bindingModule.ConnectionManager();

  try {
    await assert.rejects(
      manager.connect(target.driver, target.dsn(missingDatabase)),
      (error) => {
        assert.match(error.message, new RegExp(missingDatabase));
        return true;
      },
    );

    const adminConnection = await manager.connect(target.driver, target.dsn());
    try {
      await executeNonQuery(adminConnection, `create database ${databaseName}`);

      const databaseConnection = await manager.connect(target.driver, target.dsn(databaseName));
      try {
        await executeNonQuery(databaseConnection, `create table ${tableName} (id bigint primary key, value text not null)`);
        await executeNonQuery(databaseConnection, `insert into ${tableName} (id, value) values (1, 'alpha'), (2, 'beta')`);

        assert.equal(await databaseConnection.test(), true);

        const resultSet = await databaseConnection.execute(`select id, value from ${tableName} order by id`);
        try {
          assert.equal(resultSet.rowCount, 2);
          assert.equal(resultSet.value(0, 1), "alpha");
          assert.equal(resultSet.value(1, 1), "beta");
        } finally {
          await resultSet.close();
        }

        const missingTable = uniqueIdentifier("missing");
        await assert.rejects(
          databaseConnection.execute(`select * from ${missingTable}`),
          (error) => {
            assert.match(error.message, new RegExp(missingTable));
            return true;
          },
        );

        const missingColumn = uniqueIdentifier("missing_column");
        await assert.rejects(
          databaseConnection.execute(`select ${missingColumn} from ${tableName}`),
          (error) => {
            assert.match(error.message, new RegExp(missingColumn));
            return true;
          },
        );

        const databasesResult = await databaseConnection.getDatabases();
        try {
          assert.ok(readResultSetValues(databasesResult, 0).includes(databaseName));
        } finally {
          await databasesResult.close();
        }

        const tablesResult = await databaseConnection.getTables(null, "public");
        try {
          assert.ok(readResultSetValues(tablesResult, 2).includes(tableName));
        } finally {
          await tablesResult.close();
        }
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

async function runStarRocksLifecycleTest(target) {
  const databaseName = uniqueIdentifier("aq_sr");
  const tableName = uniqueIdentifier("records");
  const missingDatabase = uniqueIdentifier("missing_db");
  const manager = new bindingModule.ConnectionManager();

  try {
    await assert.rejects(
      manager.connect(target.driver, target.dsn(missingDatabase)),
      (error) => {
        assert.match(error.message, new RegExp(missingDatabase));
        return true;
      },
    );

    const adminConnection = await manager.connect(target.driver, target.dsn());
    try {
      await executeNonQuery(adminConnection, `create database if not exists ${databaseName}`);

      const databaseConnection = await manager.connect(target.driver, target.dsn(databaseName));
      try {
        await executeNonQuery(
          databaseConnection,
          `create table ${tableName} (` +
            "id bigint not null, " +
            "value string not null" +
          `) duplicate key(id) distributed by hash(id) buckets 1 properties (\"replication_num\" = \"1\")`,
        );
        await executeNonQuery(databaseConnection, `insert into ${tableName} (id, value) values (1, 'alpha'), (2, 'beta')`);

        assert.equal(await databaseConnection.test(), true);

        const resultSet = await databaseConnection.execute(`select id, value from ${tableName} order by id`);
        try {
          assert.equal(resultSet.rowCount, 2);
          assert.equal(resultSet.value(0, 1), "alpha");
          assert.equal(resultSet.value(1, 1), "beta");
        } finally {
          await resultSet.close();
        }

        const missingTable = uniqueIdentifier("missing");
        await assert.rejects(
          databaseConnection.execute(`select * from ${missingTable}`),
          (error) => {
            assert.match(error.message, new RegExp(missingTable));
            return true;
          },
        );

        const missingColumn = uniqueIdentifier("missing_column");
        await assert.rejects(
          databaseConnection.execute(`select ${missingColumn} from ${tableName}`),
          (error) => {
            assert.match(error.message, new RegExp(missingColumn));
            return true;
          },
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
        } finally {
          await tablesResult.close();
        }
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

function registerDatabaseBindingTest(sectionName) {
  const target = loadTarget(sectionName);
  const skipReason = bindingLoadError
    ? `node binding dependencies are not available: ${bindingLoadError.message}`
    : !shouldRunSection(sectionName)
      ? `DATABASE_ZIG_TEST_SECTION is filtering out ${sectionName}`
      : target.skip;

  test(`test_${sectionName}`, { skip: skipReason }, async () => {
    if (sectionName === "postgres") {
      await runPostgresLifecycleTest(target);
      return;
    }

    if (sectionName === "starrocks") {
      await runStarRocksLifecycleTest(target);
      return;
    }

    throw new Error(`unsupported database lifecycle test: ${sectionName}`);
  });
}

module.exports = {
  registerDatabaseBindingTest,
};