pub const DriverKind = enum(u8) {
    adbc,
    custom,
};

pub const DriverLanguage = enum(u8) {
    shared_library,
    native_zig,
    external_process,
};

pub const ColumnType = enum(i32) {
    unknown = 0,
    boolean = 1,
    int64 = 2,
    float64 = 3,
    text = 4,
    binary = 5,
    decimal = 6,
    timestamp = 7,
    json = 8,
    date = 9,
    time = 10,
    interval = 11,
    uuid = 12,
    array = 13,
    map = 14,
    struct_ = 15,
    int8 = 16,
    uint8 = 17,
    int16 = 18,
    uint16 = 19,
    int32 = 20,
    uint32 = 21,
    uint64 = 22,
    float16 = 23,
    float32 = 24,
    duration = 25,
};

pub const ColumnMetadata = struct {
    name: []const u8,
    raw_type: ?[]const u8 = null,
    column_type: ColumnType = .unknown,
    nullable: bool = true,
};

pub const ResultCell = struct {
    text: []const u8,
    is_null: bool = false,
};

pub const ResultRow = struct {
    values: []const ResultCell,
};

pub const GetTablesOptions = struct {
    catalog: ?[]const u8 = null,
    database: ?[]const u8 = null,
};

pub const ConnectOptions = struct {
    driver: DriverKind,
    dsn: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    database: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    warehouse: ?[]const u8 = null,
    role: ?[]const u8 = null,
    flags: u32 = 0,
};
