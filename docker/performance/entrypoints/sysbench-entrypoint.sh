#!/usr/bin/env bash
# sysbench-entrypoint.sh – CPU / memory benchmark entrypoint using sysbench.
# Environment variables:
#   SYSBENCH_TEST    Test name: cpu | memory | fileio (default: cpu)
#   SYSBENCH_THREADS Number of threads (default: number of CPUs)
#   SYSBENCH_TIME    Test duration in seconds (default: 60)
#   RESULT_DIR       Output directory (default: /results)

set -euo pipefail

TEST="${SYSBENCH_TEST:-cpu}"
THREADS="${SYSBENCH_THREADS:-$(nproc)}"
TIME_SEC="${SYSBENCH_TIME:-60}"
OUT_DIR="${RESULT_DIR:-/results}"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_FILE="${OUT_DIR}/sysbench-${TEST}-${TIMESTAMP}.json"

mkdir -p "$OUT_DIR"

echo "Running sysbench ${TEST} test (${THREADS} threads, ${TIME_SEC}s)..."

RAW=$(sysbench "$TEST" \
  --threads="$THREADS" \
  --time="$TIME_SEC" \
  run 2>&1)

echo "$RAW"

# Extract common metrics.
EVENTS=$(echo "$RAW"  | grep 'total number of events'  | awk '{print $NF}')
LATAVG=$(echo "$RAW"  | grep 'avg:'                    | awk '{print $2}')
LATMIN=$(echo "$RAW"  | grep 'min:'                    | awk '{print $2}')
LATMAX=$(echo "$RAW"  | grep 'max:'                    | awk '{print $2}')
EPS=$(echo    "$RAW"  | grep 'events per second'       | awk '{print $NF}')

jq -n \
  --arg ts      "$TIMESTAMP" \
  --arg test    "$TEST" \
  --arg threads "$THREADS" \
  --arg time    "$TIME_SEC" \
  --arg events  "${EVENTS:-0}" \
  --arg eps     "${EPS:-0}" \
  --arg lat_min "${LATMIN:-0}" \
  --arg lat_avg "${LATAVG:-0}" \
  --arg lat_max "${LATMAX:-0}" \
  '{
    timestamp:          $ts,
    tool:               "sysbench",
    test:               $test,
    threads:            ($threads | tonumber),
    duration_sec:       ($time    | tonumber),
    total_events:       ($events  | tonumber),
    events_per_sec:     ($eps     | tonumber),
    latency_ms: {
      min: ($lat_min | tonumber),
      avg: ($lat_avg | tonumber),
      max: ($lat_max | tonumber)
    }
  }' > "$OUT_FILE"

echo "Results written to ${OUT_FILE}"
