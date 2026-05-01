use aq_database::ConnectionManager;
use support::{load_target, maybe_skip_configured_section, read_values};

mod support;

#[test]
fn rust_binding_exasol_catalogs() {
    if let Some(reason) = maybe_skip_configured_section("exasol") {
        eprintln!("skipping rust Exasol integration test: {reason}");
        return;
    }

    let target = load_target("exasol").expect("exasol target should load after skip check");
    let test_result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let manager = ConnectionManager::new()?;

        let connection = match manager.connect(target.driver, &target.dsn(None)) {
            Ok(connection) => connection,
            Err(error) if is_runtime_unavailable(&error) => {
                eprintln!("skipping rust Exasol integration test at runtime: {error}");
                return Ok(());
            }
            Err(error) => return Err(Box::new(error)),
        };

        assert!(connection.test()?);

        let databases_result = connection.get_databases()?;
        let database_names = read_values(&databases_result, 0)?;
        assert!(!database_names.is_empty());
        databases_result.close()?;

        let catalogs_error = match connection.get_catalogs() {
            Ok(_) => panic!("exasol targets should reject get_catalogs"),
            Err(error) => error,
        };
        assert!(catalogs_error.to_string().contains("get catalogs is not supported"));

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