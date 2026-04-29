# Drivers

The old per-database driver scaffolds have been removed. database.zig now routes all database access through Apache Arrow ADBC and keeps Zig responsible for connection lifecycle, error mapping, result-set ownership, and the public ABI.

## Current Role

- Document the migration away from per-database native driver folders.
- Track how Zig should load the Arrow ADBC driver manager and vendor ADBC shared libraries.
- Keep database-specific protocol handling out of the Python and Node.js bindings.

## Integration Rules

- Zig should expose one built-in public backend: `adbc`.
- Zig should depend on Arrow ADBC shared libraries through dynamic linking.
- Vendor-specific connection options should flow through ADBC configuration rather than separate Zig driver kinds.
- Language bindings should remain thin wrappers over the public C ABI.
