import aqDatabase = require("./src/index");

const manager = new aqDatabase.ConnectionManager(null);
const driver: keyof typeof aqDatabase.DRIVER_KINDS = "adbc";

const connection = manager.connectSync(driver, "driver=stub");
const connectionPromise: Promise<aqDatabase.Connection> = manager.connect(driver, "driver=stub");

const resultSet = connection.executeSync("select 1");
const resultSetPromise: Promise<aqDatabase.ResultSet> = connection.execute("select 1");
const cursorPromise: Promise<aqDatabase.Cursor> = connection.cursor("select 1");
const isHealthy: Promise<boolean> = connection.test();
const catalogs: Promise<aqDatabase.ResultSet> = connection.getCatalogs();
const tables: Promise<aqDatabase.ResultSet> = connection.getTables(null, "main");
const namespaceAccess: Promise<aqDatabase.NamespaceAccess> = connection.inspectNamespaceAccess(null, "main");

const firstColumn: aqDatabase.ColumnMetadata = resultSet.columns[0];
const cellValue = resultSet.value(0, 0);
const qualifiedName = resultSet.tableQualifiedName(0);
const role: aqDatabase.QualifiedNamePartRole = aqDatabase.QUALIFIED_NAME_PART_ROLES.OBJECT;
const part = new aqDatabase.QualifiedNamePart(role, "records");
const qualifiedNameText: string = qualifiedName.toString();
const resolvedLibraryPath: string = aqDatabase.resolveLibraryPath(null);

void connectionPromise;
void resultSetPromise;
void cursorPromise;
void isHealthy;
void catalogs;
void tables;
void namespaceAccess;
void firstColumn;
void part;
void qualifiedNameText;
void resolvedLibraryPath;

if (typeof cellValue === "bigint") {
  const bigintValue: bigint = cellValue;
  void bigintValue;
}

if (Buffer.isBuffer(cellValue)) {
  const binaryValue: Buffer = cellValue;
  void binaryValue;
}
