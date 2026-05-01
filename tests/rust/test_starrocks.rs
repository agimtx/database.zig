mod support;

use aq_database::{ColumnType, Value};
use support::{
    assert_columns_match, assert_namespace_access, assert_table_qualified_name, execute_non_query,
    find_row_index, load_target, maybe_skip_configured_section, read_values, ExpectedColumn,
    unique_identifier,
};

const STARROCKS_BOOL_TYPES: &[ColumnType] = &[ColumnType::Boolean, ColumnType::Int8];
const STARROCKS_JSON_TYPES: &[ColumnType] = &[ColumnType::Json, ColumnType::Text];

const STARROCKS_ADDITIONAL_TYPES_SQL: &str = concat!(
    "select ",
    "cast(1 as tinyint) as tiny_value, ",
    "cast(2 as smallint) as small_value, ",
    "cast(3 as int) as int_value, ",
    "cast(4 as bigint) as big_value, ",
    "cast(5.5 as float) as float_value, ",
    "cast(6.5 as double) as double_value, ",
    "cast('[1,2,3]' as array<int>) as array_value, ",
    "map('a',1,'b',2) as map_value, ",
    "row(1, 'alpha') as struct_value"
);

const STARROCKS_SKETCH_TYPES_SQL: &str = concat!(
    "select ",
    "to_bitmap(42) as bitmap_value, ",
    "hll_hash('alpha') as hll_value, ",
    "percentile_hash(42) as percentile_value"
);

#[test]
fn rust_binding_starrocks_lifecycle() {
    if let Some(reason) = maybe_skip_configured_section("starrocks") {
        eprintln!("skipping rust StarRocks integration test: {reason}");
        return;
    }

    let target = load_target("starrocks").expect("starrocks target should load after skip check");
    let database_name = unique_identifier("aq_sr");
    let table_name = unique_identifier("records");
    let missing_database = unique_identifier("missing_db");

    let test_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let manager = aq_database::ConnectionManager::new()?;

        let admin_connection = match manager.connect(target.driver, &target.dsn(None)) {
            Ok(connection) => connection,
            Err(error) if is_runtime_unavailable(&error) => {
                eprintln!("skipping rust StarRocks integration test at runtime: {error}");
                return Ok(());
            }
            Err(error) => return Err(Box::new(error)),
        };

        let missing_database_error = match manager.connect(target.driver, &target.dsn(Some(&missing_database))) {
            Ok(_) => panic!("missing database should fail"),
            Err(error) => error,
        };
        assert!(!missing_database_error.to_string().is_empty());
        execute_non_query(&admin_connection, &format!("create database if not exists {database_name}"))?;

        let database_result = (|| -> Result<(), Box<dyn std::error::Error>> {
            let database_connection = manager.connect(target.driver, &target.dsn(Some(&database_name)))?;
            assert!(database_connection.test()?);

            assert_starrocks_type_coverage(&database_connection, &table_name)?;
            assert_starrocks_additional_type_coverage(&database_connection)?;

            let missing_table = unique_identifier("missing");
            let missing_table_error = match database_connection.execute(&format!("select * from {missing_table}")) {
                Ok(_) => panic!("missing table should fail"),
                Err(error) => error,
            };
            assert!(!missing_table_error.to_string().is_empty());

            let missing_column = unique_identifier("missing_column");
            let missing_column_error = match database_connection.execute(&format!("select {missing_column} from {table_name}")) {
                Ok(_) => panic!("missing column should fail"),
                Err(error) => error,
            };
            assert!(!missing_column_error.to_string().is_empty());

            let databases_result = database_connection.get_databases()?;
            let database_names = read_values(&databases_result, 0)?;
            assert!(database_names.contains(&Value::Text(database_name.clone())));
            databases_result.close()?;

            let catalogs_error = match database_connection.get_catalogs() {
                Ok(_) => panic!("starrocks/mysql-compatible targets should reject get_catalogs"),
                Err(error) => error,
            };
            assert!(catalogs_error.to_string().contains("get catalogs is not supported"));

            let tables_result = database_connection.get_tables(None, Some(&database_name))?;
            let table_names = read_values(&tables_result, 2)?;
            assert!(table_names.contains(&Value::Text(table_name.clone())));
            let catalog_names = read_values(&tables_result, 0)?;
            assert!(catalog_names.iter().any(|value| match value {
                Value::Text(text) => !text.is_empty(),
                _ => false,
            }));
            let table_row = find_row_index(&tables_result, 2, &Value::Text(table_name.clone()))?;
            assert_table_qualified_name(&tables_result, table_row)?;
            tables_result.close()?;

            let namespace_access = database_connection.inspect_namespace_access(None, Some(&database_name))?;
            assert_namespace_access(
                &namespace_access,
                false,
                true,
                true,
                aq_database::QualifiedNamePartRole::Database,
                &[(aq_database::QualifiedNamePartRole::Database, &database_name)],
            );

            let missing_access = database_connection.inspect_namespace_access(None, Some(&missing_database))?;
            assert_namespace_access(
                &missing_access,
                false,
                true,
                false,
                aq_database::QualifiedNamePartRole::Database,
                &[(aq_database::QualifiedNamePartRole::Database, &missing_database)],
            );

            database_connection.close()?;
            Ok(())
        })();

        let drop_result = execute_non_query(&admin_connection, &format!("drop database if exists {database_name}"));
        let close_result = admin_connection.close();

        database_result?;
        drop_result?;
        close_result?;
        Ok(())
    })();

    test_result.unwrap();
}

fn assert_starrocks_type_coverage(
    connection: &aq_database::Connection,
    table_name: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    execute_non_query(
        connection,
        &format!(
            "create table {table_name} (id bigint not null, bool_value boolean not null, int_value bigint not null, float_value double not null, text_value string not null, fixed_text_value char(5) not null, decimal_value decimal(10, 2) not null, date_value date not null, timestamp_value datetime not null, largeint_value largeint not null, json_value json not null) duplicate key(id) distributed by hash(id) buckets 1 properties (\"replication_num\" = \"1\")"
        ),
    )?;

    execute_non_query(
        connection,
        &format!(
            "insert into {table_name} (id, bool_value, int_value, float_value, text_value, fixed_text_value, decimal_value, date_value, timestamp_value, largeint_value, json_value) values (1, true, 42, 3.5, 'alpha', 'omega', 123.45, '2024-01-02', '2024-01-02 03:04:05', 123456789012345678901234567890, parse_json('{{\"enabled\": true, \"count\": 1}}'))"
        ),
    )?;

    let result_set = connection.execute(&format!(
        "select id, bool_value, int_value, float_value, text_value, fixed_text_value, decimal_value, date_value, timestamp_value, largeint_value, json_value from {table_name} order by id"
    ))?;
    assert_eq!(result_set.row_count()?, 1);
    let columns = result_set.columns()?;
    assert_columns_match(
        &columns,
        &[
            ExpectedColumn { name: "id", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "bool_value", column_types: STARROCKS_BOOL_TYPES, raw_type: None },
            ExpectedColumn { name: "int_value", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "float_value", column_types: &[ColumnType::Float64], raw_type: None },
            ExpectedColumn { name: "text_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "fixed_text_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "decimal_value", column_types: &[ColumnType::Decimal], raw_type: None },
            ExpectedColumn { name: "date_value", column_types: &[ColumnType::Date], raw_type: None },
            ExpectedColumn { name: "timestamp_value", column_types: &[ColumnType::Timestamp], raw_type: None },
            ExpectedColumn { name: "largeint_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "json_value", column_types: STARROCKS_JSON_TYPES, raw_type: None },
        ],
    );
    assert_eq!(result_set.value(0, 0)?, Value::Int64(1));
    match columns[1].column_type {
        ColumnType::Boolean => assert_eq!(result_set.value(0, 1)?, Value::Boolean(true)),
        _ => assert_eq!(result_set.value(0, 1)?, Value::Int8(1)),
    }
    assert_eq!(result_set.value(0, 2)?, Value::Int64(42));
    assert_eq!(result_set.value(0, 3)?, Value::Float64(3.5));
    assert_eq!(result_set.value(0, 4)?, Value::Text("alpha".to_owned()));
    assert_eq!(result_set.value(0, 5)?, Value::Text("omega".to_owned()));
    assert_eq!(result_set.value(0, 6)?, Value::Text("123.45".to_owned()));
    assert_eq!(result_set.value(0, 7)?, Value::Text("2024-01-02".to_owned()));
    assert_matches_text_prefix(result_set.value(0, 8)?, "2024-01-02T03:04:05");
    assert_eq!(
        result_set.value(0, 9)?,
        Value::Text("123456789012345678901234567890".to_owned())
    );
    match columns[10].column_type {
        ColumnType::Json => assert_eq!(result_set.value(0, 10)?, Value::Text("{\"enabled\": true, \"count\": 1}".to_owned())),
        _ => assert_contains_text(result_set.value(0, 10)?, "\"enabled\""),
    }
    result_set.close()?;

    let cursor = connection.cursor(&format!(
        "select id, bool_value, int_value, float_value, text_value, fixed_text_value, decimal_value, date_value, timestamp_value, largeint_value, json_value from {table_name} order by id"
    ))?;
    assert_columns_match(
        &cursor.columns()?,
        &[
            ExpectedColumn { name: "id", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "bool_value", column_types: STARROCKS_BOOL_TYPES, raw_type: None },
            ExpectedColumn { name: "int_value", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "float_value", column_types: &[ColumnType::Float64], raw_type: None },
            ExpectedColumn { name: "text_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "fixed_text_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "decimal_value", column_types: &[ColumnType::Decimal], raw_type: None },
            ExpectedColumn { name: "date_value", column_types: &[ColumnType::Date], raw_type: None },
            ExpectedColumn { name: "timestamp_value", column_types: &[ColumnType::Timestamp], raw_type: None },
            ExpectedColumn { name: "largeint_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "json_value", column_types: STARROCKS_JSON_TYPES, raw_type: None },
        ],
    );
    assert!(cursor.next()?);
    assert!(!cursor.next()?);
    cursor.close()?;

    Ok(())
}

fn assert_starrocks_additional_type_coverage(
    connection: &aq_database::Connection,
) -> Result<(), Box<dyn std::error::Error>> {
    let result_set = connection.execute(STARROCKS_ADDITIONAL_TYPES_SQL)?;
    assert_columns_match(
        &result_set.columns()?,
        &[
            ExpectedColumn { name: "tiny_value", column_types: &[ColumnType::Int8], raw_type: None },
            ExpectedColumn { name: "small_value", column_types: &[ColumnType::Int16], raw_type: None },
            ExpectedColumn { name: "int_value", column_types: &[ColumnType::Int32], raw_type: None },
            ExpectedColumn { name: "big_value", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "float_value", column_types: &[ColumnType::Float32], raw_type: None },
            ExpectedColumn { name: "double_value", column_types: &[ColumnType::Float64], raw_type: None },
            ExpectedColumn { name: "array_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "map_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "struct_value", column_types: &[ColumnType::Text], raw_type: None },
        ],
    );
    assert_eq!(result_set.value(0, 0)?, Value::Int8(1));
    assert_eq!(result_set.value(0, 1)?, Value::Int16(2));
    assert_eq!(result_set.value(0, 2)?, Value::Int32(3));
    assert_eq!(result_set.value(0, 3)?, Value::Int64(4));
    assert_eq!(result_set.value(0, 4)?, Value::Float32(5.5));
    assert_eq!(result_set.value(0, 5)?, Value::Float64(6.5));
    assert_eq!(result_set.value(0, 6)?, Value::Text("[1,2,3]".to_owned()));
    assert_eq!(result_set.value(0, 7)?, Value::Text("{\"a\":1,\"b\":2}".to_owned()));
    assert_eq!(result_set.value(0, 8)?, Value::Text("{\"col1\":1,\"col2\":\"alpha\"}".to_owned()));
    result_set.close()?;

    let sketch_result = connection.execute(STARROCKS_SKETCH_TYPES_SQL)?;
    assert_columns_match(
        &sketch_result.columns()?,
        &[
            ExpectedColumn { name: "bitmap_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "hll_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "percentile_value", column_types: &[ColumnType::Binary], raw_type: None },
        ],
    );
    assert_eq!(sketch_result.value(0, 0)?, Value::Null);
    assert_eq!(sketch_result.value(0, 1)?, Value::Null);
    assert_eq!(sketch_result.value(0, 2)?, Value::Null);
    sketch_result.close()?;

    Ok(())
}

fn assert_contains_text(value: Value, needle: &str) {
    match value {
        Value::Text(text) => assert!(text.contains(needle), "expected `{text}` to contain `{needle}`"),
        other => panic!("expected text value, got {other:?}"),
    }
}

fn assert_matches_text_prefix(value: Value, prefix: &str) {
    match value {
        Value::Text(text) => assert!(text.starts_with(prefix), "expected `{text}` to start with `{prefix}`"),
        other => panic!("expected text value, got {other:?}"),
    }
}

fn is_runtime_unavailable(error: &aq_database::Error) -> bool {
    let message = error.to_string();
    message.contains("Could not load")
        || message.contains("Library not loaded")
        || message.contains("connection refused")
    || message.contains("timed out")
}