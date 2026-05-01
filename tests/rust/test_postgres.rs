mod support;

use aq_database::{ColumnType, Value};
use support::{
    assert_columns_match, assert_table_qualified_name, execute_non_query, find_row_index, load_target,
    maybe_skip_configured_section, read_values, ExpectedColumn, unique_identifier,
};

const POSTGRES_DECIMAL_OR_TEXT: &[ColumnType] = &[ColumnType::Decimal, ColumnType::Text];
const POSTGRES_JSON_OR_TEXT: &[ColumnType] = &[ColumnType::Json, ColumnType::Text];

const POSTGRES_ADDITIONAL_TYPES_SQL: &str = concat!(
    "select ",
    "cast(12.34 as money) as money_value, ",
    "cast(B'1010' as bit(4)) as bit_value, ",
    "cast(B'101011' as varbit) as varbit_value, ",
    "'10.0.0.0/24'::cidr as cidr_value, ",
    "'08:00:2b:01:02:03'::macaddr as macaddr_value, ",
    "'08:00:2b:01:02:03:04:05'::macaddr8 as macaddr8_value, ",
    "to_tsvector('english', 'hello world') as tsv_value, ",
    "to_tsquery('english', 'hello & world') as tsq_value, ",
    "point(1,2) as point_value, ",
    "box(point(0,0), point(1,1)) as box_value, ",
    "'int4'::regtype as regtype_value, ",
    "time with time zone '03:04:05+02' as timetz_value, ",
    "timestamptz '2024-01-02 03:04:05+02' as timestamptz_value"
);

const POSTGRES_RANGE_AND_SYSTEM_TYPES_SQL: &str = concat!(
    "select ",
    "int4range(1,5) as range_value, ",
    "int4multirange(int4range(1,5), int4range(7,9)) as multirange_value, ",
    "42::oid as oid_value, ",
    "'pg_type'::regclass as regclass_value, ",
    "'(1,2)'::tid as tid_value, ",
    "'0/16B6C50'::pg_lsn as lsn_value"
);

#[test]
fn rust_binding_postgres_lifecycle() {
    if let Some(reason) = maybe_skip_configured_section("postgres") {
        eprintln!("skipping rust Postgres integration test: {reason}");
        return;
    }

    let target = load_target("postgres").expect("postgres target should load after skip check");
    let database_name = unique_identifier("aq_pg");
    let table_name = unique_identifier("records");
    let missing_database = unique_identifier("missing_db");

    let test_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let manager = aq_database::ConnectionManager::new()?;

        let admin_connection = match manager.connect(target.driver, &target.dsn(None)) {
            Ok(connection) => connection,
            Err(error) if is_runtime_unavailable(&error) => {
                eprintln!("skipping rust Postgres integration test at runtime: {error}");
                return Ok(());
            }
            Err(error) => return Err(Box::new(error)),
        };

        let missing_database_error = match manager.connect(target.driver, &target.dsn(Some(&missing_database))) {
            Ok(_) => panic!("missing database should fail"),
            Err(error) => error,
        };
        assert!(!missing_database_error.to_string().is_empty());
        execute_non_query(&admin_connection, &format!("create database {database_name}"))?;

        let database_result = (|| -> Result<(), Box<dyn std::error::Error>> {
            let database_connection = manager.connect(target.driver, &target.dsn(Some(&database_name)))?;
            assert!(database_connection.test()?);

            assert_postgres_type_coverage(&database_connection, &table_name)?;
            assert_postgres_additional_type_coverage(&database_connection)?;

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

            let tables_result = database_connection.get_tables(None, Some("public"))?;
            let table_names = read_values(&tables_result, 2)?;
            assert!(table_names.contains(&Value::Text(table_name.clone())));
            let namespaces = read_values(&tables_result, 1)?;
            assert!(namespaces.contains(&Value::Text("public".to_owned())));
            let table_row = find_row_index(&tables_result, 2, &Value::Text(table_name.clone()))?;
            assert_table_qualified_name(&tables_result, table_row)?;
            tables_result.close()?;

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

fn assert_postgres_type_coverage(
    connection: &aq_database::Connection,
    table_name: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    execute_non_query(
        connection,
        &format!(
            "create table {table_name} (id bigint primary key, bool_value boolean not null, int_value bigint not null, float_value double precision not null, text_value text not null, binary_value bytea not null, decimal_value numeric(10, 2) not null, date_value date not null, time_value time not null, interval_value interval not null, uuid_value uuid not null, xml_value xml not null, array_value integer[] not null, inet_value inet not null, timestamp_value timestamp not null, json_value jsonb not null)"
        ),
    )?;

    execute_non_query(
        connection,
        &format!(
            "insert into {table_name} (id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value) values (1, true, 42, 3.5, 'alpha', decode('0102ff', 'hex'), 123.45, date '2024-01-02', time '03:04:05', interval '1 day 2 seconds', '550e8400-e29b-41d4-a716-446655440000'::uuid, xmlparse(document '<a>1</a>'), array[1,2,3], inet '127.0.0.1', timestamp '2024-01-02 03:04:05', '{{\"enabled\":true,\"count\":1}}'::jsonb)"
        ),
    )?;

    let result_set = connection.execute(&format!(
        "select id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value from {table_name} order by id"
    ))?;
    assert_eq!(result_set.row_count()?, 1);
    let columns = result_set.columns()?;
    assert_columns_match(
        &columns,
        &[
            ExpectedColumn { name: "id", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "bool_value", column_types: &[ColumnType::Boolean], raw_type: None },
            ExpectedColumn { name: "int_value", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "float_value", column_types: &[ColumnType::Float64], raw_type: None },
            ExpectedColumn { name: "text_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "binary_value", column_types: &[ColumnType::Binary], raw_type: None },
            ExpectedColumn { name: "decimal_value", column_types: POSTGRES_DECIMAL_OR_TEXT, raw_type: None },
            ExpectedColumn { name: "date_value", column_types: &[ColumnType::Date], raw_type: None },
            ExpectedColumn { name: "time_value", column_types: &[ColumnType::Time], raw_type: None },
            ExpectedColumn { name: "interval_value", column_types: &[ColumnType::Interval], raw_type: None },
            ExpectedColumn { name: "uuid_value", column_types: &[ColumnType::Uuid], raw_type: Some("uuid") },
            ExpectedColumn { name: "xml_value", column_types: &[ColumnType::Unknown], raw_type: Some("xml") },
            ExpectedColumn { name: "array_value", column_types: &[ColumnType::Array], raw_type: None },
            ExpectedColumn { name: "inet_value", column_types: &[ColumnType::Unknown], raw_type: Some("inet") },
            ExpectedColumn { name: "timestamp_value", column_types: &[ColumnType::Timestamp], raw_type: None },
            ExpectedColumn { name: "json_value", column_types: POSTGRES_JSON_OR_TEXT, raw_type: None },
        ],
    );
    assert_eq!(result_set.value(0, 0)?, Value::Int64(1));
    assert_eq!(result_set.value(0, 1)?, Value::Boolean(true));
    assert_eq!(result_set.value(0, 2)?, Value::Int64(42));
    assert_eq!(result_set.value(0, 3)?, Value::Float64(3.5));
    assert_eq!(result_set.value(0, 4)?, Value::Text("alpha".to_owned()));
    assert_eq!(result_set.value(0, 5)?, Value::Binary(vec![0x01, 0x02, 0xff]));
    assert_eq!(result_set.value(0, 6)?, Value::Text("123.45".to_owned()));
    assert_eq!(result_set.value(0, 7)?, Value::Text("2024-01-02".to_owned()));
    assert_matches_text_prefix(result_set.value(0, 8)?, "03:04:05");
    assert_matches_text_prefix(result_set.value(0, 9)?, "P0M1DT00:00:02");
    assert_eq!(
        result_set.value(0, 10)?,
        Value::Text("550e8400-e29b-41d4-a716-446655440000".to_owned())
    );
    assert_eq!(result_set.value(0, 11)?, Value::Text("<a>1</a>".to_owned()));
    assert_eq!(result_set.value(0, 12)?, Value::Text("[1,2,3]".to_owned()));
    assert_eq!(result_set.value(0, 13)?, Value::Text("127.0.0.1".to_owned()));
    assert_matches_text_prefix(result_set.value(0, 14)?, "2024-01-02T03:04:05");
    let json_value = result_set.value(0, 15)?;
    match columns[15].column_type {
        ColumnType::Json => assert_eq!(json_value, Value::Text("{\"enabled\": true, \"count\": 1}".to_owned())),
        _ => assert_contains_text(json_value, "\"enabled\""),
    }
    result_set.close()?;

    let cursor = connection.cursor(&format!(
        "select id, bool_value, int_value, float_value, text_value, binary_value, decimal_value, date_value, time_value, interval_value, uuid_value, xml_value, array_value, inet_value, timestamp_value, json_value from {table_name} order by id"
    ))?;
    let cursor_columns = cursor.columns()?;
    assert_columns_match(
        &cursor_columns,
        &[
            ExpectedColumn { name: "id", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "bool_value", column_types: &[ColumnType::Boolean], raw_type: None },
            ExpectedColumn { name: "int_value", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "float_value", column_types: &[ColumnType::Float64], raw_type: None },
            ExpectedColumn { name: "text_value", column_types: &[ColumnType::Text], raw_type: None },
            ExpectedColumn { name: "binary_value", column_types: &[ColumnType::Binary], raw_type: None },
            ExpectedColumn { name: "decimal_value", column_types: POSTGRES_DECIMAL_OR_TEXT, raw_type: None },
            ExpectedColumn { name: "date_value", column_types: &[ColumnType::Date], raw_type: None },
            ExpectedColumn { name: "time_value", column_types: &[ColumnType::Time], raw_type: None },
            ExpectedColumn { name: "interval_value", column_types: &[ColumnType::Interval], raw_type: None },
            ExpectedColumn { name: "uuid_value", column_types: &[ColumnType::Uuid], raw_type: Some("uuid") },
            ExpectedColumn { name: "xml_value", column_types: &[ColumnType::Unknown], raw_type: Some("xml") },
            ExpectedColumn { name: "array_value", column_types: &[ColumnType::Array], raw_type: None },
            ExpectedColumn { name: "inet_value", column_types: &[ColumnType::Unknown], raw_type: Some("inet") },
            ExpectedColumn { name: "timestamp_value", column_types: &[ColumnType::Timestamp], raw_type: None },
            ExpectedColumn { name: "json_value", column_types: POSTGRES_JSON_OR_TEXT, raw_type: None },
        ],
    );
    assert!(cursor.next()?);
    assert!(!cursor.next()?);
    cursor.close()?;

    Ok(())
}

fn assert_postgres_additional_type_coverage(
    connection: &aq_database::Connection,
) -> Result<(), Box<dyn std::error::Error>> {
    let enum_name = unique_identifier("status_enum");
    execute_non_query(connection, &format!("create type {enum_name} as enum ('new', 'done')"))?;
    let enum_result = connection.execute(&format!("select 'new'::{enum_name} as enum_value"))?;
    let enum_columns = enum_result.columns()?;
    assert_eq!(enum_columns.len(), 1);
    assert_eq!(enum_columns[0].name, "enum_value");
    assert_eq!(enum_columns[0].column_type, ColumnType::Binary);
    assert_eq!(enum_result.value(0, 0)?, Value::Binary(b"new".to_vec()));
    enum_result.close()?;
    execute_non_query(connection, &format!("drop type if exists {enum_name}"))?;

    let result_set = connection.execute(POSTGRES_ADDITIONAL_TYPES_SQL)?;
    assert_columns_match(
        &result_set.columns()?,
        &[
            ExpectedColumn { name: "money_value", column_types: &[ColumnType::Int64], raw_type: None },
            ExpectedColumn { name: "bit_value", column_types: &[ColumnType::Binary], raw_type: None },
            ExpectedColumn { name: "varbit_value", column_types: &[ColumnType::Binary], raw_type: None },
            ExpectedColumn { name: "cidr_value", column_types: &[ColumnType::Unknown], raw_type: Some("cidr") },
            ExpectedColumn { name: "macaddr_value", column_types: &[ColumnType::Unknown], raw_type: Some("macaddr") },
            ExpectedColumn { name: "macaddr8_value", column_types: &[ColumnType::Unknown], raw_type: Some("macaddr8") },
            ExpectedColumn { name: "tsv_value", column_types: &[ColumnType::Unknown], raw_type: Some("tsvector") },
            ExpectedColumn { name: "tsq_value", column_types: &[ColumnType::Unknown], raw_type: Some("tsquery") },
            ExpectedColumn { name: "point_value", column_types: &[ColumnType::Unknown], raw_type: Some("point") },
            ExpectedColumn { name: "box_value", column_types: &[ColumnType::Unknown], raw_type: Some("box") },
            ExpectedColumn { name: "regtype_value", column_types: &[ColumnType::Binary], raw_type: Some("regtype") },
            ExpectedColumn { name: "timetz_value", column_types: &[ColumnType::Time], raw_type: None },
            ExpectedColumn { name: "timestamptz_value", column_types: &[ColumnType::Timestamp], raw_type: None },
        ],
    );
    assert_eq!(result_set.value(0, 0)?, Value::Int64(1234));
    assert_binary_non_empty(result_set.value(0, 1)?);
    assert_binary_non_empty(result_set.value(0, 2)?);
    assert_eq!(result_set.value(0, 3)?, Value::Text("10.0.0.0/24".to_owned()));
    assert_eq!(result_set.value(0, 4)?, Value::Text("08:00:2b:01:02:03".to_owned()));
    assert_eq!(result_set.value(0, 5)?, Value::Text("08:00:2b:01:02:03:04:05".to_owned()));
    assert_eq!(result_set.value(0, 6)?, Value::Text("'hello':1 'world':2".to_owned()));
    assert_eq!(result_set.value(0, 7)?, Value::Text("'hello' & 'world'".to_owned()));
    assert_eq!(result_set.value(0, 8)?, Value::Text("(1,2)".to_owned()));
    assert_eq!(result_set.value(0, 9)?, Value::Text("(1,1),(0,0)".to_owned()));
    assert_eq!(result_set.value(0, 10)?, Value::Binary(vec![0x23]));
    assert_binary_or_hex_text_non_empty(result_set.value(0, 11)?);
    assert_matches_text_prefix(result_set.value(0, 12)?, "2024-01-02T01:04:05");
    result_set.close()?;

    let range_result = connection.execute(POSTGRES_RANGE_AND_SYSTEM_TYPES_SQL)?;
    assert_columns_match(
        &range_result.columns()?,
        &[
            ExpectedColumn { name: "range_value", column_types: &[ColumnType::Binary], raw_type: None },
            ExpectedColumn { name: "multirange_value", column_types: &[ColumnType::Binary], raw_type: None },
            ExpectedColumn { name: "oid_value", column_types: &[ColumnType::Int32], raw_type: None },
            ExpectedColumn { name: "regclass_value", column_types: &[ColumnType::Binary], raw_type: Some("regclass") },
            ExpectedColumn { name: "tid_value", column_types: &[ColumnType::Unknown], raw_type: Some("tid") },
            ExpectedColumn { name: "lsn_value", column_types: &[ColumnType::Unknown], raw_type: Some("pg_lsn") },
        ],
    );
    assert_eq!(
        range_result.value(0, 0)?,
        Value::Binary(vec![0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05])
    );
    assert_eq!(
        range_result.value(0, 1)?,
        Value::Binary(vec![
            0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x11, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00,
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
            0x11, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x04,
            0x00, 0x00, 0x00, 0x09,
        ])
    );
    assert_eq!(range_result.value(0, 2)?, Value::Int32(42));
    assert_eq!(range_result.value(0, 3)?, Value::Binary(vec![0x12, 0x47]));
    assert_eq!(range_result.value(0, 4)?, Value::Text("(1,2)".to_owned()));
    assert_eq!(range_result.value(0, 5)?, Value::Text("0/16B6C50".to_owned()));
    range_result.close()?;

    let pseudo_result = connection.execute("select null::anyelement as pseudo_value")?;
    assert_columns_match(
        &pseudo_result.columns()?,
        &[ExpectedColumn { name: "pseudo_value", column_types: &[ColumnType::Text], raw_type: None }],
    );
    assert_eq!(pseudo_result.value(0, 0)?, Value::Null);
    pseudo_result.close()?;

    let row_error = match connection.execute("select row(1, 'alpha') as row_value") {
        Ok(_) => panic!("anonymous row values should fail"),
        Err(error) => error,
    };
    assert!(row_error.to_string().contains("internal error"));

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

fn assert_binary_non_empty(value: Value) {
    match value {
        Value::Binary(bytes) => assert!(!bytes.is_empty(), "expected non-empty binary value"),
        other => panic!("expected binary value, got {other:?}"),
    }
}

fn assert_binary_or_hex_text_non_empty(value: Value) {
    match value {
        Value::Binary(bytes) => assert!(!bytes.is_empty(), "expected non-empty binary value"),
        Value::Text(text) => {
            assert!(!text.is_empty(), "expected non-empty text value");
            assert_eq!(text.len() % 2, 0, "expected even-length hexadecimal text");
            assert!(text.chars().all(|character| character.is_ascii_hexdigit()));
        }
        other => panic!("expected binary or hexadecimal text, got {other:?}"),
    }
}

fn is_runtime_unavailable(error: &aq_database::Error) -> bool {
    let message = error.to_string();
    message.contains("Could not load")
        || message.contains("Library not loaded")
        || message.contains("connection refused")
        || message.contains("timed out")
        || message.contains("aq_connection_open failed:")
}