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

The platform matrix is not uniform. The upstream community ADBC registry currently publishes these community drivers for `macos_arm64`, `linux_amd64`, `linux_arm64`, and `windows_amd64`, but generally not for `macos_amd64`. In this repository, `macos-x86_64` now includes source-built Intel macOS dylibs for MySQL, BigQuery, Trino, Databricks, ClickHouse, Exasol, and SingleStore alongside the official Arrow/DuckDB artifacts. SQL Server and Redshift remain absent on `macos-x86_64` because the current community distributions do not publish Intel macOS artifacts and there is no public-source build path wired into this repository for them.

## MySQL

This repository now has the control-plane support needed to open an ADBC connection through a MySQL-compatible shared library. The workspace currently vendors a community MySQL ADBC driver under `third_party/adbc/1.11.0/lib/<platform>/`, so `mysql://...` now resolves automatically on the vendored macOS, Linux, and Windows targets shipped in this repository.

On `macos-x86_64`, this repository vendors a separately built Intel macOS MySQL dylib together with source-built Intel macOS dylibs for BigQuery, Trino, Databricks, ClickHouse, Exasol, and SingleStore.

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
cargo test --manifest-path bindings/rust/Cargo.toml
```

`zig build shared` should run before the language binding suites so Python, Node.js, and Rust can load `zig-out/lib/libaq_database.*`.

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
cargo test --manifest-path bindings/rust/Cargo.toml
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
