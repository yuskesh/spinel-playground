# steps/ — frozen verification programs matching the Edocs

The programs that verified each step of P012. They are **what the Edocs' reproduction steps actually run**, so from now on
they are not refactored (moved here from the root in the 2026-08-13 refactor. Paths in the body of Edocs
before that are the pre-move ones — the paths of that time are in the history up to commit `a542514`).

The only change at the move: `require_relative` updated to `../lib/decoder` / `../lib/query_ast`
(following the rename of the shared modules; the logic is unchanged).

**Build with the repo's examples/o11y_backend/ as the cwd** (because ffi_cflags'
`vendor/duckdb` and the like are relative to the cwd):

```sh
cd examples/o11y_backend
/path/to/spinel steps/s1_duck_check.rb && LD_LIBRARY_PATH=vendor/duckdb ./s1_duck_check
```

| File | Edoc | What it pins down |
|---|---|---|
| `s1_duck_check.rb` | E437 | spinel FFI × DuckDB connectivity (0 lines of wrapper) |
| `s2_decode_check.rb` | E438 | decoder checked against expected values (offline) |
| `s2_otlp_server.rb` | E438 | the first OTLP/HTTP receiver (decode only) |
| `s3_parquet_check.rb` | E439 | appender → COPY TO Parquet → read back |
| `s4_backend.rb` | E440 | single-binary backend (ingest+rotate+query) |
| `s6_decode_bench.rb` | E442 | decode micro-benchmark |
| `s7_thread_bench.rb` | E443 | Thread (M:N) scaling measurement |
| `s8_backend_mt.rb` | E444 | fork + SO_REUSEPORT + keepalive (blocking worker) |
| `s9_backend.rb` | E445/E447 | C wrapper query + AST wiring (final single-binary form) |
| `s11_compact.rb` | E446 | manual compaction (the form before the catalog) |
| `s12_ast_check.rb` | E447 | 15 positive and negative cases for the pipeline language compiler |

The current product form is `ingestd.rb` / `queryd.rb` in the parent directory (see README.md).
