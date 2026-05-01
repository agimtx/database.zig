const assert = require("node:assert/strict");
const test = require("node:test");

const { bindingModule } = require("./support.js");

class FakeManager {
	constructor(columnType, rawValue) {
		this.columns = [{ name: "value", columnType, nullable: true }];
		this.rawValue = rawValue;
	}

	_resultSetColumns() {
		return this.columns;
	}

	_resultSetValue() {
		return this.rawValue;
	}
}

function convert(columnType, rawValue) {
	const resultSet = new bindingModule.ResultSet(new FakeManager(columnType, rawValue), 1);
	return resultSet.value(0, 0);
}

test("node binding returns typed table qualified names", () => {
	const manager = new FakeManager(bindingModule.COLUMN_TYPES.TEXT, "ignored");
	manager._resultSetTableQualifiedName = () => new bindingModule.QualifiedName([
		new bindingModule.QualifiedNamePart(bindingModule.QUALIFIED_NAME_PART_ROLES.DATABASE, "main"),
		new bindingModule.QualifiedNamePart(bindingModule.QUALIFIED_NAME_PART_ROLES.OBJECT, "records"),
	], "main.records");

	const qualifiedName = new bindingModule.ResultSet(manager, 1).tableQualifiedName(0);
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

test("node binding converts booleans", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.BOOLEAN, "true"), true);
	assert.equal(convert(bindingModule.COLUMN_TYPES.BOOLEAN, "0"), false);
});

test("node binding converts int64 to bigint", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.INT64, "42"), 42n);
});

test("node binding converts int32 to number", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.INT32, "42"), 42);
});

test("node binding converts uint64 to bigint", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.UINT64, "42"), 42n);
});

test("node binding converts float64 to number", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.FLOAT64, "3.5"), 3.5);
});

test("node binding converts float32 to number", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.FLOAT32, "3.5"), 3.5);
});

test("node binding converts binary to buffer", () => {
	assert.deepEqual(convert(bindingModule.COLUMN_TYPES.BINARY, "0102ff"), Buffer.from([0x01, 0x02, 0xff]));
});

test("node binding converts json to objects", () => {
	assert.deepEqual(convert(bindingModule.COLUMN_TYPES.JSON, '{"enabled":true,"count":1}'), { enabled: true, count: 1 });
});

test("node binding converts arrays to arrays", () => {
	assert.deepEqual(convert(bindingModule.COLUMN_TYPES.ARRAY, "[1,2,3]"), [1, 2, 3]);
});

test("node binding keeps decimals as strings", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.DECIMAL, "123.45"), "123.45");
});

test("node binding preserves null", () => {
	assert.equal(convert(bindingModule.COLUMN_TYPES.TEXT, null), null);
});