#![allow(dead_code)]

use aq_database::{ColumnMetadata, ColumnType, ConnectionManager, DriverKind, Error, QualifiedNamePartRole, Value};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .unwrap()
        .to_path_buf()
}

pub fn should_run_section(section: &str) -> bool {
    env::var("DATABASE_ZIG_TEST_SECTION")
        .map(|requested| requested.eq_ignore_ascii_case(section))
        .unwrap_or(true)
}

pub fn default_env_file() -> PathBuf {
    repo_root().join(".env")
}

pub fn vendored_driver_path(name: &str) -> PathBuf {
    let host = if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "macos-arm64"
        } else {
            "macos-x86_64"
        }
    } else if cfg!(target_os = "linux") {
        if cfg!(target_arch = "aarch64") {
            "linux-arm64"
        } else {
            "linux-x86_64"
        }
    } else if cfg!(target_os = "windows") {
        "windows-x86_64"
    } else {
        panic!("unsupported platform")
    };

    let file_name = if cfg!(target_os = "windows") {
        if name == "duckdb" {
            "duckdb.dll".to_owned()
        } else {
            format!("adbc_driver_{name}.dll")
        }
    } else {
        let suffix = if cfg!(target_os = "macos") { ".dylib" } else { ".so" };
        if name == "duckdb" {
            format!("libduckdb{suffix}")
        } else {
            format!("libadbc_driver_{name}{suffix}")
        }
    };

    repo_root()
        .join("third_party")
        .join("adbc")
        .join("1.11.0")
        .join("lib")
        .join(host)
        .join(file_name)
}

pub fn repo_tmp_dir(parts: &[&str]) -> PathBuf {
    let mut path = repo_root().join(".tmp");
    for part in parts {
        path.push(part);
    }
    fs::create_dir_all(&path).unwrap();
    path
}

pub fn remove_file_if_exists(path: &Path) {
    let _ = fs::remove_file(path);
}

pub fn unique_identifier(prefix: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("{prefix}_{:08x}", (nanos & 0xffff_ffff) as u64)
}

pub fn duckdb_test_dsn(database_path: &Path) -> String {
    format!(
        "driver={};entrypoint=duckdb_adbc_init;path={}",
        vendored_driver_path("duckdb").display(),
        database_path.display()
    )
}

pub fn maybe_skip_duckdb() -> Option<String> {
    if !should_run_section("duckdb") {
        return Some("DATABASE_ZIG_TEST_SECTION is filtering out duckdb".to_owned());
    }

    let env_file = env::var("DATABASE_ZIG_TEST_ENV_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_env_file());
    if env_file.exists() {
        return None;
    }

    let driver_path = vendored_driver_path("duckdb");
    if !driver_path.exists() {
        return Some(format!("duckdb driver not found: {}", driver_path.display()));
    }

    None
}

pub fn open_duckdb_manager() -> Result<ConnectionManager, Error> {
    ConnectionManager::new()
}

pub fn open_duckdb_connection(manager: &ConnectionManager, dsn: &str) -> Result<aq_database::Connection, Error> {
    manager.connect(DriverKind::Adbc, dsn)
}

pub fn read_values(result_set: &aq_database::ResultSet, column_index: usize) -> Result<Vec<Value>, Error> {
    let row_count = result_set.row_count()? as usize;
    let mut values = Vec::with_capacity(row_count);
    for row_index in 0..row_count {
        values.push(result_set.value(row_index, column_index)?);
    }
    Ok(values)
}

pub fn find_row_index(result_set: &aq_database::ResultSet, column_index: usize, expected: &Value) -> Result<usize, Error> {
    let row_count = result_set.row_count()? as usize;
    for row_index in 0..row_count {
        if &result_set.value(row_index, column_index)? == expected {
            return Ok(row_index);
        }
    }
    panic!("value not found in column {column_index}: {expected:?}");
}

pub fn assert_columns(columns: &[ColumnMetadata], expected: &[(&str, ColumnType)]) {
    assert_eq!(columns.len(), expected.len());
    for (column, (name, column_type)) in columns.iter().zip(expected.iter()) {
        assert_eq!(&column.name, name);
        assert_eq!(&column.column_type, column_type);
    }
}

pub fn assert_table_qualified_name(result_set: &aq_database::ResultSet, row_index: usize) -> Result<(), Error> {
    let qualified_name = result_set.table_qualified_name(row_index)?;
    let catalog = result_set.value(row_index, 0)?;
    let namespace = result_set.value(row_index, 1)?;
    let object_name = result_set.value(row_index, 2)?;
    let namespace_kind = result_set.value(row_index, 4)?;
    let formatted = result_set.value(row_index, 5)?;

    let mut expected_parts = Vec::new();
    if let Value::Text(value) = catalog {
        if !value.is_empty() {
            expected_parts.push((QualifiedNamePartRole::Catalog, value));
        }
    }
    if let (Value::Text(kind), Value::Text(value)) = (namespace_kind, namespace) {
        if !value.is_empty() {
            expected_parts.push((namespace_kind_role(&kind), value));
        }
    }
    if let Value::Text(value) = object_name {
        if !value.is_empty() {
            expected_parts.push((QualifiedNamePartRole::Object, value));
        }
    }

    assert_eq!(
        qualified_name
            .parts
            .iter()
            .map(|part| (part.role, part.value.clone()))
            .collect::<Vec<_>>(),
        expected_parts
    );

    match formatted {
        Value::Text(value) => assert_eq!(qualified_name.formatted, value),
        other => panic!("unexpected formatted value: {other:?}"),
    }

    Ok(())
}

fn namespace_kind_role(namespace_kind: &str) -> QualifiedNamePartRole {
    let mapping = HashMap::from([
        ("catalog", QualifiedNamePartRole::Catalog),
        ("database", QualifiedNamePartRole::Database),
        ("schema", QualifiedNamePartRole::Schema),
        ("dataset", QualifiedNamePartRole::Dataset),
        ("namespace", QualifiedNamePartRole::Namespace),
        ("object", QualifiedNamePartRole::Object),
    ]);
    *mapping.get(namespace_kind).unwrap()
}