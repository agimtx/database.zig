#ifndef DATABASE_ZIG_H
#define DATABASE_ZIG_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum dbz_driver_kind {
    DBZ_DRIVER_ADBC = 1
};

enum dbz_status {
    DBZ_OK = 0,
    DBZ_INVALID_ARGUMENT = 1,
    DBZ_DRIVER_NOT_REGISTERED = 2,
    DBZ_CONNECTION_NOT_FOUND = 3,
    DBZ_RESULT_SET_NOT_FOUND = 4,
    DBZ_CURSOR_NOT_FOUND = 5,
    DBZ_COLUMN_INDEX_OUT_OF_BOUNDS = 6,
    DBZ_INTERNAL_ERROR = 255
};

enum dbz_column_type {
    DBZ_COLUMN_UNKNOWN = 0,
    DBZ_COLUMN_BOOLEAN = 1,
    DBZ_COLUMN_INT64 = 2,
    DBZ_COLUMN_FLOAT64 = 3,
    DBZ_COLUMN_TEXT = 4,
    DBZ_COLUMN_BINARY = 5,
    DBZ_COLUMN_DECIMAL = 6,
    DBZ_COLUMN_TIMESTAMP = 7,
    DBZ_COLUMN_JSON = 8
};

struct dbz_column_metadata {
    const uint8_t *name_ptr;
    uintptr_t name_len;
    int32_t column_type;
    uint8_t nullable;
};

void *dbz_manager_create(void);
void dbz_manager_destroy(void *manager);
uint64_t dbz_connection_open(void *manager, int32_t driver_kind, const char *dsn);
int32_t dbz_connection_close(void *manager, uint64_t connection_id);
uint64_t dbz_connection_execute(void *manager, uint64_t connection_id, const char *sql);
int32_t dbz_result_set_close(void *manager, uint64_t result_set_id);
int32_t dbz_result_set_row_count(void *manager, uint64_t result_set_id, uint64_t *out_row_count);
int32_t dbz_result_set_affected_rows(void *manager, uint64_t result_set_id, uint64_t *out_affected_rows);
int32_t dbz_result_set_column_count(void *manager, uint64_t result_set_id, uintptr_t *out_column_count);
int32_t dbz_result_set_column_metadata(void *manager, uint64_t result_set_id, uintptr_t column_index, struct dbz_column_metadata *out_metadata);
uint64_t dbz_cursor_open(void *manager, uint64_t connection_id, const char *sql);
int32_t dbz_cursor_next(void *manager, uint64_t cursor_id, uint8_t *out_has_row);
int32_t dbz_cursor_close(void *manager, uint64_t cursor_id);
int32_t dbz_cursor_column_count(void *manager, uint64_t cursor_id, uintptr_t *out_column_count);
int32_t dbz_cursor_column_metadata(void *manager, uint64_t cursor_id, uintptr_t column_index, struct dbz_column_metadata *out_metadata);
uint64_t dbz_manager_open(void *manager, int32_t driver_kind, const char *dsn);
int32_t dbz_manager_close(void *manager, uint64_t connection_id);

#ifdef __cplusplus
}
#endif

#endif
