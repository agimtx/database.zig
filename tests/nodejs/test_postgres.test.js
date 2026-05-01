const assert = require("node:assert/strict");
const test = require("node:test");

const {
	bindingLoadError,
	bindingModule,
	loadTarget,
	shouldRunSection,
	uniqueIdentifier,
	executeNonQuery,
	readResultSetValues,
	assertNonEmptyValue,
	assertHexValue,
	assertBooleanValue,
	assertColumnMetadata,
	assertTypeCoverage,
} = require("./support.js");

const target = loadTarget("postgres");

function buildPostgresTypeCoverageCase(tableName) {
	return {
		metadataDatabase: "public",
		createTableSql:
			`create table ${tableName} (` +
			"id bigint primary key, " +
			"bool_value boolean not null, " +
			"int_value bigint not null, " +
			"float_value double precision not null, " +
			"text_value text not null, " +
			"binary_value bytea not null, " +
			"decimal_value numeric(10, 2) not null, " +
			"date_value date not null, " +
			"time_value time not null, " +
			"interval_value interval not null, " +
			"uuid_value uuid not null, " +
			"xml_value xml not null, " +
			"array_value integer[] not null, " +
			"inet_value inet not null, " +
			"timestamp_value timestamp not null, " +
			"json_value jsonb not null" +
			")",
		insertSql:
			`insert into ${tableName} (` +
			"id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value" +
			") values (" +
			"1, true, 42, 3.5, 'alpha', decode('0102ff', 'hex'), 123.45, date '2024-01-02', time '03:04:05', interval '1 day 2 seconds', '550e8400-e29b-41d4-a716-446655440000'::uuid, xmlparse(document '<a>1</a>'), array[1,2,3], inet '127.0.0.1', timestamp '2024-01-02 03:04:05', '{\"enabled\":true,\"count\":1}'::jsonb" +
			")",
		selectSql:
			`select id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value from ${tableName} order by id`,
		expectedColumns: [
			{ name: "id", type: bindingModule.COLUMN_TYPES.INT64 },
			{ name: "bool_value", type: bindingModule.COLUMN_TYPES.BOOLEAN },
			{ name: "int_value", type: bindingModule.COLUMN_TYPES.INT64 },
			{ name: "float_value", type: bindingModule.COLUMN_TYPES.FLOAT64 },
			{ name: "text_value", type: bindingModule.COLUMN_TYPES.TEXT },
			{ name: "binary_value", type: bindingModule.COLUMN_TYPES.BINARY },
			{ name: "decimal_value", type: [bindingModule.COLUMN_TYPES.DECIMAL, bindingModule.COLUMN_TYPES.TEXT] },
			{ name: "date_value", type: bindingModule.COLUMN_TYPES.DATE },
			{ name: "time_value", type: bindingModule.COLUMN_TYPES.TIME },
			{ name: "interval_value", type: bindingModule.COLUMN_TYPES.INTERVAL },
			{ name: "uuid_value", type: bindingModule.COLUMN_TYPES.UUID, rawType: "uuid" },
			{ name: "xml_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "xml" },
			{ name: "array_value", type: bindingModule.COLUMN_TYPES.ARRAY },
			{ name: "inet_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "inet" },
			{ name: "timestamp_value", type: bindingModule.COLUMN_TYPES.TIMESTAMP },
			{ name: "json_value", type: [bindingModule.COLUMN_TYPES.JSON, bindingModule.COLUMN_TYPES.TEXT] },
		],
	};
}

function assertPostgresTypeCoverageValues(resultSet) {
	const columns = resultSet.columns;
	assert.equal(resultSet.value(0, 0), 1n);
	assertBooleanValue(resultSet.value(0, 1));
	assert.equal(resultSet.value(0, 2), 42n);
	assert.equal(resultSet.value(0, 3), 3.5);
	assert.equal(resultSet.value(0, 4), "alpha");
	assert.deepEqual(resultSet.value(0, 5), Buffer.from([0x01, 0x02, 0xff]));
	assert.equal(resultSet.value(0, 6), "123.45");
	assert.equal(resultSet.value(0, 7), "2024-01-02");
	assert.match(resultSet.value(0, 8), /^03:04:05(?:\.\d+)?$/);
	assert.match(resultSet.value(0, 9), /^P0M1DT00:00:02(?:\.0+)?$/);
	assert.equal(resultSet.value(0, 10), "550e8400-e29b-41d4-a716-446655440000");
	assert.equal(resultSet.value(0, 11), "<a>1</a>");
	assert.deepEqual(resultSet.value(0, 12), [1, 2, 3]);
	assert.equal(resultSet.value(0, 13), "127.0.0.1");
	assert.match(resultSet.value(0, 14), /^2024-01-02T03:04:05(?:\.\d+)?$/);
	if (columns[15].columnType === bindingModule.COLUMN_TYPES.JSON) {
		assert.deepEqual(resultSet.value(0, 15), { enabled: true, count: 1 });
	} else {
		assert.match(resultSet.value(0, 15), /"enabled"/);
	}
}

const POSTGRES_ADDITIONAL_TYPES_SQL =
	"select " +
	"cast(12.34 as money) as money_value, " +
	"cast(B'1010' as bit(4)) as bit_value, " +
	"cast(B'101011' as varbit) as varbit_value, " +
	"'10.0.0.0/24'::cidr as cidr_value, " +
	"'08:00:2b:01:02:03'::macaddr as macaddr_value, " +
	"'08:00:2b:01:02:03:04:05'::macaddr8 as macaddr8_value, " +
	"to_tsvector('english', 'hello world') as tsv_value, " +
	"to_tsquery('english', 'hello & world') as tsq_value, " +
	"point(1,2) as point_value, " +
	"box(point(0,0), point(1,1)) as box_value, " +
	"'int4'::regtype as regtype_value, " +
	"time with time zone '03:04:05+02' as timetz_value, " +
	"timestamptz '2024-01-02 03:04:05+02' as timestamptz_value";

const POSTGRES_RANGE_AND_SYSTEM_TYPES_SQL =
	"select " +
	"int4range(1,5) as range_value, " +
	"int4multirange(int4range(1,5), int4range(7,9)) as multirange_value, " +
	"42::oid as oid_value, " +
	"'pg_type'::regclass as regclass_value, " +
	"'(1,2)'::tid as tid_value, " +
	"'0/16B6C50'::pg_lsn as lsn_value";

async function assertPostgresAdditionalTypeCoverage(connection) {
	const enumName = uniqueIdentifier("status_enum");
	const createType = await connection.execute(`create type ${enumName} as enum ('new', 'done')`);
	await createType.close();
	try {
		const enumResult = await connection.execute(`select 'new'::${enumName} as enum_value`);
		try {
			assert.equal(enumResult.columns.length, 1);
			assert.equal(enumResult.columns[0].name, "enum_value");
			assert.equal(enumResult.columns[0].columnType, bindingModule.COLUMN_TYPES.BINARY);
			assert.deepEqual(enumResult.value(0, 0), Buffer.from("new"));
		} finally {
			await enumResult.close();
		}
	} finally {
		const dropType = await connection.execute(`drop type if exists ${enumName}`);
		await dropType.close();
	}

	const resultSet = await connection.execute(POSTGRES_ADDITIONAL_TYPES_SQL);
	try {
		assertColumnMetadata(resultSet.columns, [
			{ name: "money_value", type: bindingModule.COLUMN_TYPES.INT64 },
			{ name: "bit_value", type: bindingModule.COLUMN_TYPES.BINARY },
			{ name: "varbit_value", type: bindingModule.COLUMN_TYPES.BINARY },
			{ name: "cidr_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "cidr" },
			{ name: "macaddr_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "macaddr" },
			{ name: "macaddr8_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "macaddr8" },
			{ name: "tsv_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "tsvector" },
			{ name: "tsq_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "tsquery" },
			{ name: "point_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "point" },
			{ name: "box_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "box" },
			{ name: "regtype_value", type: bindingModule.COLUMN_TYPES.BINARY, rawType: "regtype" },
			{ name: "timetz_value", type: bindingModule.COLUMN_TYPES.TIME },
			{ name: "timestamptz_value", type: bindingModule.COLUMN_TYPES.TIMESTAMP },
		]);
		assert.equal(resultSet.value(0, 0), 1234n);
		assert.equal(resultSet.value(0, 3), "10.0.0.0/24");
		assert.equal(resultSet.value(0, 4), "08:00:2b:01:02:03");
		assert.equal(resultSet.value(0, 5), "08:00:2b:01:02:03:04:05");
		assert.equal(resultSet.value(0, 6), "'hello':1 'world':2");
		assert.equal(resultSet.value(0, 7), "'hello' & 'world'");
		assert.equal(resultSet.value(0, 8), "(1,2)");
		assert.equal(resultSet.value(0, 9), "(1,1),(0,0)");
		assert.deepEqual(resultSet.value(0, 10), Buffer.from([0x23]));
		assert.equal(resultSet.value(0, 12), "2024-01-02T01:04:05.000000");

		for (const [index, label] of [[1, "bit_value"], [2, "varbit_value"], [11, "timetz_value"]]) {
			assertHexValue(resultSet.value(0, index), label);
		}
	} finally {
		await resultSet.close();
	}

	const rangeResult = await connection.execute(POSTGRES_RANGE_AND_SYSTEM_TYPES_SQL);
	try {
		assertColumnMetadata(rangeResult.columns, [
			{ name: "range_value", type: bindingModule.COLUMN_TYPES.BINARY },
			{ name: "multirange_value", type: bindingModule.COLUMN_TYPES.BINARY },
			{ name: "oid_value", type: bindingModule.COLUMN_TYPES.INT32 },
			{ name: "regclass_value", type: bindingModule.COLUMN_TYPES.BINARY, rawType: "regclass" },
			{ name: "tid_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "tid" },
			{ name: "lsn_value", type: bindingModule.COLUMN_TYPES.UNKNOWN, rawType: "pg_lsn" },
		]);
		assert.deepEqual(rangeResult.value(0, 0), Buffer.from("0200000004000000010000000400000005", "hex"));
		assert.deepEqual(
			rangeResult.value(0, 1),
			Buffer.from("00000002000000110200000004000000010000000400000005000000110200000004000000070000000400000009", "hex"),
		);
		assert.equal(rangeResult.value(0, 2), 42);
		assert.deepEqual(rangeResult.value(0, 3), Buffer.from([0x12, 0x47]));
		assert.equal(rangeResult.value(0, 4), "(1,2)");
		assert.equal(rangeResult.value(0, 5), "0/16B6C50");
	} finally {
		await rangeResult.close();
	}

	const pseudoResult = await connection.execute("select null::anyelement as pseudo_value");
	try {
		assertColumnMetadata(pseudoResult.columns, [{ name: "pseudo_value", type: bindingModule.COLUMN_TYPES.TEXT }]);
		assert.equal(pseudoResult.value(0, 0), null);
	} finally {
		await pseudoResult.close();
	}

	await assert.rejects(
		connection.execute("select row(1, 'alpha') as row_value"),
		(error) => {
			assert.match(error.message, /internal error/i);
			return true;
		},
	);
}

async function runPostgresLifecycleTest() {
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
				assert.equal(await databaseConnection.test(), true);

				const typeCoverage = await assertTypeCoverage(databaseConnection, buildPostgresTypeCoverageCase(tableName), assertPostgresTypeCoverageValues);
				await assertPostgresAdditionalTypeCoverage(databaseConnection);

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
					if (typeCoverage.metadataDatabase !== null) {
						assert.ok(readResultSetValues(tablesResult, 1).includes(typeCoverage.metadataDatabase));
					}
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

const skipReason = bindingLoadError
	? `node binding dependencies are not available: ${bindingLoadError.message}`
	: !shouldRunSection("postgres")
		? "DATABASE_ZIG_TEST_SECTION is filtering out postgres"
		: target.skip;

test("test_postgres", { skip: skipReason }, async () => {
	await runPostgresLifecycleTest();
});