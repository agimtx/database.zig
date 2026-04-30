const assert = require("node:assert/strict");
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
    dsn: buildDsn(resolvedSectionName, section),
  };
}

function buildDsn(sectionName, config) {
  if (config.dsn) {
    return config.dsn;
  }

  const scheme = config.scheme || defaultScheme(sectionName);
  const host = config.host || "127.0.0.1";
  const port = config.port ? `:${config.port}` : "";
  const username = config.user || "";
  const password = Object.prototype.hasOwnProperty.call(config, "password") ? config.password : null;
  const database = config.database || defaultDatabase(sectionName);

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

function registerDatabaseBindingTest(sectionName) {
  const target = loadTarget(sectionName);
  const skipReason = bindingLoadError
    ? `node binding dependencies are not available: ${bindingLoadError.message}`
    : !shouldRunSection(sectionName)
      ? `DATABASE_ZIG_TEST_SECTION is filtering out ${sectionName}`
      : target.skip;

  test(`test_${sectionName}`, { skip: skipReason }, async () => {
    const manager = new bindingModule.ConnectionManager();
    try {
      const connection = await manager.connect(target.driver, target.dsn);
      try {
        const resultSet = await connection.execute(testSql);
        try {
          assert.equal(resultSet.rowCount, 2);
          assert.equal(resultSet.affectedRows, 2);

          const columns = resultSet.columns;
          assert.equal(columns.length, 2);
          assert.equal(columns[0].name, "id");
          assert.equal(columns[1].name, "value");
        } finally {
          await resultSet.close();
        }

        const cursor = await connection.cursor(testSql);
        try {
          const columns = cursor.columns;
          assert.equal(columns.length, 2);

          let seenRows = 0;
          while (cursor.next()) {
            seenRows += 1;
          }
          assert.equal(seenRows, 2);
        } finally {
          await cursor.close();
        }
      } finally {
        await connection.close();
      }
    } finally {
      await manager.dispose();
    }
  });
}

module.exports = {
  registerDatabaseBindingTest,
};