# Integration Tests

This directory contains binding-level integration tests for the Python, Node.js, and Rust wrappers.

## Configuration

- Tests read connection settings from the repository `.env` file by default.
- The `.env` file uses INI-style sections such as `[postgres]` or `[starrocks]`.
- Python and Node.js each keep one file per database, named like `test_postgres` and `test_starrocks`.
- Use `DATABASE_ZIG_TEST_SECTION` to run only one database-specific test file.
- Use `DATABASE_ZIG_TEST_ENV_FILE` to override the config file path.

## Python

Run from the repository root:

```bash
python -m unittest discover -s tests/python -p 'test_*.py'
```

## Node.js

Install the binding dependencies first if they are not already installed:

```bash
cd bindings/nodejs && npm install
```

Run from the repository root:

```bash
npm --prefix bindings/nodejs run typecheck:tests
npm --prefix bindings/nodejs run test:node
```

## Rust

Rust test sources live under `tests/rust/`. Build the shared library first so the Rust crate can load `zig-out/lib/libaq_database.*`:

```bash
zig build shared
cargo test --manifest-path bindings/rust/Cargo.toml
```
