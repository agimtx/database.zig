use std::cell::Cell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::fmt;
use std::path::{Path, PathBuf};
use std::ptr;
use std::rc::Rc;
use std::slice;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum DriverKind {
    Adbc = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Status {
    Ok = 0,
    InvalidArgument = 1,
    DriverNotRegistered = 2,
    ConnectionNotFound = 3,
    ResultSetNotFound = 4,
    CursorNotFound = 5,
    ColumnIndexOutOfBounds = 6,
    RowIndexOutOfBounds = 7,
    OperationNotFound = 8,
    InternalError = 255,
}

impl Status {
    fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::Ok),
            1 => Some(Self::InvalidArgument),
            2 => Some(Self::DriverNotRegistered),
            3 => Some(Self::ConnectionNotFound),
            4 => Some(Self::ResultSetNotFound),
            5 => Some(Self::CursorNotFound),
            6 => Some(Self::ColumnIndexOutOfBounds),
            7 => Some(Self::RowIndexOutOfBounds),
            8 => Some(Self::OperationNotFound),
            255 => Some(Self::InternalError),
            _ => None,
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::InvalidArgument => "invalid argument",
            Self::DriverNotRegistered => "driver not registered",
            Self::ConnectionNotFound => "connection not found",
            Self::ResultSetNotFound => "result set not found",
            Self::CursorNotFound => "cursor not found",
            Self::ColumnIndexOutOfBounds => "column index out of bounds",
            Self::RowIndexOutOfBounds => "row index out of bounds",
            Self::OperationNotFound => "operation not found",
            Self::InternalError => "internal error",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum ColumnType {
    Unknown = 0,
    Boolean = 1,
    Int64 = 2,
    Float64 = 3,
    Text = 4,
    Binary = 5,
    Decimal = 6,
    Timestamp = 7,
    Json = 8,
    Date = 9,
    Time = 10,
    Interval = 11,
    Uuid = 12,
    Array = 13,
    Map = 14,
    Struct = 15,
    Int8 = 16,
    UInt8 = 17,
    Int16 = 18,
    UInt16 = 19,
    Int32 = 20,
    UInt32 = 21,
    UInt64 = 22,
    Float16 = 23,
    Float32 = 24,
    Duration = 25,
}

impl ColumnType {
    fn from_raw(value: i32) -> Self {
        match value {
            1 => Self::Boolean,
            2 => Self::Int64,
            3 => Self::Float64,
            4 => Self::Text,
            5 => Self::Binary,
            6 => Self::Decimal,
            7 => Self::Timestamp,
            8 => Self::Json,
            9 => Self::Date,
            10 => Self::Time,
            11 => Self::Interval,
            12 => Self::Uuid,
            13 => Self::Array,
            14 => Self::Map,
            15 => Self::Struct,
            16 => Self::Int8,
            17 => Self::UInt8,
            18 => Self::Int16,
            19 => Self::UInt16,
            20 => Self::Int32,
            21 => Self::UInt32,
            22 => Self::UInt64,
            23 => Self::Float16,
            24 => Self::Float32,
            25 => Self::Duration,
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum QualifiedNamePartRole {
    Catalog = 0,
    Database = 1,
    Schema = 2,
    Dataset = 3,
    Namespace = 4,
    Object = 5,
}

impl QualifiedNamePartRole {
    fn from_raw(value: i32) -> Option<Self> {
        match value {
            0 => Some(Self::Catalog),
            1 => Some(Self::Database),
            2 => Some(Self::Schema),
            3 => Some(Self::Dataset),
            4 => Some(Self::Namespace),
            5 => Some(Self::Object),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnMetadata {
    pub name: String,
    pub raw_type: Option<String>,
    pub column_type: ColumnType,
    pub nullable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QualifiedNamePart {
    pub role: QualifiedNamePartRole,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QualifiedName {
    pub parts: Vec<QualifiedNamePart>,
    pub formatted: String,
}

impl fmt::Display for QualifiedName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.formatted)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Boolean(bool),
    Int8(i8),
    UInt8(u8),
    Int16(i16),
    UInt16(u16),
    Int32(i32),
    UInt32(u32),
    Int64(i64),
    UInt64(u64),
    Float32(f32),
    Float64(f64),
    Binary(Vec<u8>),
    Text(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    Library,
    InvalidInput,
    Status,
    Closed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    message: String,
    status: Option<Status>,
}

impl Error {
    fn library(message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Library,
            message: message.into(),
            status: None,
        }
    }

    fn invalid_input(message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::InvalidInput,
            message: message.into(),
            status: None,
        }
    }

    fn closed(message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Closed,
            message: message.into(),
            status: None,
        }
    }

    fn status(status: Option<Status>, message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Status,
            message: message.into(),
            status,
        }
    }

    pub fn kind(&self) -> &ErrorKind {
        &self.kind
    }

    pub fn status_code(&self) -> Option<Status> {
        self.status
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

type Result<T> = std::result::Result<T, Error>;

#[repr(C)]
struct AqColumnMetadata {
    name_ptr: *const u8,
    name_len: usize,
    raw_type_ptr: *const u8,
    raw_type_len: usize,
    column_type: i32,
    nullable: u8,
}

#[repr(C)]
struct AqResultCell {
    text_ptr: *const u8,
    text_len: usize,
    is_null: u8,
}

#[repr(C)]
struct AqQualifiedNamePart {
    role: i32,
    value_ptr: *const u8,
    value_len: usize,
}

#[repr(C)]
struct AqQualifiedName {
    part_count: usize,
    formatted_ptr: *const u8,
    formatted_len: usize,
    parts: [AqQualifiedNamePart; 3],
}

#[repr(C)]
struct AqOperationResult {
    state: u8,
    _padding: [u8; 3],
    status: i32,
    value: u64,
}

#[repr(C)]
struct AqErrorMessage {
    message_ptr: *const u8,
    message_len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
enum OperationState {
    Pending = 0,
    Running = 1,
    Succeeded = 2,
    Failed = 3,
}

impl OperationState {
    fn from_raw(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Pending),
            1 => Some(Self::Running),
            2 => Some(Self::Succeeded),
            3 => Some(Self::Failed),
            _ => None,
        }
    }
}

struct Api {
    _library: DynamicLibrary,
    aq_manager_create: unsafe extern "C" fn() -> *mut c_void,
    aq_manager_destroy: unsafe extern "C" fn(*mut c_void),
    aq_connection_open: unsafe extern "C" fn(*mut c_void, i32, *const c_char) -> u64,
    aq_connection_open_async: unsafe extern "C" fn(*mut c_void, i32, *const c_char) -> u64,
    aq_connection_close: unsafe extern "C" fn(*mut c_void, u64) -> i32,
    aq_connection_execute: unsafe extern "C" fn(*mut c_void, u64, *const c_char) -> u64,
    aq_connection_execute_async: unsafe extern "C" fn(*mut c_void, u64, *const c_char) -> u64,
    aq_connection_test: unsafe extern "C" fn(*mut c_void, u64, *mut u8) -> i32,
    aq_connection_get_tables: unsafe extern "C" fn(*mut c_void, u64, *const c_char, *const c_char) -> u64,
    aq_connection_get_databases: unsafe extern "C" fn(*mut c_void, u64) -> u64,
    aq_connection_get_database: unsafe extern "C" fn(*mut c_void, u64) -> u64,
    aq_result_set_close: unsafe extern "C" fn(*mut c_void, u64) -> i32,
    aq_result_set_row_count: unsafe extern "C" fn(*mut c_void, u64, *mut u64) -> i32,
    aq_result_set_affected_rows: unsafe extern "C" fn(*mut c_void, u64, *mut u64) -> i32,
    aq_result_set_column_count: unsafe extern "C" fn(*mut c_void, u64, *mut usize) -> i32,
    aq_result_set_column_metadata: unsafe extern "C" fn(*mut c_void, u64, usize, *mut AqColumnMetadata) -> i32,
    aq_result_set_value: unsafe extern "C" fn(*mut c_void, u64, usize, usize, *mut AqResultCell) -> i32,
    aq_result_set_table_qualified_name: unsafe extern "C" fn(*mut c_void, u64, usize, *mut AqQualifiedName) -> i32,
    aq_cursor_open: unsafe extern "C" fn(*mut c_void, u64, *const c_char) -> u64,
    aq_cursor_open_async: unsafe extern "C" fn(*mut c_void, u64, *const c_char) -> u64,
    aq_cursor_next: unsafe extern "C" fn(*mut c_void, u64, *mut u8) -> i32,
    aq_cursor_close: unsafe extern "C" fn(*mut c_void, u64) -> i32,
    aq_cursor_column_count: unsafe extern "C" fn(*mut c_void, u64, *mut usize) -> i32,
    aq_cursor_column_metadata: unsafe extern "C" fn(*mut c_void, u64, usize, *mut AqColumnMetadata) -> i32,
    aq_operation_await: unsafe extern "C" fn(*mut c_void, u64, *mut AqOperationResult) -> i32,
    aq_last_error_message: unsafe extern "C" fn(*mut c_void, *mut AqErrorMessage) -> i32,
}

impl Api {
    fn load(path: &Path) -> Result<Self> {
        let library = DynamicLibrary::open(path)?;
        let aq_manager_create = unsafe { library.symbol("aq_manager_create")? };
        let aq_manager_destroy = unsafe { library.symbol("aq_manager_destroy")? };
        let aq_connection_open = unsafe { library.symbol("aq_connection_open")? };
        let aq_connection_open_async = unsafe { library.symbol("aq_connection_open_async")? };
        let aq_connection_close = unsafe { library.symbol("aq_connection_close")? };
        let aq_connection_execute = unsafe { library.symbol("aq_connection_execute")? };
        let aq_connection_execute_async = unsafe { library.symbol("aq_connection_execute_async")? };
        let aq_connection_test = unsafe { library.symbol("aq_connection_test")? };
        let aq_connection_get_tables = unsafe { library.symbol("aq_connection_get_tables")? };
        let aq_connection_get_databases = unsafe { library.symbol("aq_connection_get_databases")? };
        let aq_connection_get_database = unsafe { library.symbol("aq_connection_get_database")? };
        let aq_result_set_close = unsafe { library.symbol("aq_result_set_close")? };
        let aq_result_set_row_count = unsafe { library.symbol("aq_result_set_row_count")? };
        let aq_result_set_affected_rows = unsafe { library.symbol("aq_result_set_affected_rows")? };
        let aq_result_set_column_count = unsafe { library.symbol("aq_result_set_column_count")? };
        let aq_result_set_column_metadata = unsafe { library.symbol("aq_result_set_column_metadata")? };
        let aq_result_set_value = unsafe { library.symbol("aq_result_set_value")? };
        let aq_result_set_table_qualified_name = unsafe { library.symbol("aq_result_set_table_qualified_name")? };
        let aq_cursor_open = unsafe { library.symbol("aq_cursor_open")? };
        let aq_cursor_open_async = unsafe { library.symbol("aq_cursor_open_async")? };
        let aq_cursor_next = unsafe { library.symbol("aq_cursor_next")? };
        let aq_cursor_close = unsafe { library.symbol("aq_cursor_close")? };
        let aq_cursor_column_count = unsafe { library.symbol("aq_cursor_column_count")? };
        let aq_cursor_column_metadata = unsafe { library.symbol("aq_cursor_column_metadata")? };
        let aq_operation_await = unsafe { library.symbol("aq_operation_await")? };
        let aq_last_error_message = unsafe { library.symbol("aq_last_error_message")? };
        Ok(Self {
            _library: library,
            aq_manager_create,
            aq_manager_destroy,
            aq_connection_open,
            aq_connection_open_async,
            aq_connection_close,
            aq_connection_execute,
            aq_connection_execute_async,
            aq_connection_test,
            aq_connection_get_tables,
            aq_connection_get_databases,
            aq_connection_get_database,
            aq_result_set_close,
            aq_result_set_row_count,
            aq_result_set_affected_rows,
            aq_result_set_column_count,
            aq_result_set_column_metadata,
            aq_result_set_value,
            aq_result_set_table_qualified_name,
            aq_cursor_open,
            aq_cursor_open_async,
            aq_cursor_next,
            aq_cursor_close,
            aq_cursor_column_count,
            aq_cursor_column_metadata,
            aq_operation_await,
            aq_last_error_message,
        })
    }
}

struct ManagerInner {
    api: Api,
    handle: *mut c_void,
}

impl ManagerInner {
    fn new(library_path: &Path) -> Result<Self> {
        let api = Api::load(library_path)?;
        let handle = unsafe { (api.aq_manager_create)() };
        if handle.is_null() {
            return Err(Error::library(format!(
                "aq_manager_create failed for {}",
                library_path.display()
            )));
        }
        Ok(Self { api, handle })
    }

    fn last_error_message(&self) -> Option<String> {
        let mut message = AqErrorMessage {
            message_ptr: ptr::null(),
            message_len: 0,
        };
        let status = unsafe { (self.api.aq_last_error_message)(self.handle, &mut message) };
        if status != Status::Ok as i32 {
            return None;
        }

        bytes_to_string(message.message_ptr, message.message_len)
    }

    fn status_error(&self, operation: &str, status: i32) -> Error {
        let status_code = Status::from_raw(status);
        let detail = self.last_error_message().unwrap_or_else(|| {
            let status_message = status_code
                .map(Status::message)
                .unwrap_or("unknown status");
            status_message.to_owned()
        });
        Error::status(status_code, format!("{operation} failed: {detail}"))
    }

    fn zero_result_error(&self, operation: &str) -> Error {
        let detail = self
            .last_error_message()
            .unwrap_or_else(|| "zero result returned".to_owned());
        Error::status(None, format!("{operation} failed: {detail}"))
    }

    fn check_status(&self, operation: &str, status: i32) -> Result<()> {
        if status == Status::Ok as i32 {
            Ok(())
        } else {
            Err(self.status_error(operation, status))
        }
    }

    fn await_operation(&self, operation_id: u64) -> Result<u64> {
        if operation_id == 0 {
            return Err(self.zero_result_error("operation_start"));
        }

        let mut result = AqOperationResult {
            state: 0,
            _padding: [0; 3],
            status: 0,
            value: 0,
        };
        let status = unsafe { (self.api.aq_operation_await)(self.handle, operation_id, &mut result) };
        self.check_status("aq_operation_await", status)?;

        match OperationState::from_raw(result.state) {
            Some(OperationState::Succeeded) => Ok(result.value),
            Some(OperationState::Failed) => Err(self.status_error("aq_operation_await", result.status)),
            Some(OperationState::Pending) | Some(OperationState::Running) => {
                Err(Error::status(None, "aq_operation_await returned before operation completion"))
            }
            None => Err(Error::status(None, format!("aq_operation_await returned unknown state {}", result.state))),
        }
    }
}

impl Drop for ManagerInner {
    fn drop(&mut self) {
        unsafe { (self.api.aq_manager_destroy)(self.handle) };
    }
}

#[derive(Clone)]
pub struct ConnectionManager {
    inner: Rc<ManagerInner>,
}

impl ConnectionManager {
    pub fn new() -> Result<Self> {
        Self::with_library_path(resolve_library_path())
    }

    pub fn with_library_path<P: AsRef<Path>>(library_path: P) -> Result<Self> {
        Ok(Self {
            inner: Rc::new(ManagerInner::new(library_path.as_ref())?),
        })
    }

    pub fn last_error_message(&self) -> Option<String> {
        self.inner.last_error_message()
    }

    pub fn connect(&self, driver: DriverKind, dsn: &str) -> Result<Connection> {
        let dsn = make_c_string(dsn, "dsn")?;
        let connection_id = unsafe {
            (self.inner.api.aq_connection_open)(self.inner.handle, driver as i32, dsn.as_ptr())
        };
        if connection_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_open"));
        }
        Ok(Connection::new(self.inner.clone(), connection_id))
    }

    pub fn connect_async(&self, driver: DriverKind, dsn: &str) -> Result<Connection> {
        let dsn = make_c_string(dsn, "dsn")?;
        let operation_id = unsafe {
            (self.inner.api.aq_connection_open_async)(self.inner.handle, driver as i32, dsn.as_ptr())
        };
        let connection_id = self.inner.await_operation(operation_id)?;
        if connection_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_open_async"));
        }
        Ok(Connection::new(self.inner.clone(), connection_id))
    }
}

pub struct Connection {
    inner: Rc<ManagerInner>,
    id: Cell<u64>,
}

impl Connection {
    fn new(inner: Rc<ManagerInner>, id: u64) -> Self {
        Self {
            inner,
            id: Cell::new(id),
        }
    }

    pub fn id(&self) -> u64 {
        self.id.get()
    }

    pub fn execute(&self, sql: &str) -> Result<ResultSet> {
        let sql = make_c_string(sql, "sql")?;
        let result_set_id = unsafe {
            (self.inner.api.aq_connection_execute)(self.inner.handle, self.open_id()?, sql.as_ptr())
        };
        if result_set_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_execute"));
        }
        Ok(ResultSet::new(self.inner.clone(), result_set_id))
    }

    pub fn execute_async(&self, sql: &str) -> Result<ResultSet> {
        let sql = make_c_string(sql, "sql")?;
        let operation_id = unsafe {
            (self.inner.api.aq_connection_execute_async)(self.inner.handle, self.open_id()?, sql.as_ptr())
        };
        let result_set_id = self.inner.await_operation(operation_id)?;
        if result_set_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_execute_async"));
        }
        Ok(ResultSet::new(self.inner.clone(), result_set_id))
    }

    pub fn test(&self) -> Result<bool> {
        let mut out_ok = 0u8;
        let status = unsafe {
            (self.inner.api.aq_connection_test)(self.inner.handle, self.open_id()?, &mut out_ok)
        };
        self.inner.check_status("aq_connection_test", status)?;
        Ok(out_ok == 1)
    }

    pub fn get_tables(&self, catalog: Option<&str>, database: Option<&str>) -> Result<ResultSet> {
        let catalog = make_optional_c_string(catalog, "catalog")?;
        let database = make_optional_c_string(database, "database")?;
        let result_set_id = unsafe {
            (self.inner.api.aq_connection_get_tables)(
                self.inner.handle,
                self.open_id()?,
                catalog.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
                database.as_ref().map_or(ptr::null(), |value| value.as_ptr()),
            )
        };
        if result_set_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_get_tables"));
        }
        Ok(ResultSet::new(self.inner.clone(), result_set_id))
    }

    pub fn get_databases(&self) -> Result<ResultSet> {
        let result_set_id = unsafe {
            (self.inner.api.aq_connection_get_databases)(self.inner.handle, self.open_id()?)
        };
        if result_set_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_get_databases"));
        }
        Ok(ResultSet::new(self.inner.clone(), result_set_id))
    }

    pub fn get_database(&self) -> Result<ResultSet> {
        let result_set_id = unsafe {
            (self.inner.api.aq_connection_get_database)(self.inner.handle, self.open_id()?)
        };
        if result_set_id == 0 {
            return Err(self.inner.zero_result_error("aq_connection_get_database"));
        }
        Ok(ResultSet::new(self.inner.clone(), result_set_id))
    }

    pub fn cursor(&self, sql: &str) -> Result<Cursor> {
        let sql = make_c_string(sql, "sql")?;
        let cursor_id = unsafe {
            (self.inner.api.aq_cursor_open)(self.inner.handle, self.open_id()?, sql.as_ptr())
        };
        if cursor_id == 0 {
            return Err(self.inner.zero_result_error("aq_cursor_open"));
        }
        Ok(Cursor::new(self.inner.clone(), cursor_id))
    }

    pub fn cursor_async(&self, sql: &str) -> Result<Cursor> {
        let sql = make_c_string(sql, "sql")?;
        let operation_id = unsafe {
            (self.inner.api.aq_cursor_open_async)(self.inner.handle, self.open_id()?, sql.as_ptr())
        };
        let cursor_id = self.inner.await_operation(operation_id)?;
        if cursor_id == 0 {
            return Err(self.inner.zero_result_error("aq_cursor_open_async"));
        }
        Ok(Cursor::new(self.inner.clone(), cursor_id))
    }

    pub fn close(&self) -> Result<()> {
        let id = self.id.replace(0);
        if id == 0 {
            return Ok(());
        }
        let status = unsafe { (self.inner.api.aq_connection_close)(self.inner.handle, id) };
        self.inner.check_status("aq_connection_close", status)
    }

    fn open_id(&self) -> Result<u64> {
        let id = self.id.get();
        if id == 0 {
            Err(Error::closed("connection is already closed"))
        } else {
            Ok(id)
        }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

pub struct ResultSet {
    inner: Rc<ManagerInner>,
    id: Cell<u64>,
}

impl ResultSet {
    fn new(inner: Rc<ManagerInner>, id: u64) -> Self {
        Self {
            inner,
            id: Cell::new(id),
        }
    }

    pub fn id(&self) -> u64 {
        self.id.get()
    }

    pub fn row_count(&self) -> Result<u64> {
        let mut row_count = 0u64;
        let status = unsafe {
            (self.inner.api.aq_result_set_row_count)(self.inner.handle, self.open_id()?, &mut row_count)
        };
        self.inner.check_status("aq_result_set_row_count", status)?;
        Ok(row_count)
    }

    pub fn affected_rows(&self) -> Result<u64> {
        let mut affected_rows = 0u64;
        let status = unsafe {
            (self.inner.api.aq_result_set_affected_rows)(self.inner.handle, self.open_id()?, &mut affected_rows)
        };
        self.inner.check_status("aq_result_set_affected_rows", status)?;
        Ok(affected_rows)
    }

    pub fn columns(&self) -> Result<Vec<ColumnMetadata>> {
        let mut column_count = 0usize;
        let status = unsafe {
            (self.inner.api.aq_result_set_column_count)(self.inner.handle, self.open_id()?, &mut column_count)
        };
        self.inner.check_status("aq_result_set_column_count", status)?;

        let mut columns = Vec::with_capacity(column_count);
        for index in 0..column_count {
            let mut metadata = AqColumnMetadata {
                name_ptr: ptr::null(),
                name_len: 0,
                raw_type_ptr: ptr::null(),
                raw_type_len: 0,
                column_type: 0,
                nullable: 0,
            };
            let status = unsafe {
                (self.inner.api.aq_result_set_column_metadata)(
                    self.inner.handle,
                    self.open_id()?,
                    index,
                    &mut metadata,
                )
            };
            self.inner
                .check_status("aq_result_set_column_metadata", status)?;
            columns.push(ColumnMetadata {
                name: bytes_to_string(metadata.name_ptr, metadata.name_len).unwrap_or_default(),
                raw_type: bytes_to_string(metadata.raw_type_ptr, metadata.raw_type_len),
                column_type: ColumnType::from_raw(metadata.column_type),
                nullable: metadata.nullable == 1,
            });
        }
        Ok(columns)
    }

    pub fn value(&self, row_index: usize, column_index: usize) -> Result<Value> {
        let columns = self.columns()?;
        let column_type = columns
            .get(column_index)
            .map(|column| column.column_type)
            .unwrap_or(ColumnType::Unknown);
        let mut cell = AqResultCell {
            text_ptr: ptr::null(),
            text_len: 0,
            is_null: 0,
        };
        let status = unsafe {
            (self.inner.api.aq_result_set_value)(
                self.inner.handle,
                self.open_id()?,
                row_index,
                column_index,
                &mut cell,
            )
        };
        self.inner.check_status("aq_result_set_value", status)?;
        let raw_value = if cell.is_null == 1 {
            None
        } else {
            bytes_to_string(cell.text_ptr, cell.text_len)
        };
        Ok(decode_value(raw_value.as_deref(), column_type))
    }

    pub fn table_qualified_name(&self, row_index: usize) -> Result<QualifiedName> {
        let mut raw_name = AqQualifiedName {
            part_count: 0,
            formatted_ptr: ptr::null(),
            formatted_len: 0,
            parts: [
                AqQualifiedNamePart {
                    role: 0,
                    value_ptr: ptr::null(),
                    value_len: 0,
                },
                AqQualifiedNamePart {
                    role: 0,
                    value_ptr: ptr::null(),
                    value_len: 0,
                },
                AqQualifiedNamePart {
                    role: 0,
                    value_ptr: ptr::null(),
                    value_len: 0,
                },
            ],
        };
        let status = unsafe {
            (self.inner.api.aq_result_set_table_qualified_name)(
                self.inner.handle,
                self.open_id()?,
                row_index,
                &mut raw_name,
            )
        };
        self.inner
            .check_status("aq_result_set_table_qualified_name", status)?;

        let mut parts = Vec::with_capacity(raw_name.part_count.min(raw_name.parts.len()));
        for raw_part in raw_name.parts.iter().take(raw_name.part_count.min(raw_name.parts.len())) {
            if let Some(role) = QualifiedNamePartRole::from_raw(raw_part.role) {
                parts.push(QualifiedNamePart {
                    role,
                    value: bytes_to_string(raw_part.value_ptr, raw_part.value_len).unwrap_or_default(),
                });
            }
        }

        Ok(QualifiedName {
            parts,
            formatted: bytes_to_string(raw_name.formatted_ptr, raw_name.formatted_len).unwrap_or_default(),
        })
    }

    pub fn close(&self) -> Result<()> {
        let id = self.id.replace(0);
        if id == 0 {
            return Ok(());
        }
        let status = unsafe { (self.inner.api.aq_result_set_close)(self.inner.handle, id) };
        self.inner.check_status("aq_result_set_close", status)
    }

    fn open_id(&self) -> Result<u64> {
        let id = self.id.get();
        if id == 0 {
            Err(Error::closed("result set is already closed"))
        } else {
            Ok(id)
        }
    }
}

impl Drop for ResultSet {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

pub struct Cursor {
    inner: Rc<ManagerInner>,
    id: Cell<u64>,
}

impl Cursor {
    fn new(inner: Rc<ManagerInner>, id: u64) -> Self {
        Self {
            inner,
            id: Cell::new(id),
        }
    }

    pub fn columns(&self) -> Result<Vec<ColumnMetadata>> {
        let mut column_count = 0usize;
        let status = unsafe {
            (self.inner.api.aq_cursor_column_count)(self.inner.handle, self.open_id()?, &mut column_count)
        };
        self.inner.check_status("aq_cursor_column_count", status)?;

        let mut columns = Vec::with_capacity(column_count);
        for index in 0..column_count {
            let mut metadata = AqColumnMetadata {
                name_ptr: ptr::null(),
                name_len: 0,
                raw_type_ptr: ptr::null(),
                raw_type_len: 0,
                column_type: 0,
                nullable: 0,
            };
            let status = unsafe {
                (self.inner.api.aq_cursor_column_metadata)(
                    self.inner.handle,
                    self.open_id()?,
                    index,
                    &mut metadata,
                )
            };
            self.inner
                .check_status("aq_cursor_column_metadata", status)?;
            columns.push(ColumnMetadata {
                name: bytes_to_string(metadata.name_ptr, metadata.name_len).unwrap_or_default(),
                raw_type: bytes_to_string(metadata.raw_type_ptr, metadata.raw_type_len),
                column_type: ColumnType::from_raw(metadata.column_type),
                nullable: metadata.nullable == 1,
            });
        }
        Ok(columns)
    }

    pub fn next(&self) -> Result<bool> {
        let mut has_row = 0u8;
        let status = unsafe {
            (self.inner.api.aq_cursor_next)(self.inner.handle, self.open_id()?, &mut has_row)
        };
        self.inner.check_status("aq_cursor_next", status)?;
        Ok(has_row == 1)
    }

    pub fn close(&self) -> Result<()> {
        let id = self.id.replace(0);
        if id == 0 {
            return Ok(());
        }
        let status = unsafe { (self.inner.api.aq_cursor_close)(self.inner.handle, id) };
        self.inner.check_status("aq_cursor_close", status)
    }

    fn open_id(&self) -> Result<u64> {
        let id = self.id.get();
        if id == 0 {
            Err(Error::closed("cursor is already closed"))
        } else {
            Ok(id)
        }
    }
}

impl Drop for Cursor {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

pub fn decode_value(raw_value: Option<&str>, column_type: ColumnType) -> Value {
    let Some(raw_value) = raw_value else {
        return Value::Null;
    };

    match column_type {
        ColumnType::Boolean => match raw_value {
            "true" | "1" => Value::Boolean(true),
            "false" | "0" => Value::Boolean(false),
            _ => Value::Text(raw_value.to_owned()),
        },
        ColumnType::Int8 => raw_value.parse().map(Value::Int8).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::UInt8 => raw_value.parse().map(Value::UInt8).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::Int16 => raw_value.parse().map(Value::Int16).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::UInt16 => raw_value.parse().map(Value::UInt16).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::Int32 => raw_value.parse().map(Value::Int32).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::UInt32 => raw_value.parse().map(Value::UInt32).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::Int64 => raw_value.parse().map(Value::Int64).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::UInt64 => raw_value.parse().map(Value::UInt64).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::Float16 | ColumnType::Float32 => {
            raw_value.parse().map(Value::Float32).unwrap_or_else(|_| Value::Text(raw_value.to_owned()))
        }
        ColumnType::Float64 => raw_value.parse().map(Value::Float64).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        ColumnType::Binary => decode_hex(raw_value).map(Value::Binary).unwrap_or_else(|_| Value::Text(raw_value.to_owned())),
        _ => Value::Text(raw_value.to_owned()),
    }
}

fn make_c_string(value: &str, label: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::invalid_input(format!("{label} cannot contain NUL bytes")))
}

fn make_optional_c_string(value: Option<&str>, label: &str) -> Result<Option<CString>> {
    value.map(|item| make_c_string(item, label)).transpose()
}

fn bytes_to_string(ptr: *const u8, len: usize) -> Option<String> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    let bytes = unsafe { slice::from_raw_parts(ptr, len) };
    Some(String::from_utf8_lossy(bytes).into_owned())
}

fn decode_hex(value: &str) -> std::result::Result<Vec<u8>, ()> {
    if value.len() % 2 != 0 {
        return Err(());
    }

    let mut bytes = Vec::with_capacity(value.len() / 2);
    let raw = value.as_bytes();
    for index in (0..raw.len()).step_by(2) {
        let high = hex_nibble(raw[index]).ok_or(())?;
        let low = hex_nibble(raw[index + 1]).ok_or(())?;
        bytes.push((high << 4) | low);
    }
    Ok(bytes)
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn resolve_library_path() -> PathBuf {
    if let Ok(value) = std::env::var("AQ_DATABASE_LIBRARY_PATH") {
        return PathBuf::from(value);
    }

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .and_then(Path::parent)
        .unwrap_or(&manifest_dir)
        .join("zig-out")
        .join("lib")
        .join(platform_library_name())
}

fn platform_library_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "libaq_database.dylib"
    } else if cfg!(target_os = "windows") {
        "aq_database.dll"
    } else {
        "libaq_database.so"
    }
}

struct DynamicLibrary {
    handle: *mut c_void,
}

impl DynamicLibrary {
    fn open(path: &Path) -> Result<Self> {
        #[cfg(unix)]
        {
            unix::open(path)
        }
        #[cfg(windows)]
        {
            windows::open(path)
        }
    }

    unsafe fn symbol<T>(&self, name: &str) -> Result<T> {
        #[cfg(unix)]
        {
            unix::symbol(self, name)
        }
        #[cfg(windows)]
        {
            windows::symbol(self, name)
        }
    }
}

impl Drop for DynamicLibrary {
    fn drop(&mut self) {
        #[cfg(unix)]
        unsafe {
            unix::close(self.handle);
        }
        #[cfg(windows)]
        unsafe {
            windows::close(self.handle);
        }
    }
}

#[cfg(unix)]
mod unix {
    use super::{c_char, c_void, CStr, CString, DynamicLibrary, Error, Result};
    use std::mem;
    use std::path::Path;

    #[cfg(not(target_os = "macos"))]
    #[link(name = "dl")]
    extern "C" {}

    extern "C" {
        fn dlopen(filename: *const c_char, flags: i32) -> *mut c_void;
        fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
        fn dlclose(handle: *mut c_void) -> i32;
        fn dlerror() -> *const c_char;
    }

    const RTLD_NOW: i32 = 2;

    pub(super) fn open(path: &Path) -> Result<DynamicLibrary> {
        let c_path = CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| Error::library(format!("invalid library path: {}", path.display())))?;
        let handle = unsafe { dlopen(c_path.as_ptr(), RTLD_NOW) };
        if handle.is_null() {
            return Err(Error::library(last_error().unwrap_or_else(|| {
                format!("failed to load dynamic library {}", path.display())
            })));
        }
        Ok(DynamicLibrary { handle })
    }

    pub(super) unsafe fn symbol<T>(library: &DynamicLibrary, name: &str) -> Result<T> {
        let c_name = CString::new(name)
            .map_err(|_| Error::library(format!("invalid symbol name: {name}")))?;
        let symbol = dlsym(library.handle, c_name.as_ptr());
        if symbol.is_null() {
            return Err(Error::library(last_error().unwrap_or_else(|| {
                format!("failed to resolve symbol {name}")
            })));
        }
        Ok(mem::transmute_copy(&symbol))
    }

    pub(super) unsafe fn close(handle: *mut c_void) {
        if !handle.is_null() {
            let _ = dlclose(handle);
        }
    }

    fn last_error() -> Option<String> {
        let message = unsafe { dlerror() };
        if message.is_null() {
            None
        } else {
            Some(unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned())
        }
    }
}

#[cfg(windows)]
mod windows {
    use super::{c_char, c_void, DynamicLibrary, Error, Result};
    use std::ffi::OsStr;
    use std::mem;
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;

    type HModule = *mut c_void;

    #[link(name = "kernel32")]
    extern "system" {
        fn LoadLibraryW(path: *const u16) -> HModule;
        fn GetProcAddress(handle: HModule, symbol: *const c_char) -> *mut c_void;
        fn FreeLibrary(handle: HModule) -> i32;
    }

    pub(super) fn open(path: &Path) -> Result<DynamicLibrary> {
        let wide: Vec<u16> = OsStr::new(path)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let handle = unsafe { LoadLibraryW(wide.as_ptr()) };
        if handle.is_null() {
            return Err(Error::library(format!(
                "failed to load dynamic library {}",
                path.display()
            )));
        }
        Ok(DynamicLibrary { handle })
    }

    pub(super) unsafe fn symbol<T>(library: &DynamicLibrary, name: &str) -> Result<T> {
        let symbol_name = std::ffi::CString::new(name)
            .map_err(|_| Error::library(format!("invalid symbol name: {name}")))?;
        let symbol = GetProcAddress(library.handle, symbol_name.as_ptr());
        if symbol.is_null() {
            return Err(Error::library(format!("failed to resolve symbol {name}")));
        }
        Ok(mem::transmute_copy(&symbol))
    }

    pub(super) unsafe fn close(handle: *mut c_void) {
        if !handle.is_null() {
            let _ = FreeLibrary(handle);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{decode_value, ColumnType, Value};

    #[test]
    fn converts_boolean_values() {
        assert_eq!(decode_value(Some("true"), ColumnType::Boolean), Value::Boolean(true));
        assert_eq!(decode_value(Some("0"), ColumnType::Boolean), Value::Boolean(false));
    }

    #[test]
    fn converts_integers_and_floats() {
        assert_eq!(decode_value(Some("42"), ColumnType::Int64), Value::Int64(42));
        assert_eq!(decode_value(Some("7"), ColumnType::UInt32), Value::UInt32(7));
        assert_eq!(decode_value(Some("3.5"), ColumnType::Float64), Value::Float64(3.5));
    }

    #[test]
    fn converts_binary_hex() {
        assert_eq!(
            decode_value(Some("0102ff"), ColumnType::Binary),
            Value::Binary(vec![0x01, 0x02, 0xff])
        );
    }

    #[test]
    fn preserves_text_for_non_numeric_types() {
        assert_eq!(
            decode_value(Some("2024-01-02T03:04:05"), ColumnType::Timestamp),
            Value::Text("2024-01-02T03:04:05".to_owned())
        );
        assert_eq!(decode_value(None, ColumnType::Text), Value::Null);
    }
}