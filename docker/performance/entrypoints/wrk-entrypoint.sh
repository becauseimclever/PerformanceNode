#!/usr/bin/env bash
# wrk-entrypoint.sh – HTTP benchmark entrypoint.
# Environment variables:
#   WRK_URL        Target URL (required)
#   WRK_THREADS    Number of threads (default: 4)
#   WRK_CONNECTIONS Number of connections (default: 100)
#   WRK_DURATION   Test duration (default: 30s)
#   RESULT_DIR     Output directory (default: /results)

set -euo pipefail

URL="${WRK_URL:-http://localhost/}"
THREADS="${WRK_THREADS:-4}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
DURATION="${WRK_DURATION:-30s}"
OUT_DIR="${RESULT_DIR:-/results}"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_FILE="${OUT_DIR}/wrk-${TIMESTAMP}.json"

mkdir -p "$OUT_DIR"

echo "Running wrk benchmark against ${URL}..."
echo "  Threads: ${THREADS}, Connections: ${CONNECTIONS}, Duration: ${DURATION}"

RAW=$(wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" \
  --latency "$URL" 2>&1)

echo "$RAW"

# Parse key metrics and emit a JSON result.
REQUESTS=$(echo "$RAW" | grep 'Requests/sec' | awk '{print $2}')
LATENCY_AVG=$(echo "$RAW" | grep 'Latency' | head -1 | awk '{print $2}')
TRANSFER=$(echo "$RAW" | grep 'Transfer/sec' | awk '{print $2}')

jq -n \
  --arg ts        "$TIMESTAMP" \
  --arg url       "$URL" \
  --arg threads   "$THREADS" \
  --arg conns     "$CONNECTIONS" \
  --arg duration  "$DURATION" \
  --arg req_sec   "${REQUESTS:-0}" \
  --arg lat_avg   "${LATENCY_AVG:-0}" \
  --arg transfer  "${TRANSFER:-0}" \
  '{
    timestamp:   $ts,
    tool:        "wrk",
    target_url:  $url,
    threads:     ($threads | tonumber),
    connections: ($conns | tonumber),
    duration:    $duration,
    requests_per_sec: ($req_sec | tonumber),
    latency_avg: $lat_avg,
    transfer_per_sec: $transfer
  }' > "$OUT_FILE"

echo "Results written to ${OUT_FILE}"
