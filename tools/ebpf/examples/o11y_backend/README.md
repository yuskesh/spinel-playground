# o11y_backend — an observability backend written in Ruby (spinel AOT)

Receives logs over OTLP/HTTP, writes them to Parquet segments, searches them with a pipeline language and
shows them in Grafana. It runs on **Ruby + libduckdb + libsqlite3 alone**
(design: docs/design/observability_backend_ruby_spinel.md,
record of the plan and measurements: P012 / E437-E450).

```text
OTLP client ─HTTP :4318 / gRPC :4317─> ingestd (fork worker × N, epoll+keepalive,
   │                            sk_reuseport BPF worker selection [opt-in])
   │                              │ decode → DuckDB appender → rotate
   │                              ▼
   │                        data/*.parquet  ←─ compactor (resident, periodic compact)
   │                              │
   │                        catalog.db (SQLite — the single source of truth for live segments)
   │                              │
Grafana / curl ─POST /api/v1/query─> queryd ── read_parquet([live...]) → bind SQL
```

## File map

| Path | Contents | Main Edocs |
|---|---|---|
| `ingestd.rb` | ingest daemon (fork parent/child of worker/compactor + eBPF worker selection) | E444/E448/E449/E450 |
| `queryd.rb` | query daemon (catalog-driven, AST + structured filter) | E440/E445/E447/E448 |
| `lib/net.rb` | socket/epoll/fork FFI declarations | — |
| `lib/http.rb` | HTTP/1.x read and write (including the keepalive decision) | E444 |
| `lib/h2.rb` + `native/o11y_h2.c` | OTLP/gRPC receive (nghttp2 h2c, callbacks on the C side) | E451 |
| `lib/gzip.rb` + `native/o11y_gzip.c` | gzip inflate (for both gRPC frames and HTTP Content-Encoding) | E452 |
| `lib/tls.rb` + `native/o11y_tls.c` | TLS termination (mbedTLS, ALPN fixed per port, 5s I/O deadline) | E453 |
| `lib/duck.rb` | DuckDB FFI (64bit is `:long` — E439's silent truncation) | E437/E439 |
| `lib/catalog.rb` | SQLite segment catalog (live→dead→purge state machine) | E448 |
| `lib/decoder.rb` | hand-written OTLP protobuf decoder (direct getbyte scan, column-oriented output) | E438/E443 |
| `lib/query_ast.rb` | pipeline language → allowlist+bind SQL compiler | E447 |
| `native/o11y_duck_json.c` | the only C: a wrapper for result scanning + JSON conversion (`:str` is a borrow — the convention is to wrap ownership-transfer APIs in a C shim, E445 addendum) | E445 |
| `steps/` | frozen verification programs of E437-E447 ([steps/README.md](steps/README.md)) | each Edoc |
| `scripts/` | libduckdb fetch / test payload generation / Grafana provisioning | E437/E438/E441 |

## Quick start (container = spnlbuild)

```sh
cd examples/o11y_backend
sh scripts/fetch-duckdb.sh                 # libduckdb into vendor/duckdb (version recorded in VERSION)
sh scripts/gen-test-payload.sh             # tests/payload_logs.bin (protoc)

# build (ingestd is eBPF-mixed, queryd is native-only)
ruby ../../bin/spinel-ebpf compile ingestd.rb --build -o build
ruby ../../bin/spinel-ebpf compile queryd.rb --native-only --build -o build

# start
mkdir -p data
LD_LIBRARY_PATH=vendor/duckdb O11Y_WORKERS=4 ./build/ingestd 4318 100000 data &
# TLS termination: setting both O11Y_TLS_CERT=... and O11Y_TLS_KEY=... puts 4317/4318 on TLS (E453)
LD_LIBRARY_PATH=vendor/duckdb ./build/queryd 4319 data &

# ingest and search
curl -X POST --data-binary @tests/payload_logs.bin \
     -H 'Content-Type: application/x-protobuf' http://127.0.0.1:4318/v1/logs
curl -X POST -H 'Content-Type: application/json' \
     -d '{"q":"logs | severity >= error | stats count() by service"}' \
     http://127.0.0.1:4319/api/v1/query
```

For Grafana (Infinity datasource), `sh scripts/provision-grafana.sh <grafana> <queryd>`
installs the datasource + dashboard (E441).

## Design discipline (assumed wherever you read)

- **User values are always bound** — string concatenation into SQL is only for server-generated literals (E440, injection negative control done)
- **Errors are subject + remedy** — the response says what is wrong and what would be accepted (E435 standard)
- **After writing a decoder, feed it broken input** — the negative controls caught all 3 silent bugs (E438/E439)
- **64bit in the FFI is `:long`** — `:int` is C's 32-bit int and silently truncates (E439)
- **The visibility boundary = the segment** — mem rows not yet rotated are invisible to queries (tuned by rotate's age/rows)

## Known limitations (Phase 4 candidates, recorded in P012)

slow-client partial reads / SIGCHLD reap / graceful shutdown / keeping BPF modulo (4) and
O11Y_WORKERS in line by hand / quoted `|` splitting in the AST / metrics and traces signals / mTLS (client certificates) and certificate rotation.
