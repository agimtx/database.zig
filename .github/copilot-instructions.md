# database.zig Default Prompt

Always follow these repository rules when working in this codebase:

- This project is structured as Zig control plane + native driver layer + public C ABI + thin Python and Node.js bindings.
- Keep the types, error model, connection lifecycle, and driver registration contracts in `src/core/` stable.
- Do not move database protocol details, SQL dialect handling, or authentication logic into the Python or Node.js bindings.
- New database support should be implemented under `drivers/<database>/` and then wired into Zig.
- Drivers must be compiled into platform-native shared libraries and consumed by Zig through dynamic linking.
- Do not assume static archive integration, runtime vtable discovery, or ad-hoc plugin registration.
- Keep the external public API centered on a stable C ABI, then wrap that ABI for Python and Node.js.
- Keep dependency flow one-way: `native drivers -> zig core -> public c abi -> language bindings`.
- Prioritize tests, error-code mapping, symmetric resource cleanup, and cross-language examples.
- When adding new capability, prefer extending shared abstractions such as `health check`, `query`, or `transaction` instead of hard-coding one database-specific branch.

Before delivering an implementation, verify:

1. Connection creation and teardown remain symmetric.
2. Errors stay stable across the public C ABI.
3. Zig-to-driver integration remains a dynamic shared-library dependency contract.
4. Language bindings only convert arguments and surface results.
5. The design still generalizes across MySQL, PostgreSQL, SQL Server, Snowflake, BigQuery, DuckDB, ClickHouse, Redshift, Databricks, and Trino.