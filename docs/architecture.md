# Architecture

## Layers

### 1. Zig Core

- `src/core/types.zig`: connection options and driver enums.
- `src/core/driver.zig`: driver contracts for connections, SQL execution, cursors, result sets, and column metadata.
- `src/core/registry.zig`: driver registration.
- `src/core/manager.zig`: connection lifecycle management plus result-set and cursor ownership.

### 2. Public C ABI

- `src/ffi/c_api.zig`: stable public C ABI.
- `bindings/c/include/database_zig.h`: C header.
- `bindings/python/`: thin Python wrapper over the public C ABI.
- `bindings/nodejs/`: thin Node.js wrapper over the public C ABI.

### 3. Apache Arrow ADBC Backend

- Zig exposes a single built-in ADBC backend through `DriverKind.adbc`.
- Database selection and vendor-specific behavior are delegated to the Arrow ADBC driver manager and the loaded ADBC driver library.
- Zig depends on ADBC shared libraries instead of embedding database protocol runtimes directly.

## Integration Rule

The Zig-to-ADBC boundary is a shared-library dependency boundary. Zig depends on the Arrow ADBC driver manager and vendor driver shared libraries for the current target, and the public language bindings only interact with Zig.

See `docs/native-driver-linking.md` for the per-platform artifact and ABI rules.

## Evolution Path

1. Replace the current stub registrations with real Arrow ADBC integration.
2. Add connection pooling, timeouts, cancellation, retries, and health checks.
3. Add row-value decoding, transactions, batch ingestion, and streaming result reads.
4. Add more idiomatic high-level APIs for Python and Node.js without leaking driver internals.

## ADBC Integration Draft

- Zig owns `ConnectionManager`, connection IDs, and public error semantics.
- Zig opens ADBC databases and connections, executes statements, and projects Arrow metadata into the stable public C ABI.
- Optional extensions can add `ping`, `begin_tx`, `commit`, `rollback`, and row-value readers.
