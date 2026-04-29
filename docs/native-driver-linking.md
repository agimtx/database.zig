# Arrow ADBC Linking

## Design Rule

Apache Arrow ADBC is not compiled into static archives for direct object inclusion. Instead, Zig consumes the ADBC driver manager and vendor driver shared libraries through dynamic linking.

## Why

- Shared libraries are easier to ship per operating system and architecture than embedding every database client into one final binary.
- They keep ADBC driver rollout separate from the Zig control-plane binary.
- They keep the ABI surface explicit and testable.
- They allow Zig to treat the ADBC driver manager and vendor drivers as target-specific native dependencies.

## Artifact Expectations

Zig should load the ADBC driver manager shared library plus the relevant vendor ADBC driver shared library for the selected database.

Typical platform-native artifacts include:

- macOS: `libadbc_driver_manager.dylib`, `libadbc_driver_<name>.dylib`
- Linux: `libadbc_driver_manager.so`, `libadbc_driver_<name>.so`
- Windows: `adbc_driver_manager.dll`, `adbc_driver_<name>.dll`

On Windows, the import libraries required by the Zig linker may also be produced alongside the DLLs.

## Integration Pattern

1. Zig links or loads the Arrow ADBC C API surface.
2. Zig configures the ADBC driver manager for the selected target database.
3. Zig registers a single public `adbc` backend through compile-time or build-time wiring.
4. Python and Node.js only see the final public C ABI exposed by Zig.

## API Shape

The minimal ADBC surface required by Zig should include:

- `AdbcDatabaseNew`
- `AdbcDatabaseSetOption`
- `AdbcDatabaseInit`
- `AdbcConnectionNew`
- `AdbcConnectionInit`
- `AdbcStatementNew`
- `AdbcStatementSetSqlQuery`
- `AdbcStatementExecuteQuery`

Optional additions can include:

- `AdbcConnectionGetInfo`
- `AdbcConnectionCommit`
- `AdbcConnectionRollback`
- Arrow stream readers and buffer decoders

## Build Notes

- Each supported operating system should have its own ADBC driver manager binary.
- Each supported operating system should have its own vendor ADBC driver binaries for the databases you ship.
- Build and packaging scripts should account for target triples rather than host-only builds.
- Zig should own final assembly and deployment rules so the public library remains consistent across platforms.
