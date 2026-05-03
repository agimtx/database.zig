# src-aq-core

`src-aq-core` is a small Zig module that links directly to the vendored `surrealdb.c` SDK for embedded SurrealDB use.

Current scope:

- open embedded `mem://` and `surrealkv://...` endpoints
- select namespace and database
- optional root sign-in
- run SurrealQL queries and manage result lifetimes

Build with the dedicated step:

```bash
zig build aq-core-test
```