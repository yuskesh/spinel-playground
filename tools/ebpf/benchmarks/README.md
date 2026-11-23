# benchmarks/

Benchmark infrastructure for each milestone (M001-M004) set by the
P001 HTTP server roadmap. **No milestone is
declared achieved until it has numbers measured under the same conditions as nginx**.

## Layout

```
benchmarks/
├── README.md                 # ← this file
├── harness/
│   ├── run_ab.sh             # Apache Bench wrapper, result as one CSV line
│   ├── run_wrk.sh            # wrk wrapper, result as one CSV line
│   └── csv_header.sh         # prints the CSV header line (written at the top of results/*.csv)
├── targets/
│   ├── nginx_hello.conf      # hello-world conf for nginx alpine (8080)
│   ├── start_nginx.sh        # installs + starts nginx inside the container
│   └── stop_nginx.sh         # cleanup
└── results/
    ├── baseline_nginx/       # results for nginx alone (the reference for the M001 comparison)
    └── M001/ ... M004/       # results for each milestone (committed when achieved)
```

## CSV format

results/*.csv has these 10 columns:

```
timestamp,milestone,target,tool,concurrency,requests,rps,p50_ms,p99_ms,failures
```

- **timestamp**: ISO8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`)
- **milestone**: `baseline_nginx` / `M001` / `M002` / `M003` / `M004`
- **target**: target URL (e.g. `http://127.0.0.1:8080/`)
- **tool**: `ab` / `wrk` / `hping3` (for DDoS tests, M002+)
- **concurrency**: concurrency (-c for ab)
- **requests**: total number of requests (-n for ab)
- **rps**: requests per second (mean)
- **p50_ms**: median latency in ms
- **p99_ms**: 99th percentile latency in ms
- **failures**: number of failures (non-2xx + connection error)

## Usage

### 1. Start the container + install dependencies

```bash
# from the project root
container run -d --name bench --cap-add ALL -c 4 -m 4G \
  --mount type=bind,source=$PWD,target=/work \
  -w /work docker.io/library/debian:trixie sleep infinity

container exec bench bash -c '
  DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
  apt-get install -y --no-install-recommends \
    apache2-utils wrk nginx iputils-ping curl
'
```

### 2. Measure the nginx baseline (the comparison target for M001)

```bash
container exec bench bash -c '
  /work/benchmarks/targets/start_nginx.sh
  sleep 1
  curl -s http://127.0.0.1:8080/  # smoke test

  out=/work/benchmarks/results/baseline_nginx/ab.csv
  mkdir -p $(dirname $out)
  /work/benchmarks/harness/csv_header.sh > $out
  /work/benchmarks/harness/run_ab.sh baseline_nginx http://127.0.0.1:8080/ 1   1000  >> $out
  /work/benchmarks/harness/run_ab.sh baseline_nginx http://127.0.0.1:8080/ 10  10000 >> $out
  /work/benchmarks/harness/run_ab.sh baseline_nginx http://127.0.0.1:8080/ 100 10000 >> $out
  cat $out
'
```

### 3. Cleanup

```bash
container exec bench /work/benchmarks/targets/stop_nginx.sh
container stop bench && container rm bench
```

## Notes

- **The load generator and the target are in the same container** (for the M001 baseline
  comparison, CPU contention affects both equally, so it is valid as a relative comparison).
  The plan is to move the load gen into a separate container when multi-worker measurement
  starts at M003
- **CPU count**: 4 are assigned with `container run -c 4`. This is fixed so that nginx and
  spinel are compared under the same conditions
- **Absolute values** include the Apple container's virtualization overhead and are for
  reference only. The **relative comparison** (vs the nginx baseline) is the main axis

## Mapping to P001 progress

- [ ] M001 baseline: nginx alone → `results/baseline_nginx/ab.csv` (created by step 2 of this file)
- [ ] M001: spinel HTTP server → `results/M001/ab.csv`
- [ ] M002: + XDP early reject → `results/M002/ab.csv` + `results/M002/hping.csv`
- [ ] M003: + SO_REUSEPORT → `results/M003/ab_workers_{1,2,4,8}.csv`
- [ ] M004: + kernel-side `/health` → `results/M004/wrk_latency.csv`
