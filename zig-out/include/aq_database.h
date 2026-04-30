#ifndef AQ_DATABASE_H
#define AQ_DATABASE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum aq_driver_kind {
    AQ_DRIVER_ADBC = 1
};

enum aq_status {
    AQ_OK = 0,
    AQ_INVALID_ARGUMENT = 1,
    AQ_DRIVER_NOT_REGISTERED = 2,
    AQ_CONNECTION_NOT_FOUND = 3,
    AQ_RESULT_SET_NOT_FOUND = 4,
    AQ_CURSOR_NOT_FOUND = 5,
    AQ_COLUMN_INDEX_OUT_OF_BOUNDS = 6,
    AQ_ROW_INDEX_OUT_OF_BOUNDS = 7,
    AQ_OPERATION_NOT_FOUND = 8,
    AQ_INTERNAL_ERROR = 255
};

enum aq_operation_state {
    AQ_OPERATION_PENDING = 0,
    AQ_OPERATION_RUNNING = 1,
    AQ_OPERATION_SUCCEEDED = 2,
    AQ_OPERATION_FAILED = 3
};

enum aq_column_type {
    AQ_COLUMN_UNKNOWN = 0,
    AQ_COLUMN_BOOLEAN = 1,
    AQ_COLUMN_INT64 = 2,
    AQ_COLUMN_FLOAT64 = 3,
    AQ_COLUMN_TEXT = 4,
    AQ_COLUMN_BINARY = 5,
    AQ_COLUMN_DECIMAL = 6,
    AQ_COLUMN_TIMESTAMP = 7,
    AQ_COLUMN_JSON = 8,
    AQ_COLUMN_DATE = 9,
    AQ_COLUMN_TIME = 10,
    AQ_COLUMN_INTERVAL = 11,
    AQ_COLUMN_UUID = 12,
    AQ_COLUMN_XML = 13,
    AQ_COLUMN_ARRAY = 14,
    AQ_COLUMN_MAP = 15,
    AQ_COLUMN_STRUCT = 16
};

struct aq_column_metadata {
    const uint8_t *name_ptr;
    uintptr_t name_len;
    int32_t column_type;
    uint8_t nullable;
};

struct aq_result_cell {
    const uint8_t *text_ptr;
    uintptr_t text_len;
    uint8_t is_null;
};

struct aq_operation_result {
    uint8_t state;
    int32_t status;
    uint64_t value;
};

struct aq_error_message {
    const uint8_t *message_ptr;
    uintptr_t message_len;
};

void *aq_manager_create(void);
void aq_manager_destroy(void *manager);
uint64_t aq_connection_open(void *manager, int32_t driver_kind, const char *dsn);
uint64_t aq_connection_open_async(void *manager, int32_t driver_kind, const char *dsn);
int32_t aq_connection_close(void *manager, uint64_t connection_id);
uint64_t aq_connection_execute(void *manager, uint64_t connection_id, const char *sql);
uint64_t aq_connection_execute_async(void *manager, uint64_t connection_id, const char *sql);
int32_t aq_connection_test(void *manager, uint64_t connection_id, uint8_t *out_ok);
uint64_t aq_connection_get_tables(void *manager, uint64_t connection_id, const char *catalog, const char *database);
uint64_t aq_connection_get_databases(void *manager, uint64_t connection_id);
uint64_t aq_connection_get_database(void *manager, uint64_t connection_id);
int32_t aq_result_set_close(void *manager, uint64_t result_set_id);
int32_t aq_result_set_row_count(void *manager, uint64_t result_set_id, uint64_t *out_row_count);
int32_t aq_result_set_affected_rows(void *manager, uint64_t result_set_id, uint64_t *out_affected_rows);
int32_t aq_result_set_column_count(void *manager, uint64_t result_set_id, uintptr_t *out_column_count);
int32_t aq_result_set_column_metadata(void *manager, uint64_t result_set_id, uintptr_t column_index, struct aq_column_metadata *out_metadata);
int32_t aq_result_set_value(void *manager, uint64_t result_set_id, uintptr_t row_index, uintptr_t column_index, struct aq_result_cell *out_cell);
uint64_t aq_cursor_open(void *manager, uint64_t connection_id, const char *sql);
uint64_t aq_cursor_open_async(void *manager, uint64_t connection_id, const char *sql);
int32_t aq_cursor_next(void *manager, uint64_t cursor_id, uint8_t *out_has_row);
int32_t aq_cursor_close(void *manager, uint64_t cursor_id);
int32_t aq_cursor_column_count(void *manager, uint64_t cursor_id, uintptr_t *out_column_count);
int32_t aq_cursor_column_metadata(void *manager, uint64_t cursor_id, uintptr_t column_index, struct aq_column_metadata *out_metadata);
uint64_t aq_manager_open(void *manager, int32_t driver_kind, const char *dsn);
uint64_t aq_manager_open_async(void *manager, int32_t driver_kind, const char *dsn);
int32_t aq_manager_close(void *manager, uint64_t connection_id);
int32_t aq_operation_await(void *manager, uint64_t operation_id, struct aq_operation_result *out_result);
int32_t aq_last_error_message(void *manager, struct aq_error_message *out_message);

#ifdef __cplusplus
}
#endif

#endif
