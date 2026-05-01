mod support;

use aq_database::{ColumnType, Value};
use support::{
    assert_columns, assert_namespace_access, assert_table_qualified_name, duckdb_test_dsn,
    find_row_index, maybe_skip_duckdb, open_duckdb_connection, open_duckdb_manager, read_values,
    remove_file_if_exists, repo_tmp_dir, unique_identifier,
};

#[test]
fn rust_binding_duckdb_lifecycle() {
    if let Some(reason) = maybe_skip_duckdb() {
        eprintln!("skipping rust DuckDB integration test: {reason}");
        return;
    }

    let database_path = repo_tmp_dir(&["duckdb"]).join(format!("{}.duckdb", unique_identifier("aq_duckdb")));
    let table_name = unique_identifier("records");
    let dsn = duckdb_test_dsn(&database_path);

    remove_file_if_exists(&database_path);
    let test_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let manager = open_duckdb_manager()?;
        let connection = match open_duckdb_connection(&manager, &dsn) {
            Ok(connection) => connection,
            Err(error)
                if error.to_string().contains("Could not load")
                    || error.to_string().contains("Library not loaded") =>
            {
                eprintln!("skipping rust DuckDB integration test at runtime: {error}");
                return Ok(());
            }
            Err(error) => return Err(Box::new(error)),
        };

        assert!(connection.test()?);

        let create = connection.execute(&format!(
            "create table {table_name} (id bigint primary key, name varchar not null, score double not null, created_at timestamp not null)"
        ))?;
        create.close()?;

        let insert = connection.execute(&format!(
            "insert into {table_name} (id, name, score, created_at) values (1, 'alpha', 3.5, timestamp '2024-01-02 03:04:05')"
        ))?;
        insert.close()?;

        let result_set = connection.execute(&format!(
            "select id, name, score, created_at from {table_name} order by id"
        ))?;
        assert_eq!(result_set.row_count()?, 1);
        let columns = result_set.columns()?;
        assert_columns(
            &columns,
            &[
                ("id", ColumnType::Int64),
                ("name", ColumnType::Text),
                ("score", ColumnType::Float64),
                ("created_at", ColumnType::Timestamp),
            ],
        );
        assert_eq!(result_set.value(0, 0)?, Value::Int64(1));
        assert_eq!(result_set.value(0, 1)?, Value::Text("alpha".to_owned()));
        assert_eq!(result_set.value(0, 2)?, Value::Float64(3.5));
        match result_set.value(0, 3)? {
            Value::Text(value) => assert!(value.starts_with("2024-01-02T03:04:05")),
            other => panic!("unexpected timestamp value: {other:?}"),
        }
        result_set.close()?;

        let cursor = connection.cursor(&format!("select id, name from {table_name} order by id"))?;
        let cursor_columns = cursor.columns()?;
        assert_columns(&cursor_columns, &[("id", ColumnType::Int64), ("name", ColumnType::Text)]);
        assert!(cursor.next()?);
        assert!(!cursor.next()?);
        cursor.close()?;

        let tables = connection.get_tables(None, Some("main"))?;
        let table_row = find_row_index(&tables, 2, &Value::Text(table_name.clone()))?;
        let table_names = read_values(&tables, 2)?;
        assert!(table_names.contains(&Value::Text(table_name.clone())));
        assert_table_qualified_name(&tables, table_row)?;
        tables.close()?;

        let databases = connection.get_databases()?;
        let database_names = read_values(&databases, 0)?;
        assert!(database_names.contains(&Value::Text("main".to_owned())));
        databases.close()?;

        let catalogs = connection.get_catalogs()?;
        let catalog_names = read_values(&catalogs, 0)?;
        assert!(catalog_names.iter().any(|value| match value {
            Value::Text(text) => !text.is_empty(),
            _ => false,
        }));
        catalogs.close()?;

        let namespace_access = connection.inspect_namespace_access(None, Some("main"))?;
        assert_namespace_access(
            &namespace_access,
            true,
            true,
            true,
            aq_database::QualifiedNamePartRole::Schema,
            &[(aq_database::QualifiedNamePartRole::Schema, "main")],
        );

        let missing_namespace = unique_identifier("missing_schema");
        let missing_access = connection.inspect_namespace_access(None, Some(&missing_namespace))?;
        assert_namespace_access(
            &missing_access,
            true,
            true,
            false,
            aq_database::QualifiedNamePartRole::Schema,
            &[(aq_database::QualifiedNamePartRole::Schema, &missing_namespace)],
        );

        connection.close()?;

        let reopened = open_duckdb_connection(&manager, &dsn)?;
        let persisted = reopened.execute(&format!("select count(*) as row_count from {table_name}"))?;
        assert_eq!(persisted.value(0, 0)?, Value::Int64(1));
        persisted.close()?;
        reopened.close()?;

        Ok(())
    })();

    remove_file_if_exists(&database_path);
    test_result.unwrap();
}