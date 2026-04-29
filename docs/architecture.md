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

### 3. Native Drivers

- Each database driver lives under `drivers/<database>/`.
- Drivers can be implemented in Rust or other native stacks as long as they expose the shared-library ABI Zig expects.
- Zig depends on those shared libraries instead of embedding driver runtime objects directly.

## Integration Rule

The Zig-to-driver boundary is a shared-library dependency boundary. Each driver exports a small native ABI, Zig depends on the resulting dynamic library for the current target, and the public language bindings only interact with Zig.

See `docs/native-driver-linking.md` for the per-platform artifact and ABI rules.

## Evolution Path

1. Replace the current stub registrations with dynamically linked native drivers.
2. Add connection pooling, timeouts, cancellation, retries, and health checks.
3. Add row-value decoding, transactions, batch ingestion, and streaming result reads.
4. Add more idiomatic high-level APIs for Python and Node.js without leaking driver internals.

## Driver ABI Draft

- Zig owns `ConnectionManager`, connection IDs, and public error semantics.
- Drivers export direct ABI functions such as `dbz_driver_open`, `dbz_driver_close`, `dbz_driver_execute`, and `dbz_driver_open_cursor` from a shared library.
- Optional extensions can add `ping`, `begin_tx`, `commit`, `rollback`, and row-value readers.
