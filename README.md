# database.zig

database.zig is a database connection management library scaffold that uses Zig as the control plane and exposes a stable C ABI to C, Python, and Node.js. Database-specific drivers live under `drivers/<database>/`, can be implemented in Rust or other native stacks, and are consumed by Zig through a shared-library contract for MySQL 8, PostgreSQL, SQL Server, Snowflake, BigQuery, DuckDB, ClickHouse, Redshift, Databricks, Trino, and other analytical databases.

## Goals

- Use Zig to manage connection lifecycle, driver registration, error mapping, and the public ABI.
- Use per-database native driver implementations for protocol-heavy behavior while keeping the control plane centralized in Zig.
- Keep the Zig-to-driver integration based on shared native libraries so each driver can ship independently per operating system.
- Keep the external C ABI stable so Python and Node.js can remain thin wrappers.

## Repository Layout

```text
.
├── .github/
│   └── copilot-instructions.md
├── bindings/
│   ├── c/
│   │   └── include/
│   ├── nodejs/
│   │   └── src/
│   └── python/
│       └── database_zig/
├── docs/
│   └── architecture.md
├── drivers/
│   ├── bigquery/
│   ├── clickhouse/
│   ├── databricks/
│   ├── duckdb/
│   ├── mysql8/
│   ├── postgresql/
│   ├── redshift/
│   ├── snowflake/
│   ├── sqlserver/
│   ├── template/
│   └── trino/
└── src/
    ├── core/
    └── ffi/
```

## Current Status

- Zig already provides a connection manager, driver registry, and exported C ABI entry points.
- Zig now defines a unified external model for connections, SQL execution, cursors, result sets, and column metadata.
- Python includes a thin ctypes-based binding scaffold.
- Node.js includes a thin ffi-napi-based binding scaffold for the public C ABI.
- Drivers follow a shared-library contract and the template currently demonstrates a Rust implementation.

## Common Commands

```bash
zig build
zig build shared
zig build test
```

## Recommended Next Steps

1. Freeze the Zig-to-driver shared-library ABI for connection, execute, cursor, and metadata operations before implementing real drivers.
2. Split pooling, credential refresh, transactions, and row-value decoding into separate abstractions.
3. Add build automation that produces per-platform shared libraries for each driver implementation and wires them into Zig.
4. Add packaging and CI workflows for Python and Node.js.
