#!/usr/bin/env bash
# stress-ng-entrypoint.sh – CPU / memory / I/O stress test entrypoint.
# Environment variables:
#   STRESS_TIMEOUT  Duration (default: 60s)
#   STRESS_CPU      Number of CPU stressors (default: number of CPUs)
#   STRESS_VM       Number of VM stressors (default: 1)
#   STRESS_VM_BYTES Memory per VM stressor (default: 256m)
#   RESULT_DIR      Output directory (default: /results)

set -euo pipefail

TIMEOUT="${STRESS_TIMEOUT:-60s}"
CPU_WORKERS="${STRESS_CPU:-$(nproc)}"
VM_WORKERS="${STRESS_VM:-1}"
VM_BYTES="${STRESS_VM_BYTES:-256m}"
OUT_DIR="${RESULT_DIR:-/results}"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT_FILE="${OUT_DIR}/stress-ng-${TIMESTAMP}.json"

mkdir -p "$OUT_DIR"

echo "Running stress-ng for ${TIMEOUT}..."
echo "  CPU workers: ${CPU_WORKERS}, VM workers: ${VM_WORKERS} (${VM_BYTES} each)"

stress-ng \
  --cpu "$CPU_WORKERS" \
  --vm  "$VM_WORKERS" \
  --vm-bytes "$VM_BYTES" \
  --timeout "$TIMEOUT" \
  --metrics-brief \
  --yaml "/tmp/stress-ng-metrics.yaml" 2>&1 | tee /tmp/stress-ng-raw.txt

# Convert YAML metrics to JSON (stress-ng doesn't produce JSON natively).
python3 - << 'PYEOF'
import yaml, json, sys, os

yaml_file = "/tmp/stress-ng-metrics.yaml"
out_file  = os.environ.get("OUT_FILE", "/results/stress-ng.json")

try:
    with open(yaml_file) as f:
        data = yaml.safe_load(f)
    with open(out_file, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Results written to {out_file}")
except Exception as e:
    print(f"Warning: could not convert metrics: {e}", file=sys.stderr)
PYEOF
