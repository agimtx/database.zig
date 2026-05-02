/// <reference types="node" />

declare namespace aqDatabase {
  const DRIVER_KINDS: {
    readonly adbc: 1;
  };

  type DriverName = keyof typeof DRIVER_KINDS;
  type DriverKindCode = (typeof DRIVER_KINDS)[DriverName];

  const COLUMN_TYPES: {
    readonly UNKNOWN: 0;
    readonly BOOLEAN: 1;
    readonly INT64: 2;
    readonly FLOAT64: 3;
    readonly TEXT: 4;
    readonly BINARY: 5;
    readonly DECIMAL: 6;
    readonly TIMESTAMP: 7;
    readonly JSON: 8;
    readonly DATE: 9;
    readonly TIME: 10;
    readonly INTERVAL: 11;
    readonly UUID: 12;
    readonly ARRAY: 13;
    readonly MAP: 14;
    readonly STRUCT: 15;
    readonly INT8: 16;
    readonly UINT8: 17;
    readonly INT16: 18;
    readonly UINT16: 19;
    readonly INT32: 20;
    readonly UINT32: 21;
    readonly UINT64: 22;
    readonly FLOAT16: 23;
    readonly FLOAT32: 24;
    readonly DURATION: 25;
  };

  type ColumnType = (typeof COLUMN_TYPES)[keyof typeof COLUMN_TYPES];

  const QUALIFIED_NAME_PART_ROLES: {
    readonly CATALOG: 0;
    readonly DATABASE: 1;
    readonly SCHEMA: 2;
    readonly DATASET: 3;
    readonly NAMESPACE: 4;
    readonly OBJECT: 5;
  };

  type QualifiedNamePartRole = (typeof QUALIFIED_NAME_PART_ROLES)[keyof typeof QUALIFIED_NAME_PART_ROLES];

  interface JsonObject {
    [key: string]: JsonValue;
  }

  interface JsonArray extends Array<JsonValue> {}

  type JsonValue = string | number | boolean | null | JsonObject | JsonArray;
  type ResultValue = string | number | boolean | bigint | Buffer | null | JsonObject | JsonArray;

  interface ColumnMetadata {
    name: string;
    rawType: string | null;
    columnType: ColumnType;
    nullable: boolean;
  }

  class QualifiedNamePart {
    constructor(role: QualifiedNamePartRole, value: string);

    role: QualifiedNamePartRole;
    value: string;
  }

  class QualifiedName {
    constructor(parts: QualifiedNamePart[], formatted: string);

    parts: QualifiedNamePart[];
    formatted: string;
    toString(): string;
  }

  class NamespaceAccess {
    constructor(
      canGetSchema: boolean,
      hasCatalogAccess: boolean,
      hasNamespaceAccess: boolean,
      namespaceRole: QualifiedNamePartRole,
      qualifiedName: QualifiedName,
    );

    canGetSchema: boolean;
    hasCatalogAccess: boolean;
    hasNamespaceAccess: boolean;
    namespaceRole: QualifiedNamePartRole;
    qualifiedName: QualifiedName;
  }

  class ConnectionManager {
    constructor(libraryPath?: string | null);

    connectSync(driver: DriverName, dsn: string): Connection;
    connect(driver: DriverName, dsn: string): Promise<Connection>;
    openSync(driver: DriverName, dsn: string): number;
    open(driver: DriverName, dsn: string): Promise<number>;
    closeConnectionSync(connectionId: number): void;
    closeConnection(connectionId: number): Promise<void>;
    disposeSync(): void;
    dispose(): Promise<void>;
  }

  class Connection {
    constructor(manager: ConnectionManager, id: number, driver: DriverName, dsn: string);

    manager: ConnectionManager;
    id: number;
    driver: DriverName;
    dsn: string;
    executeSync(sql: string): ResultSet;
    execute(sql: string): Promise<ResultSet>;
    testSync(): boolean;
    test(): Promise<boolean>;
    getCatalogsSync(): ResultSet;
    getCatalogs(): Promise<ResultSet>;
    getDatabasesSync(): ResultSet;
    getDatabases(): Promise<ResultSet>;
    getTablesSync(catalog?: string | null, database?: string | null): ResultSet;
    getTables(catalog?: string | null, database?: string | null): Promise<ResultSet>;
    inspectNamespaceAccessSync(catalog?: string | null, database?: string | null): NamespaceAccess;
    inspectNamespaceAccess(catalog?: string | null, database?: string | null): Promise<NamespaceAccess>;
    cursorSync(sql: string): Cursor;
    cursor(sql: string): Promise<Cursor>;
    closeSync(): void;
    close(): Promise<void>;
  }

  class ResultSet {
    constructor(manager: ConnectionManager, id: number);

    manager: ConnectionManager;
    id: number;
    readonly rowCount: number;
    readonly affectedRows: number;
    readonly columns: ColumnMetadata[];
    value(rowIndex: number, columnIndex: number): ResultValue;
    tableQualifiedName(rowIndex: number): QualifiedName;
    closeSync(): void;
    close(): Promise<void>;
  }

  class Cursor {
    constructor(manager: ConnectionManager, id: number);

    manager: ConnectionManager;
    id: number;
    readonly columns: ColumnMetadata[];
    next(): boolean;
    closeSync(): void;
    close(): Promise<void>;
  }

  function buildDsn(sectionName: string, config: Record<string, string>, databaseOverride?: string): string;
  function resolveLibraryPath(explicitPath?: string | null): string;
}

declare const aqDatabase: {
  buildDsn: typeof aqDatabase.buildDsn;
  COLUMN_TYPES: typeof aqDatabase.COLUMN_TYPES;
  Connection: typeof aqDatabase.Connection;
  ConnectionManager: typeof aqDatabase.ConnectionManager;
  Cursor: typeof aqDatabase.Cursor;
  DRIVER_KINDS: typeof aqDatabase.DRIVER_KINDS;
  NamespaceAccess: typeof aqDatabase.NamespaceAccess;
  QualifiedName: typeof aqDatabase.QualifiedName;
  QualifiedNamePart: typeof aqDatabase.QualifiedNamePart;
  QUALIFIED_NAME_PART_ROLES: typeof aqDatabase.QUALIFIED_NAME_PART_ROLES;
  ResultSet: typeof aqDatabase.ResultSet;
  resolveLibraryPath: typeof aqDatabase.resolveLibraryPath;
};

export = aqDatabase;