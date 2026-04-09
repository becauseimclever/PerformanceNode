#!/usr/bin/env bash
# iperf3-entrypoint.sh – Network throughput benchmark entrypoint.
# Environment variables:
#   IPERF3_SERVER  Server host/IP (required)
#   IPERF3_PORT    Server port (default: 5201)
#   IPERF3_DURATION Test duration in seconds (default: 30)
#   IPERF3_PARALLEL Parallel streams (default: 4)
#   RESULT_DIR     Output directory (default: /results)

set -euo pipefail

SERVER="${IPERF3_SERVER:-localhost}"
PORT="${IPERF3_PORT:-5201}"
DURATION="${IPERF3_DURATION:-30}"
PARALLEL="${IPERF3_PARALLEL:-4}"
OUT_DIR="${RESULT_DIR:-/results}"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_FILE="${OUT_DIR}/iperf3-${TIMESTAMP}.json"

mkdir -p "$OUT_DIR"

echo "Running iperf3 benchmark against ${SERVER}:${PORT}..."
echo "  Duration: ${DURATION}s, Parallel streams: ${PARALLEL}"

iperf3 \
  --client "$SERVER" \
  --port "$PORT" \
  --time "$DURATION" \
  --parallel "$PARALLEL" \
  --json \
  > "$OUT_FILE"

# Print a human-readable summary from the JSON output.
SENT_MBPS=$(jq '.end.sum_sent.bits_per_second / 1e6' "$OUT_FILE")
RECV_MBPS=$(jq '.end.sum_received.bits_per_second / 1e6' "$OUT_FILE")
echo "Sent:     ${SENT_MBPS} Mbps"
echo "Received: ${RECV_MBPS} Mbps"
echo "Results written to ${OUT_FILE}"
