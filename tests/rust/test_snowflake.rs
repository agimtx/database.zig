use aq_database::{ConnectionManager, Value};
use support::{load_target, maybe_skip_configured_section, read_values};

mod support;

#[test]
fn rust_binding_snowflake_catalogs() {
    if let Some(reason) = maybe_skip_configured_section("snowflake") {
        eprintln!("skipping rust Snowflake integration test: {reason}");
        return;
    }

    let target = load_target("snowflake").expect("snowflake target should load after skip check");
    let test_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let manager = ConnectionManager::new()?;

        let connection = match manager.connect(target.driver, &target.dsn(None)) {
            Ok(connection) => connection,
            Err(error) if is_runtime_unavailable(&error) => {
                eprintln!("skipping rust Snowflake integration test at runtime: {error}");
                return Ok(());
            }
            Err(error) => return Err(Box::new(error)),
        };

        assert!(connection.test()?);

        let databases_result = connection.get_databases()?;
        let database_names = read_values(&databases_result, 0)?;
        assert!(database_names.iter().any(|value| match value {
            Value::Text(text) => !text.is_empty(),
            _ => false,
        }));
        databases_result.close()?;

        let catalogs_result = connection.get_catalogs()?;
        let catalog_names = read_values(&catalogs_result, 0)?;
        assert!(catalog_names.iter().any(|value| match value {
            Value::Text(text) => !text.is_empty(),
            _ => false,
        }));
        catalogs_result.close()?;

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
}