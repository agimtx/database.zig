# aq_database Type Mapping

This document defines how source data is mapped into the stable `aq_database` column types exposed by the Zig API, the public C ABI, and the thin Python and Node.js bindings.

The current implementation derives column metadata from Apache Arrow ADBC schemas and then exposes cell values through the stable `aq_result_cell.text_ptr/text_len` surface. Column type and value encoding are related, but they are not the same thing. Column metadata also carries a best-effort `raw_type` string when the driver exposes the original database type name in Arrow metadata. Current coverage is strongest on PostgreSQL, where the driver exports `ADBC:postgresql:typname`; current DuckDB and StarRocks integration coverage does not expose comparable raw type names and therefore reports `raw_type = null`.

## Public aq_database Types

`aq_database` currently exposes these public column types through `enum aq_column_type` in `bindings/c/include/aq_database.h`:

| C ABI enum | Zig enum | Value | Meaning |
| --- | --- | ---: | --- |
| `AQ_COLUMN_UNKNOWN` | `ColumnType.unknown` | 0 | Type could not be inferred from the Arrow schema. |
| `AQ_COLUMN_BOOLEAN` | `ColumnType.boolean` | 1 | Boolean logical value. |
| `AQ_COLUMN_INT64` | `ColumnType.int64` | 2 | Signed 64-bit integer. |
| `AQ_COLUMN_FLOAT64` | `ColumnType.float64` | 3 | 64-bit floating-point value. |
| `AQ_COLUMN_TEXT` | `ColumnType.text` | 4 | UTF-8 text and text-like logical values. |
| `AQ_COLUMN_BINARY` | `ColumnType.binary` | 5 | Binary payloads exposed as hexadecimal text. |
| `AQ_COLUMN_DECIMAL` | `ColumnType.decimal` | 6 | Decimal logical values. |
| `AQ_COLUMN_TIMESTAMP` | `ColumnType.timestamp` | 7 | Timestamp-like logical values. |
| `AQ_COLUMN_JSON` | `ColumnType.json` | 8 | JSON logical values. |
| `AQ_COLUMN_DATE` | `ColumnType.date` | 9 | Calendar date values. |
| `AQ_COLUMN_TIME` | `ColumnType.time` | 10 | Time-of-day values. |
| `AQ_COLUMN_INTERVAL` | `ColumnType.interval` | 11 | Duration and interval values. |
| `AQ_COLUMN_UUID` | `ColumnType.uuid` | 12 | UUID logical values. |
| `AQ_COLUMN_ARRAY` | `ColumnType.array` | 13 | Array and list-like logical values. |
| `AQ_COLUMN_MAP` | `ColumnType.map` | 14 | Map-like logical values. |
| `AQ_COLUMN_STRUCT` | `ColumnType.struct_` | 15 | Struct / record logical values. |
| `AQ_COLUMN_INT8` | `ColumnType.int8` | 16 | Signed 8-bit integer. |
| `AQ_COLUMN_UINT8` | `ColumnType.uint8` | 17 | Unsigned 8-bit integer. |
| `AQ_COLUMN_INT16` | `ColumnType.int16` | 18 | Signed 16-bit integer. |
| `AQ_COLUMN_UINT16` | `ColumnType.uint16` | 19 | Unsigned 16-bit integer. |
| `AQ_COLUMN_INT32` | `ColumnType.int32` | 20 | Signed 32-bit integer. |
| `AQ_COLUMN_UINT32` | `ColumnType.uint32` | 21 | Unsigned 32-bit integer. |
| `AQ_COLUMN_UINT64` | `ColumnType.uint64` | 22 | Unsigned 64-bit integer. |
| `AQ_COLUMN_FLOAT16` | `ColumnType.float16` | 23 | 16-bit floating-point value. |
| `AQ_COLUMN_FLOAT32` | `ColumnType.float32` | 24 | 32-bit floating-point value. |
| `AQ_COLUMN_DURATION` | `ColumnType.duration` | 25 | Arrow duration logical value. |

## Mapping Precedence

The ADBC backend applies type mapping in this order:

1. If the Arrow schema is dictionary-encoded, `aq_database` uses the dictionary value schema, not the index type.
2. If Arrow extension metadata is present, known logical extensions override the raw format code.
3. Otherwise the backend maps the Arrow format string to a public `aq_database` type.

This means a dictionary column with `int32` indices and UTF-8 dictionary values is reported as `AQ_COLUMN_TEXT`, not `AQ_COLUMN_INT32`.

## Arrow Schema To aq_database Type Mapping

The current mapping implemented in `src/core/adbc_backend.zig` is:

| Arrow source | aq_database type | Notes |
| --- | --- | --- |
| dictionary-encoded schema | recurse into dictionary value schema | Index type is ignored for metadata classification. |
| extension `ARROW:extension:name=arrow.json` | `AQ_COLUMN_JSON` | Preferred over raw format code. |
| extension `ARROW:extension:name=arrow.uuid` | `AQ_COLUMN_UUID` | Preferred over raw format code. |
| PostgreSQL typname `date` | `AQ_COLUMN_DATE` | Typname metadata overrides the raw format when the driver exports PostgreSQL type names. |
| PostgreSQL typname `time`, `timetz` | `AQ_COLUMN_TIME` | Typname metadata overrides the raw format. |
| PostgreSQL typname `interval` | `AQ_COLUMN_INTERVAL` | Typname metadata overrides the raw format. |
| PostgreSQL typname `uuid` | `AQ_COLUMN_UUID` | Typname metadata overrides the raw format. |
| PostgreSQL typname `json`, `jsonb`, `jsonpath` | `AQ_COLUMN_JSON` | Typname metadata overrides the raw format. |
| PostgreSQL typname `xml`, `inet`, `cidr`, `macaddr`, `macaddr8`, `tsvector`, `tsquery`, `point`, `box`, `pg_lsn`, `tid` | `AQ_COLUMN_UNKNOWN` | These semantic types are not part of the public Arrow/ADBC type surface; `raw_type` preserves the database type name when the driver exposes it. |
| PostgreSQL oid-like typnames such as `oid`, `regclass`, `regtype` | follow the raw Arrow format | The backend no longer hard-codes one public type for these names; it uses the Arrow storage format and exposes `raw_type` when available. |
| PostgreSQL array typnames such as `_int4` or `type[]` | `AQ_COLUMN_ARRAY` | Typname metadata marks PostgreSQL arrays explicitly. |
| `b` | `AQ_COLUMN_BOOLEAN` | Arrow boolean. |
| `c` | `AQ_COLUMN_INT8` | Arrow signed 8-bit integer. |
| `C` | `AQ_COLUMN_UINT8` | Arrow unsigned 8-bit integer. |
| `s` | `AQ_COLUMN_INT16` | Arrow signed 16-bit integer. |
| `S` | `AQ_COLUMN_UINT16` | Arrow unsigned 16-bit integer. |
| `i` | `AQ_COLUMN_INT32` | Arrow signed 32-bit integer. |
| `I` | `AQ_COLUMN_UINT32` | Arrow unsigned 32-bit integer. |
| `l` | `AQ_COLUMN_INT64` | Arrow signed 64-bit integer. |
| `L` | `AQ_COLUMN_UINT64` | Arrow unsigned 64-bit integer. |
| `e` | `AQ_COLUMN_FLOAT16` | Arrow half-precision float. |
| `f` | `AQ_COLUMN_FLOAT32` | Arrow single-precision float. |
| `g` | `AQ_COLUMN_FLOAT64` | Arrow double-precision float. |
| `u`, `U` | `AQ_COLUMN_TEXT` | UTF-8 and large UTF-8. |
| `vu` | `AQ_COLUMN_TEXT` | UTF-8 view logical type. |
| `z`, `Z`, `w` | `AQ_COLUMN_BINARY` | Binary, large binary, and fixed-size binary. |
| `vz` | `AQ_COLUMN_BINARY` | Binary view logical type. |
| `d` | `AQ_COLUMN_DECIMAL` | Arrow decimal logical type. |
| `td*` | `AQ_COLUMN_DATE` | Arrow date logical types. |
| `tt*` | `AQ_COLUMN_TIME` | Arrow time logical types. |
| `ts*`, `T*` | `AQ_COLUMN_TIMESTAMP` | Arrow timestamp logical types. |
| `tD*` | `AQ_COLUMN_DURATION` | Arrow duration logical types. |
| `ti*` | `AQ_COLUMN_INTERVAL` | Arrow interval logical types. |
| `+l`, `+L`, `+vl`, `+vL`, `+w` | `AQ_COLUMN_ARRAY` | Arrow list, large-list, list-view, large-list-view, and fixed-size-list logical types. |
| `+m` | `AQ_COLUMN_MAP` | Arrow map logical type. |
| `+s` | `AQ_COLUMN_STRUCT` | Arrow struct logical type. |
| any other or empty format | `AQ_COLUMN_UNKNOWN` | No stronger inference is available. |

## Cell Value Encoding

`aq_database` currently returns cell values through a text buffer, even when the logical column type is not text.

The current ADBC backend serializes values as follows:

| aq_database type | Current cell encoding |
| --- | --- |
| `AQ_COLUMN_BOOLEAN` | ASCII `true` or `false` |
| `AQ_COLUMN_INT8`, `AQ_COLUMN_UINT8`, `AQ_COLUMN_INT16`, `AQ_COLUMN_UINT16`, `AQ_COLUMN_INT32`, `AQ_COLUMN_UINT32`, `AQ_COLUMN_INT64`, `AQ_COLUMN_UINT64` | Base-10 integer text |
| `AQ_COLUMN_FLOAT16`, `AQ_COLUMN_FLOAT32`, `AQ_COLUMN_FLOAT64` | Decimal text produced from the Arrow floating-point value |
| `AQ_COLUMN_TEXT` | UTF-8 bytes copied as-is |
| `AQ_COLUMN_BINARY` | Lowercase hexadecimal text |
| `AQ_COLUMN_DECIMAL` | Human-readable decimal text for Arrow decimal values up to 128 bits; wider decimal words still fall back to backend-dependent text |
| `AQ_COLUMN_TIMESTAMP` | ISO-like datetime text such as `2024-01-02T03:04:05` or `2024-01-02T03:04:05.000000` depending on Arrow precision |
| `AQ_COLUMN_JSON` | JSON text when the driver exposes JSON metadata; some drivers may still surface JSON payloads as plain text |
| `AQ_COLUMN_DATE` | ISO date text such as `2024-01-02` |
| `AQ_COLUMN_TIME` | ISO-like time text such as `03:04:05` or `03:04:05.000000` depending on Arrow precision |
| `AQ_COLUMN_DURATION` | Duration text in a stable `P...DT...` form |
| `AQ_COLUMN_INTERVAL` | Interval text in a stable `P...DT...` form |
| `AQ_COLUMN_UUID` | Canonical UUID text |
| `AQ_COLUMN_ARRAY` | JSON-like array text such as `[1,2,3]` |
| `AQ_COLUMN_MAP` | JSON-like array-of-entry text |
| `AQ_COLUMN_STRUCT` | JSON-like object text |
| `AQ_COLUMN_UNKNOWN` | Empty string unless a higher layer converts the value before it reaches the ABI |

Null handling is separate from type mapping. A null cell sets `is_null = 1` and should be treated as null even if `text_len` is zero.

## Implementation Audit

The current backend does not fully support every PostgreSQL or StarRocks type family end-to-end.

Use these status labels throughout the backend-specific tables below:

| Status | Meaning |
| --- | --- |
| `supported` | Metadata mapping and current value extraction are implemented and exercised by tests or directly covered by the current scalar decoder logic. |
| `partial` | The column can be exposed through a stable `aq_database` type, but precision, formatting, or driver-specific coverage is still incomplete. |
| `unsupported` | The current backend has no reliable native handling for the underlying Arrow representation. The column only works if the driver has already stringified it into UTF-8 or binary before it reaches `aq_database`. |

### Current Code Coverage Summary

| Arrow representation | Metadata status | Value status | Notes |
| --- | --- | --- | --- |
| `b`, `c`, `C`, `s`, `S`, `i`, `I`, `l`, `L`, `f`, `g`, `u`, `U`, `z`, `Z`, `w`, `d`, `t*`, `T*` | supported | supported or partial | Scalar numeric, text, binary, date, time, timestamp, duration, and interval families all have explicit decoder branches. |
| dictionary with integer indices | supported | supported | Dictionary values are decoded through the dictionary value schema. |
| extension `arrow.json` | supported | partial | Metadata becomes `AQ_COLUMN_JSON`, but the value still depends on the storage format exported by the driver. |
| extension `arrow.uuid` | supported | supported | Metadata becomes `AQ_COLUMN_UUID`; UUID bytes are formatted into canonical text. |
| `vu`, `vz` | supported | supported | View layouts are decoded through dedicated branches. |
| nested layouts such as list, list-view, large-list, fixed-size-list, struct, map | supported | partial | These layouts are serialized into JSON-like text. Coverage is present, but not every downstream database type family is exercised yet. |
| union, run-end-encoded, other uncommon nested layouts | unsupported | unsupported | These layouts still have no decoder path. |

## PostgreSQL Built-in Type Mapping

This table covers PostgreSQL's built-in SQL-visible type families and their aliases. Domains inherit the mapping of their base type.

| PostgreSQL type family | Representative types and aliases | Target aq_database type | Status | Notes |
| --- | --- | --- | --- | --- |
| Boolean | `boolean`, `bool` | `AQ_COLUMN_BOOLEAN` | `supported` | Tested end-to-end. |
| Signed integer | `smallint`/`int2`, `integer`/`int`/`int4`, `bigint`/`int8` | `AQ_COLUMN_INT16`, `AQ_COLUMN_INT32`, or `AQ_COLUMN_INT64` | `supported` | The backend now preserves Arrow integer width instead of collapsing all signed integers into one family. |
| Serial aliases | `smallserial`/`serial2`, `serial`/`serial4`, `bigserial`/`serial8` | `AQ_COLUMN_INT16`, `AQ_COLUMN_INT32`, or `AQ_COLUMN_INT64` | `supported` | These are integer-backed aliases and now keep their Arrow width. |
| Exact numeric | `numeric`, `decimal` | `AQ_COLUMN_DECIMAL` or `AQ_COLUMN_TEXT` | `partial` | Arrow decimal payloads up to 128 bits are normalized to human-readable decimal text. Some drivers may still surface exact numerics as plain text, and wider decimal words still need dedicated handling. |
| Floating point | `real`/`float4`, `double precision`/`float8`, `float` | `AQ_COLUMN_FLOAT32` or `AQ_COLUMN_FLOAT64` | `supported` | The backend now preserves Arrow float width for tested scalar paths. |
| Monetary | `money` | `AQ_COLUMN_TEXT` | `partial` | No money-specific logical type exists in the public ABI. Safe behavior today is driver stringification to text. |
| Character and text | `char`, `character`, `varchar`, `character varying`, `text`, internal `name`-like string types | `AQ_COLUMN_TEXT` | `supported` | UTF-8 text transport is implemented. |
| Binary | `bytea` | `AQ_COLUMN_BINARY` | `supported` | Values are hex-encoded. Tested end-to-end. |
| Bit strings | `bit`, `bit varying`, `varbit` | `AQ_COLUMN_TEXT` or `AQ_COLUMN_BINARY` | `partial` | No dedicated bit-string logical type exists. Support depends on how the driver exports the Arrow storage. |
| Date/time: timestamp | `timestamp`, `timestamp without time zone`, `timestamp with time zone`, `timestamptz` | `AQ_COLUMN_TIMESTAMP` | `supported` | Values are formatted into ISO-like datetime text. `timestamp` is covered by integration tests. |
| Date/time: other temporal types | `date`, `time`, `time without time zone`, `time with time zone`, `timetz`, `interval` | `AQ_COLUMN_DATE`, `AQ_COLUMN_TIME`, `AQ_COLUMN_INTERVAL` | `supported` | PostgreSQL typname metadata now distinguishes these families and values are decoded into stable text forms. |
| JSON | `json`, `jsonb`, `jsonpath` | `AQ_COLUMN_JSON` or `AQ_COLUMN_TEXT` | `partial` | JSON extension metadata is recognized, but drivers may still expose these as plain UTF-8. `jsonb` is tested with this fallback allowed. |
| UUID | `uuid` | `AQ_COLUMN_UUID` | `supported` | UUID bytes are formatted into canonical UUID text. |
| XML | `xml` | `AQ_COLUMN_UNKNOWN` | `partial` | XML is not a public Arrow/ADBC type in this ABI anymore. When the PostgreSQL driver exposes `typname`, it is carried through `raw_type` while the value itself remains text. |
| Enumerated | `enum` | `AQ_COLUMN_TEXT` or `AQ_COLUMN_BINARY` | `partial` | Enum labels fit the text transport model, but the current PostgreSQL ADBC metadata only exposes the concrete `typname`. That is not enough to distinguish user-defined enums from other user-defined binary types at schema-mapping time, so enum columns may still surface through the binary fallback. |
| Network | `cidr`, `inet`, `macaddr`, `macaddr8` | `AQ_COLUMN_UNKNOWN` | `partial` | These are not public Arrow/ADBC logical types in this ABI. The backend still decodes common payloads to readable text, while `raw_type` preserves the original database type when metadata is available. |
| Text search | `tsvector`, `tsquery` | `AQ_COLUMN_UNKNOWN` | `partial` | The Zig core still decodes PostgreSQL binary payloads into PostgreSQL-compatible text, but metadata now reports these as `UNKNOWN` plus `raw_type`. |
| Geometric | `point`, `line`, `lseg`, `box`, `path`, `polygon`, `circle` | `AQ_COLUMN_UNKNOWN` | `partial` | `point` and `box` still decode to canonical text values, but metadata now reports these unsupported semantic types as `UNKNOWN` plus `raw_type`. |
| Range and multirange | built-in ranges and multiranges such as `int4range`, `numrange`, `tsrange`, `tstzrange`, `daterange`, plus multirange variants | `AQ_COLUMN_TEXT` or `AQ_COLUMN_UNKNOWN` | `unsupported` | Nested or driver-specific logical layouts are not normalized today. |
| Arrays | any `type[]` | `AQ_COLUMN_ARRAY` | `supported` | Native Arrow list/list-view layouts are decoded and serialized into JSON-like array text. PostgreSQL arrays are covered by integration tests. |
| Composite / row | composite types created by `CREATE TYPE`, table row types | `AQ_COLUMN_STRUCT` or `AQ_COLUMN_TEXT` | `partial` | Struct-like Arrow layouts are decoded, but end-to-end PostgreSQL composite coverage is not yet exercised. |
| OID family and system identifiers | `oid`, `regclass`, `regproc`, `regtype`, `xid`, `cid`, `tid`, `pg_lsn`, `pg_snapshot`, `txid_snapshot` | raw Arrow type, or `AQ_COLUMN_UNKNOWN` for unsupported semantic forms | `partial` | `oid` currently surfaces as `INT32` in coverage where the driver exports an integer Arrow type. `regclass` and `regtype` may still arrive as binary. `tid` and `pg_lsn` are reported as `UNKNOWN` metadata with decoded text values. `raw_type` is best-effort and depends on driver metadata availability. |
| Pseudo-types | PostgreSQL pseudo-types | not exposed | `unsupported` | These are not ordinary stored column types for the current public ABI. |

## StarRocks Built-in Type Mapping

This table covers the documented StarRocks SQL-visible type families used for table columns and materialized-view compatibility.

| StarRocks type family | Representative types | Target aq_database type | Status | Notes |
| --- | --- | --- | --- | --- |
| Boolean | `BOOLEAN` | `AQ_COLUMN_BOOLEAN` or `AQ_COLUMN_INT8` | `partial` | Integration tests allow the current boolean-to-int8 metadata fallback exported by the StarRocks path. |
| Small integers | `TINYINT`, `SMALLINT`, `INT`, `BIGINT` | `AQ_COLUMN_INT8`, `AQ_COLUMN_INT16`, `AQ_COLUMN_INT32`, or `AQ_COLUMN_INT64` | `supported` | The backend now preserves Arrow integer width for the tested StarRocks scalar integer families. |
| Large integer | `LARGEINT` | `AQ_COLUMN_TEXT` | `partial` | `LARGEINT` exceeds 64 bits, so the stable ABI keeps it in text form. This path is covered by integration tests. |
| Floating point | `FLOAT`, `DOUBLE` | `AQ_COLUMN_FLOAT32` or `AQ_COLUMN_FLOAT64` | `supported` | Current decoder preserves the Arrow float width for tested StarRocks scalar paths. |
| Decimal | `DECIMAL`, `DECIMAL32`, `DECIMAL64`, `DECIMAL128` and parameterized decimal variants | `AQ_COLUMN_DECIMAL` | `partial` | Metadata fits the public enum and values are normalized to decimal text for Arrow decimal payloads up to 128 bits. Wider decimal words still need dedicated handling. |
| Date/time: tested path | `DATETIME` | `AQ_COLUMN_TIMESTAMP` | `supported` | Values are formatted into ISO-like datetime text and this path is covered by integration tests. |
| Date/time: other temporal types | `DATE` and other temporal variants if exported by the driver | `AQ_COLUMN_DATE` or `AQ_COLUMN_TIMESTAMP` | `partial` | `DATE` is covered by integration tests; broader driver-specific temporal variants still depend on the Arrow shape exported by the driver. |
| Character and text | `CHAR`, `VARCHAR`, `STRING` | `AQ_COLUMN_TEXT` | `supported` | UTF-8 transport is implemented. |
| JSON | `JSON` | `AQ_COLUMN_JSON` or `AQ_COLUMN_TEXT` | `partial` | Integration tests already allow either metadata shape. |
| Semi-structured | `ARRAY`, `MAP`, `STRUCT` | `AQ_COLUMN_ARRAY`, `AQ_COLUMN_MAP`, `AQ_COLUMN_STRUCT` | `partial` | Native nested Arrow layouts are decoded in the backend, but StarRocks-specific end-to-end coverage for these families is not yet present. |
| Bitmap / sketch types | `BITMAP`, `HLL`, `PERCENTILE` | `AQ_COLUMN_BINARY`, `AQ_COLUMN_TEXT`, or `AQ_COLUMN_UNKNOWN` | `unsupported` | The public ABI has no dedicated sketch type and the backend has no decoder for these physical layouts. |

## Answer To "Does The Code Support Them All?"

Not yet completely.

The current backend now supports a materially broader set of Arrow/ADBC-facing families than before, including:

- booleans
- 8/16/32/64-bit integers
- 16/32/64-bit floats
- UTF-8 text
- binary and fixed-size binary
- dictionary-encoded text-like values
- Arrow view values
- date, time, timestamp, and interval formatting
- UUID logical types
- PostgreSQL arrays
- JSON-like serialization for Arrow arrays, maps, and structs

The current backend still does not provide complete coverage for all PostgreSQL and StarRocks types because:

- some database-specific families now deliberately surface as `AQ_COLUMN_UNKNOWN` plus best-effort `raw_type`
- decimal256 and other wider-than-128-bit exact numerics still need dedicated formatting support
- uncommon Arrow layouts such as unions and run-end-encoded arrays are still unsupported
- several richer PostgreSQL and StarRocks families still need explicit end-to-end integration coverage

Any future work to claim full PostgreSQL or StarRocks type coverage should first extend `src/core/types.zig` and `src/core/adbc_backend.zig` together, then add integration tests for each newly claimed family.

## Design Intent

This normalization layer is intentionally narrower than the full Arrow type system. The stable public ABI is optimized for:

- a small cross-language type surface
- stable metadata values across Zig, C, Python, and Node.js
- predictable handling of heterogeneous ADBC drivers

When a source database exposes a richer type than the current public enum can represent, `aq_database` should prefer either an Arrow/ADBC-native public type or `AQ_COLUMN_UNKNOWN`, and carry the original database type name through `raw_type` when the driver exposes it.
