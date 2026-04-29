# database.zig

database.zig is a database connection management library scaffold that uses Zig as the control plane, Apache Arrow ADBC as the database access layer, and a stable C ABI for C, Python, and Node.js consumers. Zig owns lifecycle, registration, and error mapping while the target database is selected through the ADBC driver manager and connection configuration.

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
│   ├── nodejs/
│   │   └── src/
│   └── python/
│       └── database_zig/
├── docs/
│   └── architecture.md
└── src/
    ├── core/
    └── ffi/
```

## Current Status

- Zig already provides a connection manager, an ADBC-backed registry surface, and exported C ABI entry points.
- Zig now defines a unified external model for connections, SQL execution, cursors, result sets, and column metadata.
- Python includes a thin ctypes-based binding scaffold.
- Node.js includes a thin ffi-napi-based binding scaffold for the public C ABI.
- The current backend surface is a single built-in ADBC driver path selected through the public ABI.

## Common Commands

```bash
zig build
zig build shared
zig build test
```

## Recommended Next Steps

1. Replace the stubbed ADBC registration with real Arrow ADBC C API calls.
2. Add configuration for ADBC driver manager loading, vendor driver paths, and option translation.
3. Split pooling, credential refresh, transactions, and row-value decoding into separate abstractions on top of ADBC.
4. Add packaging and CI workflows for Python and Node.js.
