# Native Driver Linking

## Design Rule

Drivers are not compiled into static archives for direct object inclusion. Instead, each driver is compiled into a platform-native shared library and consumed by Zig through a dynamic library dependency.

## Why

- Shared libraries are easier to ship per operating system and architecture than embedding every driver into one final binary.
- They keep driver rollout separate from the Zig control-plane binary.
- It keeps the ABI surface explicit and testable.
- It allows Zig to treat each driver implementation as a target-specific native dependency.

## Artifact Expectations

Each driver should produce a platform-native shared library artifact:

- macOS: `libdbz_driver_<name>.dylib`
- Linux: `libdbz_driver_<name>.so`
- Windows: `dbz_driver_<name>.dll`

On Windows, the import library required by the Zig linker may also be produced alongside the DLL.

## Integration Pattern

1. The driver exports a small, explicit C ABI.
2. Zig declares a dynamic-library dependency on the driver library for the selected target.
3. Zig registers the driver through compile-time or build-time wiring.
4. Python and Node.js only see the final public C ABI exposed by Zig.

## ABI Shape

The minimal driver-side ABI should include:

- `dbz_driver_name`
- `dbz_driver_abi_version`
- `dbz_driver_open`
- `dbz_driver_close`
- `dbz_driver_execute`
- `dbz_driver_open_cursor`
- `dbz_driver_fetch_next`

Optional additions can include:

- `dbz_driver_ping`
- `dbz_driver_begin_tx`
- `dbz_driver_commit`
- `dbz_driver_rollback`
- row-value accessors and buffer decoders

## Build Notes

- Each supported operating system should have its own Rust shared-library output.
- Each supported operating system should have its own shared-library output for each driver.
- Driver build scripts should account for target triples rather than host-only builds.
- Zig should own final assembly and deployment rules so the public library remains consistent across platforms.