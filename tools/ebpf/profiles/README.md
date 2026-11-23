# profiles/ — env profiles for OTLP destinations (ADR-014 layer 3)

**Layer 3 (deployment/config)** of ADR-014.
Differences per vendor/destination are expressed **with env profiles, not code branches**. spinel-ebpf's probes / runtime
honor OTLP through plain env (`OTEL_EXPORTER_OTLP_*`) (E290/E264/E265-E269), so changing the destination
**only takes sourcing one env file** (no code such as `if (splunk)` is written).

## Usage

```bash
# load the destination profile, then start the probe / collector.
set -a; . profiles/splunk-jp0.env; set +a
export SPLUNK_TOKEN=...        # inject secrets through env (never bake them into the file)
./build/audit_dns               # the probe honors the env above and sends directly
```

**Secrets (token / client key) are not written in profiles.** A profile only refers to env in the form
`${SPLUNK_TOKEN}`, and the value is injected separately (env / k8s Secret / `--env-file`). Never commit a token to git.

## Profiles

| File | Destination | transport | Authentication |
|---|---|---|---|
| `splunk-jp0.env` | Splunk Observability Cloud (realm jp0), direct | OTLP/HTTP+protobuf over TLS | `X-SF-Token` |
| `otel-collector.env` | local/cluster OTel Collector | OTLP/HTTP (plaintext) | none |
| `otel-collector-grpc.env` | OTel Collector (gRPC) | OTLP/gRPC | none |
| `mtls.env` | mTLS enterprise backend | OTLP/HTTP+protobuf over mTLS | client certificate |
| `debug-json.env` | interop/debugging | OTLP/HTTP+JSON | none |

## Basis (which Edoc established which env)

- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is honored **verbatim, path included** (E290). Splunk uses `/v2/trace/otlp`
  (the standard `/v1/traces` is 404 on Splunk).
- `OTEL_EXPORTER_OTLP_HEADERS` (auth), `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` (E264).
- direct sending to `https://`/`grpcs://` with mbedTLS (E265-E267, ADR-013). system CA / `OTEL_EXPORTER_OTLP_CERTIFICATE` /
  `OTEL_EXPORTER_OTLP_INSECURE_SKIP_VERIFY`.
- mTLS: `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE` / `_CLIENT_KEY` (E268).
- `OTEL_EXPORTER_OTLP_PROTOCOL=http/json` (E269, HTTP only, debugging/interop).
- per-signal endpoint `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_ENDPOINT` (E290).
- **Splunk signal matrix (E291)**: traces `/v2/trace/otlp`=200, metrics `/v2/datapoint/otlp`=200 but OTLP
  ExponentialHistogram is rejected (SignalFx datapoint model), **logs cannot be sent directly** (the Collector must convert OTLP→HEC;
  go through the collector profiles listed).
