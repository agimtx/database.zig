# Integration Tests

This directory contains binding-level integration tests for the Python and Node.js wrappers.

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
node --test tests/nodejs/*.test.js
```
