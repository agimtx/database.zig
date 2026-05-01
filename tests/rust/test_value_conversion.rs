mod support;

use aq_database::{decode_value, ColumnType, Value};

#[test]
fn rust_binding_returns_typed_scalars() {
    assert_eq!(decode_value(Some("true"), ColumnType::Boolean), Value::Boolean(true));
    assert_eq!(decode_value(Some("42"), ColumnType::Int32), Value::Int32(42));
    assert_eq!(decode_value(Some("42"), ColumnType::Int64), Value::Int64(42));
    assert_eq!(decode_value(Some("42"), ColumnType::UInt64), Value::UInt64(42));
    assert_eq!(decode_value(Some("3.5"), ColumnType::Float32), Value::Float32(3.5));
    assert_eq!(decode_value(Some("3.5"), ColumnType::Float64), Value::Float64(3.5));
}

#[test]
fn rust_binding_decodes_binary_and_preserves_textual_types() {
    assert_eq!(
        decode_value(Some("0102ff"), ColumnType::Binary),
        Value::Binary(vec![0x01, 0x02, 0xff])
    );
    assert_eq!(
        decode_value(Some("123.45"), ColumnType::Decimal),
        Value::Text("123.45".to_owned())
    );
    assert_eq!(
        decode_value(Some("{\"enabled\":true}"), ColumnType::Json),
        Value::Text("{\"enabled\":true}".to_owned())
    );
    assert_eq!(decode_value(None, ColumnType::Text), Value::Null);
}