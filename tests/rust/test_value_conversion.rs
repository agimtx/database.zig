mod support;

use aq_database::{decode_value, ColumnType, NamespaceAccess, QualifiedName, QualifiedNamePart, QualifiedNamePartRole, Value};

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

#[test]
fn rust_binding_namespace_access_keeps_typed_qualified_names() {
    let access = NamespaceAccess {
        can_get_schema: true,
        has_catalog_access: true,
        has_namespace_access: true,
        namespace_role: QualifiedNamePartRole::Schema,
        qualified_name: QualifiedName {
            parts: vec![
                QualifiedNamePart {
                    role: QualifiedNamePartRole::Catalog,
                    value: "analytics".to_owned(),
                },
                QualifiedNamePart {
                    role: QualifiedNamePartRole::Schema,
                    value: "public".to_owned(),
                },
            ],
            formatted: "analytics.public".to_owned(),
        },
    };

    assert!(access.can_get_schema);
    assert_eq!(access.namespace_role, QualifiedNamePartRole::Schema);
    assert_eq!(access.qualified_name.to_string(), "analytics.public");
}