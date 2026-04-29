# Drivers

This directory contains per-database driver implementations. Zig owns driver registration, connection lifecycle, the shared contract for SQL execution, cursors, result sets, and column metadata, and the public ABI. Each driver directory can use Rust or another native stack for protocol details, SDK compatibility, authentication flows, and database-specific behavior.

## Planned Driver Directories

- `mysql8/`
- `postgresql/`
- `sqlserver/`
- `snowflake/`
- `bigquery/`
- `duckdb/`
- `clickhouse/`
- `redshift/`
- `databricks/`
- `trino/`
- `template/`

## Integration Rules

- Each driver must expose a small, stable ABI to Zig.
- Each driver must build a platform-native shared library for every supported target OS.
- Zig should depend on driver shared libraries through dynamic linking.
- Driver internals must remain invisible to the language bindings.
- Drivers should fit the same lifecycle contract: open, close, execute, result-set metadata, cursor iteration, and health check.
- Prefer mature native ecosystems such as `sqlx`, `tokio-postgres`, `tiberius`, vendor SDKs, BigQuery REST or gRPC clients, the official DuckDB crate, or equivalent non-Rust libraries where appropriate.
