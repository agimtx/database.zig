mod support;

use aq_database::{ColumnType, ConnectionManager, QualifiedNamePartRole, Value};
use support::{
    assert_columns, assert_namespace_access, assert_table_qualified_name, execute_non_query,
    find_row_index, load_target, maybe_skip_configured_section, read_values, unique_identifier,
};

#[test]
fn rust_binding_postgres_flightsql_connection() {
    if let Some(reason) = maybe_skip_configured_section("postgres_flightsql") {
        eprintln!("skipping rust Postgres Flight SQL integration test: {reason}");
        return;
    }

    let target = load_target("postgres_flightsql").expect("postgres_flightsql target should load after skip check");
    let table_name = unique_identifier("aq_pg_flightsql");

    let test_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let manager = ConnectionManager::new()?;

        let connection = match manager.connect(target.driver, &target.dsn(None)) {
            Ok(connection) => connection,
            Err(error) if is_runtime_unavailable(&error) => {
                eprintln!("skipping rust Postgres Flight SQL integration test at runtime: {error}");
                return Ok(());
            }
            Err(error) => return Err(Box::new(error)),
        };

        assert!(connection.test()?);

        execute_non_query(
            &connection,
            &format!(
                "create table {table_name} (id bigint primary key, enabled boolean not null, name text not null)"
            ),
        )?;

        let live_result = (|| -> Result<(), Box<dyn std::error::Error>> {
            execute_non_query(
                &connection,
                &format!(
                    "insert into {table_name} (id, enabled, name) values (1, true, 'alpha'), (2, false, 'beta')"
                ),
            )?;

            let result_set = connection.execute(&format!(
                "select id, enabled, name from {table_name} order by id"
            ))?;
            assert_eq!(result_set.row_count()?, 2);
            assert_eq!(result_set.affected_rows()?, 2);
            assert_columns(
                &result_set.columns()?,
                &[
                    ("id", ColumnType::Int64),
                    ("enabled", ColumnType::Boolean),
                    ("name", ColumnType::Text),
                ],
            );
            assert_eq!(result_set.value(0, 0)?, Value::Int64(1));
            assert_eq!(result_set.value(0, 1)?, Value::Boolean(true));
            assert_eq!(result_set.value(0, 2)?, Value::Text("alpha".to_owned()));
            assert_eq!(result_set.value(1, 0)?, Value::Int64(2));
            assert_eq!(result_set.value(1, 1)?, Value::Boolean(false));
            assert_eq!(result_set.value(1, 2)?, Value::Text("beta".to_owned()));
            result_set.close()?;

            let missing_table_error = match connection.execute(&format!(
                "select * from {}",
                unique_identifier("missing_table")
            )) {
                Ok(_) => panic!("missing table should fail"),
                Err(error) => error,
            };
            assert!(!missing_table_error.to_string().is_empty());

            let cursor = connection.cursor(&format!(
                "select id, enabled, name from {table_name} order by id"
            ))?;
            assert_columns(
                &cursor.columns()?,
                &[
                    ("id", ColumnType::Int64),
                    ("enabled", ColumnType::Boolean),
                    ("name", ColumnType::Text),
                ],
            );
            let mut seen_rows = 0;
            while cursor.next()? {
                seen_rows += 1;
            }
            assert_eq!(seen_rows, 2);
            cursor.close()?;

            let databases_result = connection.get_databases()?;
            let database_names = read_values(&databases_result, 0)?;
            assert!(database_names.contains(&Value::Text("public".to_owned())));
            databases_result.close()?;

            let catalogs_error = match connection.get_catalogs() {
                Ok(_) => panic!("flightsql targets should currently reject get_catalogs"),
                Err(error) => error,
            };
            assert!(catalogs_error.to_string().contains("get catalogs is not supported"));

            let tables_result = connection.get_tables(None, Some("public"))?;
            let table_names = read_values(&tables_result, 2)?;
            assert!(table_names.contains(&Value::Text(table_name.clone())));
            let row_index = find_row_index(&tables_result, 2, &Value::Text(table_name.clone()))?;
            assert_table_qualified_name(&tables_result, row_index)?;
            tables_result.close()?;

            let namespace_access = connection.inspect_namespace_access(None, Some("public"))?;
            assert_namespace_access(
                &namespace_access,
                false,
                true,
                true,
                QualifiedNamePartRole::Database,
                &[(QualifiedNamePartRole::Database, "public")],
            );

            let missing_namespace = unique_identifier("missing_schema");
            let missing_access = connection.inspect_namespace_access(None, Some(&missing_namespace))?;
            assert_namespace_access(
                &missing_access,
                false,
                true,
                false,
                QualifiedNamePartRole::Database,
                &[(QualifiedNamePartRole::Database, &missing_namespace)],
            );

            Ok(())
        })();

        let drop_result = execute_non_query(&connection, &format!("drop table if exists {table_name}"));

        live_result?;
        drop_result?;

        connection.close()?;
        Ok(())
    })();

    test_result.unwrap();
}

fn is_runtime_unavailable(error: &aq_database::Error) -> bool {
    let message = error.to_string();
    message.contains("Could not load")
        || message.contains("Library not loaded")
        || message.contains("connection refused")
        || message.contains("timed out")
        || message.contains("not implemented")
}