#![allow(dead_code)]

use aq_database::{ColumnMetadata, ColumnType, ConnectionManager, DriverKind, Error, QualifiedNamePartRole, Value};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct TestTarget {
    pub driver: DriverKind,
    pub section: String,
    pub config: HashMap<String, String>,
}

impl TestTarget {
    pub fn dsn(&self, database_override: Option<&str>) -> String {
        build_dsn(&self.section, &self.config, database_override)
    }
}

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

pub fn load_target(section: &str) -> Result<TestTarget, String> {
    let env_file = env::var("DATABASE_ZIG_TEST_ENV_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| default_env_file());
    if !env_file.exists() {
        return Err(format!("test config not found: {}", env_file.display()));
    }

    let sections = parse_ini_sections(&env_file)?;
    let resolved_section = resolve_section_name(&sections, section)
        .ok_or_else(|| format!("test section not found: {section}"))?;
    let config = sections.get(&resolved_section).cloned().unwrap_or_default();
    Ok(TestTarget {
        driver: DriverKind::Adbc,
        section: resolved_section,
        config,
    })
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

pub fn maybe_skip_configured_section(section: &str) -> Option<String> {
    if !should_run_section(section) {
        return Some(format!("DATABASE_ZIG_TEST_SECTION is filtering out {section}"));
    }

    load_target(section).err()
}

pub fn open_duckdb_manager() -> Result<ConnectionManager, Error> {
    ConnectionManager::new()
}

pub fn open_duckdb_connection(manager: &ConnectionManager, dsn: &str) -> Result<aq_database::Connection, Error> {
    manager.connect(DriverKind::Adbc, dsn)
}

pub fn execute_non_query(connection: &aq_database::Connection, sql: &str) -> Result<(), Error> {
    let result_set = connection.execute(sql)?;
    result_set.close()
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

pub fn assert_columns_match(columns: &[ColumnMetadata], expected: &[ExpectedColumn<'_>]) {
    assert_eq!(columns.len(), expected.len());
    for (column, expected_column) in columns.iter().zip(expected.iter()) {
        assert_eq!(column.name, expected_column.name);
        assert!(
            expected_column.column_types.iter().any(|column_type| column.column_type == *column_type),
            "column {} type mismatch: got {:?}",
            column.name,
            column.column_type
        );
        if let Some(raw_type) = expected_column.raw_type {
            assert_eq!(column.raw_type.as_deref(), Some(raw_type));
        }
    }
}

pub struct ExpectedColumn<'a> {
    pub name: &'a str,
    pub column_types: &'a [ColumnType],
    pub raw_type: Option<&'a str>,
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

fn parse_ini_sections(path: &Path) -> Result<HashMap<String, HashMap<String, String>>, String> {
    let content = fs::read_to_string(path)
        .map_err(|error| format!("failed to read {}: {error}", path.display()))?;
    let mut sections: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut current: Option<String> = None;

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            let section_name = line[1..line.len() - 1].trim().to_owned();
            sections.entry(section_name.clone()).or_default();
            current = Some(section_name);
            continue;
        }

        let Some(section_name) = current.as_ref() else {
            continue;
        };
        let Some(index) = line.find('=') else {
            continue;
        };

        let key = line[..index].trim().to_owned();
        let value = line[index + 1..].trim().to_owned();
        sections.entry(section_name.clone()).or_default().insert(key, value);
    }

    Ok(sections)
}

fn resolve_section_name(
    sections: &HashMap<String, HashMap<String, String>>,
    section: &str,
) -> Option<String> {
    let alias = if section.eq_ignore_ascii_case("postgresql") {
        Some("postgres")
    } else {
        None
    };

    for candidate in [Some(section), alias].into_iter().flatten() {
        if sections.contains_key(candidate) {
            return Some(candidate.to_owned());
        }
    }

    None
}

fn build_dsn(section: &str, config: &HashMap<String, String>, database_override: Option<&str>) -> String {
    if let Some(explicit_dsn) = config.get("dsn") {
        if database_override.is_none() {
            return explicit_dsn.clone();
        }
    }

    let scheme = config
        .get("scheme")
        .cloned()
        .unwrap_or_else(|| default_scheme(section).to_owned());
    let host = config
        .get("host")
        .cloned()
        .unwrap_or_else(|| "127.0.0.1".to_owned());
    let port = config.get("port").map(|value| format!(":{value}")).unwrap_or_default();
    let username = config.get("user").cloned().unwrap_or_default();
    let password = config.get("password").cloned();
    let database = database_override
        .map(ToOwned::to_owned)
        .or_else(|| config.get("database").cloned())
        .unwrap_or_else(|| default_database(section).to_owned());

    let credentials = if username.is_empty() {
        String::new()
    } else {
        let mut credentials = percent_encode(&username);
        if let Some(password) = password {
            credentials.push(':');
            credentials.push_str(&percent_encode(&password));
        }
        credentials.push('@');
        credentials
    };

    let database_part = if database.is_empty() {
        String::new()
    } else {
        format!("/{}", percent_encode(&database))
    };

    format!("{scheme}://{credentials}{host}{port}{database_part}")
}

fn default_scheme(section: &str) -> String {
    match section.to_ascii_lowercase().as_str() {
        "postgres" | "postgresql" => "postgresql".to_owned(),
        "starrocks" | "mysql" | "singlestore" => "mysql".to_owned(),
        _ => section.to_owned(),
    }
}

fn default_database(section: &str) -> String {
    match section.to_ascii_lowercase().as_str() {
        "postgres" | "postgresql" => "postgres".to_owned(),
        "starrocks" | "mysql" | "singlestore" => "information_schema".to_owned(),
        _ => String::new(),
    }
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}