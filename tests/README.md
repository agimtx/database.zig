# Binding Tests

This directory contains binding-level tests for the Python, Node.js, and Rust wrappers.

## Configuration

- Database-backed integration tests read connection settings from the repository `.env` file by default.
- The `.env` file uses INI-style sections such as `[postgres]`, `[postgres_flightsql]`, or `[starrocks]`.
- Python, Node.js, and Rust each keep one file per database, named like `test_postgres` and `test_starrocks`.
- Use `DATABASE_ZIG_TEST_SECTION` to run only one database-specific test file.
- Use `DATABASE_ZIG_TEST_ENV_FILE` to override the config file path.
- For Flight SQL-backed PostgreSQL tests, prefer an explicit `dsn=` entry in `[postgres_flightsql]` when the server needs parameters beyond a plain `flightsql://host:port/database` URI.
- Structured configs may also describe semicolon-separated ADBC option strings by combining fields such as `driver=`, `entrypoint=`, `uri=`, `additional_manifest_search_path_list=`, or driver-specific keys like `path=`.

Example template:

```ini
[postgres_flightsql]
# Preferred when auth, TLS, or extra query parameters are required:
dsn=flightsql://user:password@127.0.0.1:8815/postgres?useEncryption=false

# Or use structured fields instead of dsn:
# scheme=flightsql
# host=127.0.0.1
# port=8815
# database=postgres
# user=postgres
# password=secret

# Structured option-string form is also supported:
# driver=/absolute/path/to/libadbc_driver_postgresql.dylib
# entrypoint=AdbcDriverInit
# uri=postgresql://user:password@127.0.0.1:5432/postgres
```

## Run All Binding Tests

From the repository root, this sequence runs the Python, Node.js, and Rust binding suites end to end:

```bash
zig build shared
python -m unittest discover -s tests/python -p 'test_*.py'
npm --prefix bindings/nodejs install
npm --prefix bindings/nodejs run typecheck:tests
npm --prefix bindings/nodejs run test:node
cargo test --manifest-path bindings/rust/Cargo.toml
```

`zig build shared` should run first so all bindings can load `zig-out/lib/libaq_database.*`.

## Unit-Style Binding Tests

These tests do not require a live database.

### Python Unit Tests

```bash
python -m unittest discover -s tests/python -p 'test_value_conversion.py'
```

### Node.js Unit Tests

Install the binding dependencies first if they are not already installed:

```bash
npm --prefix bindings/nodejs install
```

Run the database-independent Node.js value conversion test from the repository root:

```bash
npm --prefix bindings/nodejs exec tsx -- --test ../../tests/nodejs/test_value_conversion.test.ts
```

### Rust Unit Tests

Run crate-local Rust unit tests:

```bash
cargo test --manifest-path bindings/rust/Cargo.toml --lib
```

Run the database-independent Rust binding test target:

```bash
cargo test --manifest-path bindings/rust/Cargo.toml --test test_value_conversion
```

## Integration Tests

### Python Integration Tests

Run from the repository root:

```bash
python -m unittest discover -s tests/python -p 'test_*.py'
```

### Node.js Integration Tests

Install the binding dependencies first if they are not already installed:

```bash
npm --prefix bindings/nodejs install
```

Run from the repository root:

```bash
npm --prefix bindings/nodejs run typecheck:tests
npm --prefix bindings/nodejs run test:node
```

### Rust Integration Tests

Rust test sources live under `tests/rust/`. Build the shared library first so the Rust crate can load `zig-out/lib/libaq_database.*`:

```bash
zig build shared
cargo test --manifest-path bindings/rust/Cargo.toml
```

To run a single configured integration test target, for example:

```bash
DATABASE_ZIG_TEST_SECTION=postgres cargo test --manifest-path bindings/rust/Cargo.toml --test test_postgres -- --nocapture
DATABASE_ZIG_TEST_SECTION=postgres_flightsql cargo test --manifest-path bindings/rust/Cargo.toml --test test_postgres_flightsql -- --nocapture
DATABASE_ZIG_TEST_SECTION=starrocks cargo test --manifest-path bindings/rust/Cargo.toml --test test_starrocks -- --nocapture
```
