const fs = require("node:fs");
const path = require("node:path");
const ffi = require("ffi-napi");
const ref = require("ref-napi");

const DRIVER_KINDS = {
  adbc: 1,
};

const STATUS_MESSAGES = {
  1: "invalid argument",
  2: "driver not registered",
  3: "connection not found",
  4: "result set not found",
  5: "cursor not found",
  6: "column index out of bounds",
  7: "row index out of bounds",
  8: "operation not found",
  255: "internal error",
};

const COLUMN_TYPES = {
  UNKNOWN: 0,
  BOOLEAN: 1,
  INT64: 2,
  FLOAT64: 3,
  TEXT: 4,
  BINARY: 5,
  DECIMAL: 6,
  TIMESTAMP: 7,
  JSON: 8,
};

const POINTER_SIZE = ref.sizeof.pointer;
const SIZE_T_SIZE = ref.types.size_t.size;
const COLUMN_METADATA_SIZE = POINTER_SIZE + SIZE_T_SIZE + 4 + 1;
const OPERATION_RESULT_SIZE = 16;

function raiseOnStatus(status, operation) {
  if (status === 0) {
    return;
  }

  const message = STATUS_MESSAGES[status] || `unknown status=${status}`;
  throw new Error(`${operation} failed: ${message}`);
}

function readUInt64(buffer) {
  return Number(buffer.readBigUInt64LE(0));
}

function readSizeT(buffer) {
  if (SIZE_T_SIZE === 8) {
    return Number(buffer.readBigUInt64LE(0));
  }

  return buffer.readUInt32LE(0);
}

function callAsync(fn, args) {
  return new Promise((resolve, reject) => {
    fn.async(...args, (error, value) => {
      if (error) {
        reject(error);
        return;
      }

      resolve(value);
    });
  });
}

function readOperationResult(buffer) {
  return {
    state: buffer.readUInt8(0),
    status: buffer.readInt32LE(4),
    value: Number(buffer.readBigUInt64LE(8)),
  };
}

function readColumnMetadata(buffer) {
  const nameLength = SIZE_T_SIZE === 8
    ? Number(buffer.readBigUInt64LE(POINTER_SIZE))
    : buffer.readUInt32LE(POINTER_SIZE);
  const nameBuffer = ref.readPointer(buffer, 0, nameLength);
  const typeOffset = POINTER_SIZE + SIZE_T_SIZE;

  return {
    name: nameBuffer.toString("utf8"),
    columnType: buffer.readInt32LE(typeOffset),
    nullable: buffer.readUInt8(typeOffset + 4) === 1,
  };
}

function resolveLibraryPath(explicitPath) {
  if (explicitPath) {
    return explicitPath;
  }

  if (process.env.DATABASE_ZIG_LIBRARY) {
    return process.env.DATABASE_ZIG_LIBRARY;
  }

  const fileName = process.platform === "darwin"
    ? "libdatabase_zig.dylib"
    : process.platform === "win32"
      ? "database_zig.dll"
      : "libdatabase_zig.so";

  return path.resolve(__dirname, "../../../zig-out/lib", fileName);
}

class ConnectionManager {
  constructor(libraryPath) {
    const resolvedPath = resolveLibraryPath(libraryPath);
    if (!fs.existsSync(resolvedPath)) {
      throw new Error(`database.zig shared library not found: ${resolvedPath}`);
    }

    this.lib = ffi.Library(resolvedPath, {
      dbz_manager_create: ["pointer", []],
      dbz_manager_destroy: ["void", ["pointer"]],
      dbz_connection_open: ["uint64", ["pointer", "int32", "string"]],
      dbz_connection_open_async: ["uint64", ["pointer", "int32", "string"]],
      dbz_connection_close: ["int32", ["pointer", "uint64"]],
      dbz_connection_execute: ["uint64", ["pointer", "uint64", "string"]],
      dbz_connection_execute_async: ["uint64", ["pointer", "uint64", "string"]],
      dbz_result_set_close: ["int32", ["pointer", "uint64"]],
      dbz_result_set_row_count: ["int32", ["pointer", "uint64", "pointer"]],
      dbz_result_set_affected_rows: ["int32", ["pointer", "uint64", "pointer"]],
      dbz_result_set_column_count: ["int32", ["pointer", "uint64", "pointer"]],
      dbz_result_set_column_metadata: ["int32", ["pointer", "uint64", "size_t", "pointer"]],
      dbz_cursor_open: ["uint64", ["pointer", "uint64", "string"]],
      dbz_cursor_open_async: ["uint64", ["pointer", "uint64", "string"]],
      dbz_cursor_next: ["int32", ["pointer", "uint64", "pointer"]],
      dbz_cursor_close: ["int32", ["pointer", "uint64"]],
      dbz_cursor_column_count: ["int32", ["pointer", "uint64", "pointer"]],
      dbz_cursor_column_metadata: ["int32", ["pointer", "uint64", "size_t", "pointer"]],
      dbz_manager_open: ["uint64", ["pointer", "int32", "string"]],
      dbz_manager_open_async: ["uint64", ["pointer", "int32", "string"]],
      dbz_manager_close: ["int32", ["pointer", "uint64"]],
      dbz_operation_await: ["int32", ["pointer", "uint64", "pointer"]],
    });

    this.manager = this.lib.dbz_manager_create();
    if (ref.isNull(this.manager)) {
      throw new Error("failed to create database.zig connection manager");
    }
  }

  connectSync(driver, dsn) {
    const driverKind = DRIVER_KINDS[driver];
    if (driverKind === undefined) {
      throw new Error(`unsupported driver: ${driver}`);
    }

    const connectionId = this.lib.dbz_connection_open(this.manager, driverKind, dsn);
    if (connectionId === 0 || connectionId === 0n) {
      throw new Error("dbz_connection_open returned 0");
    }

    return new Connection(this, Number(connectionId), driver, dsn);
  }

  async connect(driver, dsn) {
    const driverKind = DRIVER_KINDS[driver];
    if (driverKind === undefined) {
      throw new Error(`unsupported driver: ${driver}`);
    }

    const operationId = this.lib.dbz_connection_open_async(this.manager, driverKind, dsn);
    if (operationId === 0 || operationId === 0n) {
      throw new Error("dbz_connection_open_async returned 0");
    }

    const connectionId = await this._awaitOperationValue(Number(operationId), "dbz_connection_open_async");
    return new Connection(this, connectionId, driver, dsn);
  }

  openSync(driver, dsn) {
    return this.connectSync(driver, dsn).id;
  }

  async open(driver, dsn) {
    return (await this.connect(driver, dsn)).id;
  }

  closeConnectionSync(connectionId) {
    raiseOnStatus(this.lib.dbz_connection_close(this.manager, connectionId), "dbz_connection_close");
  }

  async closeConnection(connectionId) {
    const status = await callAsync(this.lib.dbz_connection_close, [this.manager, connectionId]);
    raiseOnStatus(status, "dbz_connection_close");
  }

  disposeSync() {
    if (this.manager && !ref.isNull(this.manager)) {
      this.lib.dbz_manager_destroy(this.manager);
      this.manager = ref.NULL;
    }
  }

  async dispose() {
    this.disposeSync();
  }

  _executeSync(connectionId, sql) {
    const resultSetId = this.lib.dbz_connection_execute(this.manager, connectionId, sql);
    if (resultSetId === 0 || resultSetId === 0n) {
      throw new Error("dbz_connection_execute returned 0");
    }

    return new ResultSet(this, Number(resultSetId));
  }

  async _execute(connectionId, sql) {
    const operationId = this.lib.dbz_connection_execute_async(this.manager, connectionId, sql);
    if (operationId === 0 || operationId === 0n) {
      throw new Error("dbz_connection_execute_async returned 0");
    }

    const resultSetId = await this._awaitOperationValue(Number(operationId), "dbz_connection_execute_async");
    return new ResultSet(this, resultSetId);
  }

  _resultSetClose(resultSetId) {
    raiseOnStatus(this.lib.dbz_result_set_close(this.manager, resultSetId), "dbz_result_set_close");
  }

  async _resultSetCloseAsync(resultSetId) {
    const status = await callAsync(this.lib.dbz_result_set_close, [this.manager, resultSetId]);
    raiseOnStatus(status, "dbz_result_set_close");
  }

  _resultSetRowCount(resultSetId) {
    const out = Buffer.alloc(8);
    raiseOnStatus(this.lib.dbz_result_set_row_count(this.manager, resultSetId, out), "dbz_result_set_row_count");
    return readUInt64(out);
  }

  _resultSetAffectedRows(resultSetId) {
    const out = Buffer.alloc(8);
    raiseOnStatus(this.lib.dbz_result_set_affected_rows(this.manager, resultSetId, out), "dbz_result_set_affected_rows");
    return readUInt64(out);
  }

  _resultSetColumns(resultSetId) {
    const countBuffer = Buffer.alloc(SIZE_T_SIZE);
    raiseOnStatus(this.lib.dbz_result_set_column_count(this.manager, resultSetId, countBuffer), "dbz_result_set_column_count");
    const count = readSizeT(countBuffer);
    const columns = [];

    for (let index = 0; index < count; index += 1) {
      const metadataBuffer = Buffer.alloc(COLUMN_METADATA_SIZE);
      raiseOnStatus(
        this.lib.dbz_result_set_column_metadata(this.manager, resultSetId, index, metadataBuffer),
        "dbz_result_set_column_metadata",
      );
      columns.push(readColumnMetadata(metadataBuffer));
    }

    return columns;
  }

  _openCursorSync(connectionId, sql) {
    const cursorId = this.lib.dbz_cursor_open(this.manager, connectionId, sql);
    if (cursorId === 0 || cursorId === 0n) {
      throw new Error("dbz_cursor_open returned 0");
    }

    return new Cursor(this, Number(cursorId));
  }

  async _openCursor(connectionId, sql) {
    const operationId = this.lib.dbz_cursor_open_async(this.manager, connectionId, sql);
    if (operationId === 0 || operationId === 0n) {
      throw new Error("dbz_cursor_open_async returned 0");
    }

    const cursorId = await this._awaitOperationValue(Number(operationId), "dbz_cursor_open_async");
    return new Cursor(this, cursorId);
  }

  _cursorNext(cursorId) {
    const out = Buffer.alloc(1);
    raiseOnStatus(this.lib.dbz_cursor_next(this.manager, cursorId, out), "dbz_cursor_next");
    return out.readUInt8(0) === 1;
  }

  _cursorClose(cursorId) {
    raiseOnStatus(this.lib.dbz_cursor_close(this.manager, cursorId), "dbz_cursor_close");
  }

  async _cursorCloseAsync(cursorId) {
    const status = await callAsync(this.lib.dbz_cursor_close, [this.manager, cursorId]);
    raiseOnStatus(status, "dbz_cursor_close");
  }

  _cursorColumns(cursorId) {
    const countBuffer = Buffer.alloc(SIZE_T_SIZE);
    raiseOnStatus(this.lib.dbz_cursor_column_count(this.manager, cursorId, countBuffer), "dbz_cursor_column_count");
    const count = readSizeT(countBuffer);
    const columns = [];

    for (let index = 0; index < count; index += 1) {
      const metadataBuffer = Buffer.alloc(COLUMN_METADATA_SIZE);
      raiseOnStatus(
        this.lib.dbz_cursor_column_metadata(this.manager, cursorId, index, metadataBuffer),
        "dbz_cursor_column_metadata",
      );
      columns.push(readColumnMetadata(metadataBuffer));
    }

    return columns;
  }

  async _awaitOperationValue(operationId, operation) {
    const resultBuffer = Buffer.alloc(OPERATION_RESULT_SIZE);
    const awaitStatus = await callAsync(this.lib.dbz_operation_await, [this.manager, operationId, resultBuffer]);
    raiseOnStatus(awaitStatus, "dbz_operation_await");

    const result = readOperationResult(resultBuffer);
    raiseOnStatus(result.status, operation);
    if (result.value === 0) {
      throw new Error(`${operation} returned 0`);
    }

    return result.value;
  }
}

class Connection {
  constructor(manager, id, driver, dsn) {
    this.manager = manager;
    this.id = id;
    this.driver = driver;
    this.dsn = dsn;
  }

  executeSync(sql) {
    return this.manager._executeSync(this.id, sql);
  }

  async execute(sql) {
    return this.manager._execute(this.id, sql);
  }

  cursorSync(sql) {
    return this.manager._openCursorSync(this.id, sql);
  }

  async cursor(sql) {
    return this.manager._openCursor(this.id, sql);
  }

  closeSync() {
    this.manager.closeConnectionSync(this.id);
  }

  async close() {
    await this.manager.closeConnection(this.id);
  }
}

class ResultSet {
  constructor(manager, id) {
    this.manager = manager;
    this.id = id;
  }

  get rowCount() {
    return this.manager._resultSetRowCount(this.id);
  }

  get affectedRows() {
    return this.manager._resultSetAffectedRows(this.id);
  }

  get columns() {
    return this.manager._resultSetColumns(this.id);
  }

  closeSync() {
    this.manager._resultSetClose(this.id);
  }

  async close() {
    await this.manager._resultSetCloseAsync(this.id);
  }
}

class Cursor {
  constructor(manager, id) {
    this.manager = manager;
    this.id = id;
  }

  get columns() {
    return this.manager._cursorColumns(this.id);
  }

  next() {
    return this.manager._cursorNext(this.id);
  }

  closeSync() {
    this.manager._cursorClose(this.id);
  }

  async close() {
    await this.manager._cursorCloseAsync(this.id);
  }
}

module.exports = {
  COLUMN_TYPES,
  Connection,
  ConnectionManager,
  Cursor,
  DRIVER_KINDS,
  ResultSet,
  resolveLibraryPath,
};
