const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const {
	bindingLoadError,
	bindingModule,
	shouldRunSection,
	vendoredDriverPath,
	repoTmpDir,
	duckDbTestDsn,
	removeFileIfExists,
	uniqueIdentifier,
	readResultSetValues,
	findResultSetRowIndex,
	assertBooleanValue,
	assertColumnMetadata,
	assertTableQualifiedName,
	assertTypeCoverage,
} = require("./support.js");

function buildDuckDbTypeCoverageCase(tableName) {
	return {
		metadataDatabase: "main",
		createTableSql:
			`create table ${tableName} (` +
			"id bigint primary key, " +
			"bool_value boolean not null, " +
			"int_value bigint not null, " +
			"float_value double not null, " +
			"text_value varchar not null, " +
			"date_value date not null, " +
			"time_value time not null, " +
			"timestamp_value timestamp not null" +
			")",
		insertSql:
			`insert into ${tableName} (` +
			"id, bool_value, int_value, float_value, text_value, date_value, time_value, timestamp_value" +
			") values (" +
			"1, true, 42, 3.5, 'alpha', date '2024-01-02', time '03:04:05', timestamp '2024-01-02 03:04:05'" +
			")",
		selectSql:
			`select id, bool_value, int_value, float_value, text_value, date_value, time_value, timestamp_value from ${tableName} order by id`,
		expectedColumns: [
			{ name: "id", type: bindingModule.COLUMN_TYPES.INT64 },
			{ name: "bool_value", type: bindingModule.COLUMN_TYPES.BOOLEAN },
			{ name: "int_value", type: bindingModule.COLUMN_TYPES.INT64 },
			{ name: "float_value", type: bindingModule.COLUMN_TYPES.FLOAT64 },
			{ name: "text_value", type: bindingModule.COLUMN_TYPES.TEXT },
			{ name: "date_value", type: bindingModule.COLUMN_TYPES.DATE },
			{ name: "time_value", type: bindingModule.COLUMN_TYPES.TIME },
			{ name: "timestamp_value", type: bindingModule.COLUMN_TYPES.TIMESTAMP },
		],
	};
}

function assertDuckDbTypeCoverageValues(resultSet) {
	assert.equal(resultSet.value(0, 0), 1n);
	assertBooleanValue(resultSet.value(0, 1));
	assert.equal(resultSet.value(0, 2), 42n);
	assert.equal(resultSet.value(0, 3), 3.5);
	assert.equal(resultSet.value(0, 4), "alpha");
	assert.equal(resultSet.value(0, 5), "2024-01-02");
	assert.match(resultSet.value(0, 6), /^03:04:05(?:\.\d+)?$/);
	assert.match(resultSet.value(0, 7), /^2024-01-02T03:04:05(?:\.\d+)?$/);
}

async function assertDuckDbAdditionalTypeCoverage(connection) {
	const resultSet = await connection.execute(
		"select " +
		"cast(123.45 as decimal(10, 2)) as decimal_value, " +
		"'0102ff'::blob as binary_value, " +
		"'550e8400-e29b-41d4-a716-446655440000'::uuid as uuid_value, " +
		"json('{\"enabled\":true,\"count\":1}') as json_value, " +
		"interval '1 day 2 seconds' as interval_value, " +
		"[1,2,3] as array_value, " +
		"{'name': 'alpha', 'enabled': true} as struct_value, " +
		"map(['a','b'], [1,2]) as map_value, " +
		"'alpha'::enum ('alpha', 'beta') as enum_value, " +
		"170141183460469231731687303715884105727::hugeint as hugeint_value, " +
		"18446744073709551615::ubigint as ubigint_value, " +
		"timestamptz '2024-01-02 03:04:05+02' as timestamptz_value",
	);
	try {
		assertColumnMetadata(resultSet.columns, [
			{ name: "decimal_value", type: bindingModule.COLUMN_TYPES.DECIMAL },
			{ name: "binary_value", type: bindingModule.COLUMN_TYPES.BINARY },
			{ name: "uuid_value", type: bindingModule.COLUMN_TYPES.TEXT },
			{ name: "json_value", type: bindingModule.COLUMN_TYPES.TEXT },
			{ name: "interval_value", type: bindingModule.COLUMN_TYPES.INTERVAL },
			{ name: "array_value", type: bindingModule.COLUMN_TYPES.ARRAY },
			{ name: "struct_value", type: bindingModule.COLUMN_TYPES.STRUCT },
			{ name: "map_value", type: bindingModule.COLUMN_TYPES.MAP },
			{ name: "enum_value", type: bindingModule.COLUMN_TYPES.TEXT },
			{ name: "hugeint_value", type: bindingModule.COLUMN_TYPES.DECIMAL },
			{ name: "ubigint_value", type: bindingModule.COLUMN_TYPES.UINT64 },
			{ name: "timestamptz_value", type: bindingModule.COLUMN_TYPES.TIMESTAMP },
		]);
		assert.ok(resultSet.columns.every((column) => column.rawType === null));
		assert.equal(resultSet.value(0, 0), "123.45");
		assert.deepEqual(resultSet.value(0, 1), Buffer.from("0102ff"));
		assert.equal(resultSet.value(0, 2), "550e8400-e29b-41d4-a716-446655440000");
		assert.equal(resultSet.value(0, 3), '{"enabled":true,"count":1}');
		assert.equal(resultSet.value(0, 4), "P0M1DT00:00:02.000000000");
		assert.deepEqual(resultSet.value(0, 5), [1, 2, 3]);
		assert.deepEqual(resultSet.value(0, 6), { name: "alpha", enabled: true });
		assert.deepEqual(resultSet.value(0, 7), [{ key: "a", value: 1 }, { key: "b", value: 2 }]);
		assert.equal(resultSet.value(0, 8), "alpha");
		assert.equal(resultSet.value(0, 9), "170141183460469231731687303715884105727");
		assert.equal(resultSet.value(0, 10), 18446744073709551615n);
		assert.equal(resultSet.value(0, 11), "2024-01-02T01:04:05.000000");
	} finally {
		await resultSet.close();
	}
}

function isDuckDbRuntimeUnavailable(error) {
	return error instanceof Error && (error.message.includes("Could not load") || error.message.includes("Library not loaded"));
}

async function runDuckDbLifecycleTest() {
	const databasePath = path.join(repoTmpDir("duckdb"), `${uniqueIdentifier("aq_duckdb")}.duckdb`);
	const tableName = uniqueIdentifier("records");
	const dsn = duckDbTestDsn(databasePath);
	const manager = new bindingModule.ConnectionManager();

	removeFileIfExists(databasePath);
	try {
		let connection;
		try {
			connection = await manager.connect("adbc", dsn);
		} catch (error) {
			if (isDuckDbRuntimeUnavailable(error)) {
				return error.message;
			}
			throw error;
		}
		try {
			assert.equal(await connection.test(), true);

			const typeCoverage = await assertTypeCoverage(connection, buildDuckDbTypeCoverageCase(tableName), assertDuckDbTypeCoverageValues);
			await assertDuckDbAdditionalTypeCoverage(connection);

			const missingTable = uniqueIdentifier("missing");
			await assert.rejects(
				connection.execute(`select * from ${missingTable}`),
				(error) => {
					assert.match(error.message, new RegExp(missingTable));
					return true;
				},
			);

			const missingColumn = uniqueIdentifier("missing_column");
			await assert.rejects(
				connection.execute(`select ${missingColumn} from ${tableName}`),
				(error) => {
					assert.match(error.message, new RegExp(missingColumn));
					return true;
				},
			);

			const tablesResult = await connection.getTables(null, "main");
			try {
				assert.ok(readResultSetValues(tablesResult, 2).includes(tableName));
				assert.ok(readResultSetValues(tablesResult, 1).includes(typeCoverage.metadataDatabase));
				assertTableQualifiedName(tablesResult, findResultSetRowIndex(tablesResult, 2, tableName));
			} finally {
				await tablesResult.close();
			}

			const databasesResult = await connection.getDatabases();
			try {
				assert.ok(readResultSetValues(databasesResult, 0).includes("main"));
			} finally {
				await databasesResult.close();
			}
		} finally {
			await connection.close();
		}

		assert.equal(fs.existsSync(databasePath), true);

		const reopened = await manager.connect("adbc", dsn);
		try {
			const persisted = await reopened.execute(`select count(*) as row_count from ${tableName}`);
			try {
				assertColumnMetadata(persisted.columns, [{ name: "row_count", type: bindingModule.COLUMN_TYPES.INT64 }]);
				assert.equal(persisted.value(0, 0), 1n);
			} finally {
				await persisted.close();
			}
		} finally {
			await reopened.close();
		}
	} finally {
		await manager.dispose();
		removeFileIfExists(databasePath);
	}

	return null;
}

const duckdbDriverPath = vendoredDriverPath("duckdb");
const skipReason = bindingLoadError
	? `node binding dependencies are not available: ${bindingLoadError.message}`
	: !shouldRunSection("duckdb")
		? "DATABASE_ZIG_TEST_SECTION is filtering out duckdb"
		: !fs.existsSync(duckdbDriverPath)
			? `duckdb driver not found: ${duckdbDriverPath}`
			: null;

const duckDbTestFn = async (t) => {
	const runtimeSkipReason = await runDuckDbLifecycleTest();
	if (runtimeSkipReason) {
		t.skip(runtimeSkipReason);
	}
};

if (skipReason) {
	test("test_duckdb", { skip: skipReason }, duckDbTestFn);
} else {
	test("test_duckdb", duckDbTestFn);
}