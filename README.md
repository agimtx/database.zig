# database.zig

database.zig is a database connection management library scaffold that uses Zig as the control plane, Apache Arrow ADBC as the database access layer, and a stable C ABI for C, Python, Node.js, and Rust consumers. Zig owns lifecycle, registration, and error mapping while the target database is selected through the ADBC driver manager and connection configuration.

## Goals

- Use Zig to manage connection lifecycle, driver registration, error mapping, and the public ABI.
- Use Apache Arrow ADBC for protocol-heavy database access while keeping the control plane centralized in Zig.
- Keep the Zig-to-ADBC integration based on shared native libraries so the ADBC driver manager and vendor drivers can ship independently per operating system.
- Keep the external C ABI stable so Python and Node.js can remain thin wrappers.

## Repository Layout

```text
.
├── .github/
│   └── copilot-instructions.md
├── bindings/
│   ├── c/
│   │   └── include/
│   ├── rust/
│   │   └── src/
│   ├── nodejs/
│   │   └── src/
│   └── python/
│       └── aq_database/
├── docs/
│   └── architecture.md
├── tests/
│   ├── nodejs/
│   ├── python/
│   └── rust/
└── src/
    ├── core/
    └── ffi/
```

## Current Status

- Zig already provides a connection manager, an ADBC-backed registry surface, and exported C ABI entry points.
- Zig now defines a unified external model for connections, SQL execution, cursors, result sets, and column metadata.
- Python includes a thin ctypes-based binding scaffold.
- Node.js includes a thin ffi-napi-based binding scaffold for the public C ABI.
- Rust includes a thin dynamic-loading binding crate for the public C ABI.
- The current backend surface is a single built-in ADBC driver path selected through the public ABI.

## ADBC Connection Strings

The public API still exposes one built-in driver kind: `adbc`. Vendor selection now happens through the `dsn` value.

Use a plain URI when the repository can infer a vendored driver from the scheme:

```text
sqlite:file::memory:
postgresql://user:pass@localhost:5432/app
snowflake://account/warehouse/db/schema
```

Use an explicit semicolon-separated option string when you need to point at a specific shared library, entrypoint, or custom search path:

```text
driver=/absolute/path/to/libadbc_driver_postgresql.dylib;uri=postgresql://user:pass@localhost:5432/app
driver=/absolute/path/to/libadbc_driver_mysql.dylib;uri=mysql://user:pass@localhost:3306/app
driver=/absolute/path/to/libadbc_driver_mysql.dylib;entrypoint=AdbcDriverMySQLInit;uri=mysql://user:pass@localhost:3306/app
```

Recognized reserved keys are:

- `driver`
- `uri`
- `entrypoint`
- `additional_manifest_search_path_list`

Any other key-value pairs in the option string are forwarded to `AdbcDatabaseSetOption`.

The vendored driver set in this workspace currently covers DuckDB, SQLite, PostgreSQL, Flight SQL, Snowflake, MySQL, BigQuery, SQL Server, Redshift, Trino, Databricks, ClickHouse, Exasol, and SingleStore.

## Vendored Shared Libraries

All `adbc` connections depend on the ADBC driver manager plus one database-specific native library from `third_party/adbc/1.11.0/lib/<platform>/`.

Common ADBC dependency:

| Purpose | `.dylib` | `.so` | `.dll` |
| --- | --- | --- | --- |
| Driver manager | `libadbc_driver_manager.dylib` | `libadbc_driver_manager.so` | `adbc_driver_manager.dll` |

Database-specific native libraries:

| Database | `.dylib` | `.so` | `.dll` |
| --- | --- | --- | --- |
| DuckDB | `libduckdb.dylib` | `libduckdb.so` | `duckdb.dll` |
| SQLite | `libadbc_driver_sqlite.dylib` | `libadbc_driver_sqlite.so` | `adbc_driver_sqlite.dll` |
| PostgreSQL | `libadbc_driver_postgresql.dylib` | `libadbc_driver_postgresql.so` | `adbc_driver_postgresql.dll` |
| Flight SQL | `libadbc_driver_flightsql.dylib` | `libadbc_driver_flightsql.so` | `adbc_driver_flightsql.dll` |
| Snowflake | `libadbc_driver_snowflake.dylib` | `libadbc_driver_snowflake.so` | `adbc_driver_snowflake.dll` |
| MySQL | `libadbc_driver_mysql.dylib` | `libadbc_driver_mysql.so` | `adbc_driver_mysql.dll` |
| BigQuery | `libadbc_driver_bigquery.dylib` | `libadbc_driver_bigquery.so` | `libadbc_driver_bigquery.dll` |
| SQL Server | `libadbc_driver_mssql.dylib` | `libadbc_driver_mssql.so` | `libadbc_driver_mssql.dll` |
| Redshift | `libadbc_driver_redshift.dylib` | `libadbc_driver_redshift.so` | `libadbc_driver_redshift.dll` |
| Trino | `libadbc_driver_trino.dylib` | `libadbc_driver_trino.so` | `libadbc_driver_trino.dll` |
| Databricks | `libadbc_driver_databricks.dylib` | `libadbc_driver_databricks.so` | `libadbc_driver_databricks.dll` |
| ClickHouse | `libadbc_driver_clickhouse.dylib` | `libadbc_driver_clickhouse.so` | `libadbc_driver_clickhouse.dll` |
| Exasol | `libadbc_driver_exasol.dylib` | `libadbc_driver_exasol.so` | `libadbc_driver_exasol.dll` |
| SingleStore | `libadbc_driver_singlestore.dylib` | `libadbc_driver_singlestore.so` | `libadbc_driver_singlestore.dll` |

Notes:

- DuckDB uses DuckDB's own `libduckdb` native library instead of an Apache `libadbc_driver_*` driver package.
- On Windows, official Arrow ADBC packages use `adbc_driver_*.dll`, while several community drivers are currently vendored under `libadbc_driver_*.dll`. MySQL currently ships under both names.
- `macos-x86_64` currently includes the official `driver_manager`, `sqlite`, `postgresql`, `flightsql`, `snowflake`, and `duckdb` artifacts plus source-built Intel macOS dylibs for `mysql`, `bigquery`, `databricks`, `clickhouse`, `exasol`, and `singlestore`.
- `mssql`, `redshift`, and `trino` are currently absent on `macos-x86_64`.

## Per-Database Vendored Runtime Dependencies

The table above lists the primary database driver libraries. The lists below show the vendored non-system dynamic-library dependency closure for each database on each platform in this workspace.

### DuckDB

- `macos-arm64`: `libduckdb.dylib`, `libadbc_driver_manager.dylib`, `libicudata.75.dylib`, `libicui18n.75.dylib`, `libicuuc.75.dylib`
- `macos-x86_64`: `libduckdb.dylib`, `libadbc_driver_manager.dylib`, `libicudata.75.dylib`, `libicui18n.75.dylib`, `libicuuc.75.dylib`
- `linux-arm64`: `libduckdb.so`, `libadbc_driver_manager.so`, `libicudata.so.75`, `libicui18n.so.75`, `libicuuc.so.75`
- `linux-x86_64`: `libduckdb.so`, `libadbc_driver_manager.so`, `libicudata.so.75`, `libicui18n.so.75`, `libicuuc.so.75`
- `windows-x86_64`: `duckdb.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### SQLite

- `macos-arm64`: `libadbc_driver_sqlite.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_sqlite.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_sqlite.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_sqlite.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `adbc_driver_sqlite.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `sqlite3.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### PostgreSQL

- `macos-arm64`: `libadbc_driver_postgresql.dylib`, `libadbc_driver_manager.dylib`, `libcom_err.3.0.dylib`, `libcrypto.3.dylib`, `libgssapi_krb5.2.2.dylib`, `libk5crypto.3.1.dylib`, `libkrb5.3.3.dylib`, `libkrb5support.1.1.dylib`, `liblber.2.dylib`, `libldap.2.dylib`, `libpq.5.dylib`, `libsasl2.dylib`, `libssl.3.dylib`
- `macos-x86_64`: `libadbc_driver_postgresql.dylib`, `libadbc_driver_manager.dylib`, `libcom_err.3.0.dylib`, `libcrypto.3.dylib`, `libgssapi_krb5.2.2.dylib`, `libk5crypto.3.1.dylib`, `libkrb5.3.3.dylib`, `libkrb5support.1.1.dylib`, `liblber.2.dylib`, `libldap.2.dylib`, `libpq.5.dylib`, `libsasl2.dylib`, `libssl.3.dylib`
- `linux-arm64`: `libadbc_driver_postgresql.so`, `libadbc_driver_manager.so`, `libcom_err.so.3`, `libcrypto.so.3`, `libgssapi_krb5.so.2`, `libk5crypto.so.3`, `libkrb5.so.3`, `libkrb5support.so.0`, `liblber.so.2`, `libldap.so.2`, `libpq.so.5`, `libsasl2.so.3`, `libssl.so.3`
- `linux-x86_64`: `libadbc_driver_postgresql.so`, `libadbc_driver_manager.so`, `libcom_err.so.3`, `libcrypto.so.3`, `libgssapi_krb5.so.2`, `libk5crypto.so.3`, `libkrb5.so.3`, `libkrb5support.so.0`, `liblber.so.2`, `libldap.so.2`, `libpq.so.5`, `libsasl2.so.3`, `libssl.so.3`
- `windows-x86_64`: `adbc_driver_postgresql.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `comerr64.dll`, `gssapi64.dll`, `k5sprt64.dll`, `krb5_64.dll`, `libcrypto-3-x64.dll`, `libpq.dll`, `libssl-3-x64.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### Flight SQL

- `macos-arm64`: `libadbc_driver_flightsql.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_flightsql.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_flightsql.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_flightsql.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `adbc_driver_flightsql.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### Snowflake

- `macos-arm64`: `libadbc_driver_snowflake.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_snowflake.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_snowflake.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_snowflake.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `adbc_driver_snowflake.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### MySQL

- `macos-arm64`: `libadbc_driver_mysql.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_mysql.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_mysql.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_mysql.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `adbc_driver_mysql.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### BigQuery

- `macos-arm64`: `libadbc_driver_bigquery.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_bigquery.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_bigquery.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_bigquery.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_bigquery.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### SQL Server

- `macos-arm64`: `libadbc_driver_mssql.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: not vendored in this workspace
- `linux-arm64`: `libadbc_driver_mssql.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_mssql.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_mssql.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### Redshift

- `macos-arm64`: `libadbc_driver_redshift.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: not vendored in this workspace
- `linux-arm64`: `libadbc_driver_redshift.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_redshift.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_redshift.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### Trino

- `macos-arm64`: `libadbc_driver_trino.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: not vendored in this workspace
- `linux-arm64`: `libadbc_driver_trino.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_trino.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_trino.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### Databricks

- `macos-arm64`: `libadbc_driver_databricks.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_databricks.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_databricks.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_databricks.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_databricks.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### ClickHouse

- `macos-arm64`: `libadbc_driver_clickhouse.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_clickhouse.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_clickhouse.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_clickhouse.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_clickhouse.dll`, `adbc_driver_manager.dll`, `api-ms-win-core-synch-l1-2-0.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### Exasol

- `macos-arm64`: `libadbc_driver_exasol.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_exasol.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_exasol.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_exasol.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_exasol.dll`, `adbc_driver_manager.dll`, `api-ms-win-core-synch-l1-2-0.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

### SingleStore

- `macos-arm64`: `libadbc_driver_singlestore.dylib`, `libadbc_driver_manager.dylib`
- `macos-x86_64`: `libadbc_driver_singlestore.dylib`, `libadbc_driver_manager.dylib`
- `linux-arm64`: `libadbc_driver_singlestore.so`, `libadbc_driver_manager.so`
- `linux-x86_64`: `libadbc_driver_singlestore.so`, `libadbc_driver_manager.so`
- `windows-x86_64`: `libadbc_driver_singlestore.dll`, `adbc_driver_manager.dll`, `api-ms-win-crt-convert-l1-1-0.dll`, `api-ms-win-crt-environment-l1-1-0.dll`, `api-ms-win-crt-filesystem-l1-1-0.dll`, `api-ms-win-crt-heap-l1-1-0.dll`, `api-ms-win-crt-locale-l1-1-0.dll`, `api-ms-win-crt-math-l1-1-0.dll`, `api-ms-win-crt-private-l1-1-0.dll`, `api-ms-win-crt-runtime-l1-1-0.dll`, `api-ms-win-crt-stdio-l1-1-0.dll`, `api-ms-win-crt-string-l1-1-0.dll`, `api-ms-win-crt-time-l1-1-0.dll`, `api-ms-win-crt-utility-l1-1-0.dll`, `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`

SurrealDB is vendored separately from the ADBC path and uses its own shared-library naming under `third_party/surrealdb/lib/<platform>/`:

| Database | `.dylib` | `.so` | `.dll` |
| --- | --- | --- | --- |
| SurrealDB | `libsurrealdb.dylib` | `libsurrealdb.so` | `surrealdb.dll` |

## SurrealDB C SDK

SurrealDB is vendored separately from the ADBC path under `third_party/surrealdb/`, and this repository now keeps only the official `surrealdb/surrealdb.c` source snapshot plus the locally built current-platform shared library.

Run `scripts/download_surrealdb_c_source.sh` to download the full official `surrealdb/surrealdb.c` source tree for the pinned upstream commit and vendor it directly under `third_party/surrealdb/tree/`, with the source archive under `third_party/surrealdb/source/`.

Run `scripts/build_surrealdb_c_vendor_lib.sh` to build the vendored `surrealdb.c` SDK for the current host platform and install the shared library under `third_party/surrealdb/lib/<platform>/` as `libsurrealdb.dylib`, `libsurrealdb.so`, or `surrealdb.dll`, with the public header mirrored under `third_party/surrealdb/include/`.

Common build flows from the repository root:

Embedded or local-only build (`mem://`, `surrealkv://`):

```bash
scripts/download_surrealdb_c_source.sh
scripts/build_surrealdb_c_vendor_lib.sh
```

Remote-enabled build with the repository's active Rust toolchain:

```bash
scripts/download_surrealdb_c_source.sh
SURREALDB_REMOTE_ACCESS=1 scripts/build_surrealdb_c_vendor_lib.sh
```

Remote-enabled build when the default `rustc` is too old for SurrealDB remote dependencies:

```bash
scripts/download_surrealdb_c_source.sh
SURREALDB_REMOTE_ACCESS=1 \
SURREALDB_RUSTUP_TOOLCHAIN=1.91.0-aarch64-apple-darwin \
scripts/build_surrealdb_c_vendor_lib.sh
```

The script defaults to `release` builds, strips the installed Unix binary (`SURREALDB_STRIP_BINARY=1`), and uses a size-first release profile (`opt-level=z`, `lto=fat`, `codegen-units=1`, `panic=abort`) to keep the vendored shared library small. Set `SURREALDB_C_PROFILE=debug` or `SURREALDB_STRIP_BINARY=0` if you need an unstripped debug build.

The vendored `surrealdb.c` dependency configuration is tuned for embedded/local use (`mem://` and `surrealkv://`) instead of remote HTTP/WebSocket connectivity.

To compile remote client access into the vendored `surrealdb.c` library, set `SURREALDB_REMOTE_ACCESS=1` before running `scripts/build_surrealdb_c_vendor_lib.sh`. By default this enables both HTTP and WebSocket client protocols with Rustls:

```bash
SURREALDB_REMOTE_ACCESS=1 scripts/build_surrealdb_c_vendor_lib.sh
```

Optional knobs:

- `SURREALDB_REMOTE_TRANSPORTS=http,ws` to choose `http`, `ws`, or both
- `SURREALDB_REMOTE_TLS=rustls` or `SURREALDB_REMOTE_TLS=native-tls`
- `SURREALDB_CARGO_FEATURES=feature1,feature2` to append extra crate features explicitly
- `SURREALDB_RUSTUP_TOOLCHAIN=<toolchain>` to force a specific rustup toolchain for remote builds when the default `rustc` is too old

Current SurrealDB 3.0.1 remote dependencies require `rustc >= 1.88`. If your shell resolves an older compiler, the build script now tries `rustup run stable cargo ...` first, then falls back to any installed rustup toolchain that satisfies that minimum.

Example using only WebSocket with native TLS:

```bash
SURREALDB_REMOTE_ACCESS=1 \
SURREALDB_REMOTE_TRANSPORTS=ws \
SURREALDB_REMOTE_TLS=native-tls \
scripts/build_surrealdb_c_vendor_lib.sh
```

Set `SURREALDB_CARGO_TARGET=<rust-target-triple>` to attempt a cross build for another target, for example `x86_64-apple-darwin`, `x86_64-unknown-linux-gnu`, or `aarch64-unknown-linux-gnu`. Cross builds still depend on the corresponding Rust target, linker, SDK, and system libraries being available on the machine running the script.

SurrealDB also maintains an official separate C SDK repository, `surrealdb/surrealdb.c`, which exposes `include/surrealdb.h` and declares Rust crate types `lib`, `staticlib`, and `cdylib`. That is the upstream C ABI path used here for Zig integration, and it is currently vendored as source plus current-host output rather than as prebuilt multi-platform binaries.

The platform matrix is not uniform. The upstream community ADBC registry currently publishes these community drivers for `macos_arm64`, `linux_amd64`, `linux_arm64`, and `windows_amd64`, but generally not for `macos_amd64`. In this repository, `macos-x86_64` now includes source-built Intel macOS dylibs for MySQL, BigQuery, Databricks, ClickHouse, Exasol, and SingleStore alongside the official Arrow/DuckDB artifacts. SQL Server, Redshift, and Trino remain absent on `macos-x86_64` because the current community distributions do not publish Intel macOS artifacts and there is no public-source build path wired into this repository for them.

## MySQL

This repository now has the control-plane support needed to open an ADBC connection through a MySQL-compatible shared library. The workspace currently vendors a community MySQL ADBC driver under `third_party/adbc/1.11.0/lib/<platform>/`, so `mysql://...` now resolves automatically on the vendored macOS, Linux, and Windows targets shipped in this repository.

On `macos-x86_64`, this repository vendors a separately built Intel macOS MySQL dylib together with source-built Intel macOS dylibs for BigQuery, Databricks, ClickHouse, Exasol, and SingleStore.

On platforms where the repository does not have a vendored MySQL shared library yet, keep using an explicit native path such as `driver=/absolute/path/to/libadbc_driver_mysql.dylib;uri=mysql://...`.

On macOS, some third-party drivers may also require setting `DYLD_LIBRARY_PATH` so their native dependencies can be resolved before `database.zig` loads them.

## Common Commands

```bash
zig build
zig build shared
zig build test
```

## Testing

### Run All Tests

From the repository root, this sequence covers the Zig unit tests plus the Python, Node.js, and Rust binding test suites:

```bash
zig build test
zig build shared
python -m unittest discover -s tests/python -p 'test_*.py'
npm --prefix bindings/nodejs install
npm --prefix bindings/nodejs run typecheck:tests
npm --prefix bindings/nodejs run test:node
cargo test --manifest-path bindings/rust/Cargo.toml --tests
```

`zig build shared` should run before the language binding suites so Python, Node.js, and Rust can load `zig-out/lib/libaq_database.*`.

Note: this repository does not have a top-level `Cargo.toml`; the Rust bindings are under `bindings/rust`, so use `--manifest-path bindings/rust/Cargo.toml` for Rust tests.

### Zig Core Unit Tests

Run the Zig unit tests for the control plane and C ABI surface:

```bash
zig build test
```

### Binding Unit Tests

These commands cover database-independent binding behavior such as value conversion and local wrapper logic.

Python:

```bash
python -m unittest discover -s tests/python -p 'test_value_conversion.py'
```

Node.js:

```bash
npm --prefix bindings/nodejs install
npm --prefix bindings/nodejs exec tsx -- --test ../../tests/nodejs/test_value_conversion.test.ts
```

Rust:

```bash
cargo test --manifest-path bindings/rust/Cargo.toml --lib
cargo test --manifest-path bindings/rust/Cargo.toml --test test_value_conversion
```

### Binding Integration Tests

Database-backed binding tests read connection settings from the repository `.env` file by default. The file uses INI-style sections such as `[postgres]` and `[starrocks]`.

Run all Python binding tests:

```bash
python -m unittest discover -s tests/python -p 'test_*.py'
```

Run all Node.js binding tests:

```bash
npm --prefix bindings/nodejs install
npm --prefix bindings/nodejs run typecheck:tests
npm --prefix bindings/nodejs run test:node
```

Run all Rust binding tests:

```bash
zig build shared
cargo test --manifest-path bindings/rust/Cargo.toml --tests
```

To narrow integration coverage to one configured database section, set `DATABASE_ZIG_TEST_SECTION`, for example:

```bash
DATABASE_ZIG_TEST_SECTION=postgres cargo test --manifest-path bindings/rust/Cargo.toml --test test_postgres -- --nocapture
DATABASE_ZIG_TEST_SECTION=starrocks python -m unittest discover -s tests/python -p 'test_starrocks.py'
```

## Recommended Next Steps

1. Replace the stubbed ADBC registration with real Arrow ADBC C API calls.
2. Add configuration for ADBC driver manager loading, vendor driver paths, and option translation.
3. Split pooling, credential refresh, transactions, and row-value decoding into separate abstractions on top of ADBC.
4. Add packaging and CI workflows for Python and Node.js.
