#!/bin/sh
# benchmarks/harness/csv_header.sh
#
# Emit the canonical CSV header used by all benchmark wrappers. Pipe to the
# top of a results/*.csv file before appending run_*.sh outputs.
#
# Usage:
#   ./csv_header.sh > results/M001/ab.csv

echo "timestamp,milestone,target,tool,concurrency,requests,rps,p50_ms,p99_ms,failures"
