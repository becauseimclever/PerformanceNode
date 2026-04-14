#!/usr/bin/env bash
# run-all-cache-benchmarks.sh — Orchestrator: runs all cache benchmark scripts
# and produces a combined summary.json report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${PWD}/.performancenode/cache-benchmarks"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------- helpers ----------

log()  { echo "[cache-benchmarks] $*"; }
warn() { echo "[cache-benchmarks] WARN: $*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Options:
  --output-dir DIR   Directory for JSON output files (default: $OUTPUT_DIR)
  --skip-nuget       Skip NuGet cache benchmark
  --skip-pico        Skip Pico SDK cache benchmark
  --skip-docker      Skip Docker cache benchmark
  -h, --help         Show this help
EOF
  exit 1
}

# ---------- argument parsing ----------

SKIP_NUGET=false
SKIP_PICO=false
SKIP_DOCKER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-nuget)  SKIP_NUGET=true;  shift ;;
    --skip-pico)   SKIP_PICO=true;   shift ;;
    --skip-docker) SKIP_DOCKER=true; shift ;;
    -h|--help)     usage ;;
    *) warn "Unknown argument: $1"; usage ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

# ---------- run a benchmark script ----------

run_benchmark() {
  local name="$1"
  local script="$2"
  local out_file="$OUTPUT_DIR/${name}.json"

  log "──────────────────────────────────────────"
  log "Running: $name"
  log "──────────────────────────────────────────"

  if [[ ! -x "$script" ]]; then
    warn "$script not found or not executable — skipping"
    echo "{\"error\":\"script not found\",\"benchmark\":\"$name\"}" > "$out_file"
    echo "$out_file"
    return
  fi

  local t0 t1 elapsed_ms exit_code=0
  t0=$(date +%s%3N)
  "$script" > "$out_file" 2>&1 || exit_code=$?
  t1=$(date +%s%3N)
  elapsed_ms=$(( t1 - t0 ))

  if [[ $exit_code -ne 0 ]]; then
    warn "$name exited with code $exit_code"
    # Wrap error output in JSON if the file isn't already JSON
    if ! python3 -c "import json,sys; json.load(open('$out_file'))" 2>/dev/null; then
      local raw
      raw=$(cat "$out_file" | head -20 | tr -d '\000-\037' | \
            python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
      echo "{\"error\":\"benchmark failed\",\"details\":$raw}" > "$out_file"
    fi
  fi

  log "$name completed in ${elapsed_ms}ms → $out_file"
  echo "$out_file"
}

# ---------- pretty-print summary ----------

print_summary() {
  local summary_file="$1"

  log ""
  log "╔══════════════════════════════════════════════════════╗"
  log "║           Cache Benchmark Summary                    ║"
  log "╚══════════════════════════════════════════════════════╝"
  log ""

  python3 - "$summary_file" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

benchmarks = data.get("benchmarks", {})

def ms_to_s(ms):
    return f"{ms/1000:.2f}s"

# NuGet
if "nuget" in benchmarks:
    n = benchmarks["nuget"]
    if "error" in n:
        print(f"  NuGet   : ERROR — {n['error']}")
    else:
        print(f"  NuGet   : cold={ms_to_s(n.get('cold_build_ms',0))}  warm={ms_to_s(n.get('warm_build_ms',0))}  speedup={n.get('speedup_factor',0)}x  pkgs_cached={n.get('packages_from_cache',0)}")

# Pico SDK
if "pico_sdk" in benchmarks:
    p = benchmarks["pico_sdk"]
    if "error" in p:
        print(f"  Pico SDK: ERROR — {p['error']}")
    else:
        print(f"  Pico SDK: cold={ms_to_s(p.get('cold_build_ms',0))}  warm={ms_to_s(p.get('warm_build_ms',0))}  speedup={p.get('speedup_factor',0)}x  ccache_hit={p.get('ccache_hit_rate_pct',0)}%")

# Docker
if "docker" in benchmarks:
    d = benchmarks["docker"]
    if "error" in d:
        print(f"  Docker  : ERROR — {d['error']}")
    else:
        print(f"  Docker  : cold={ms_to_s(d.get('cold_pull_ms',0))}  warm={ms_to_s(d.get('warm_pull_ms',0))}  speedup={ms_to_s(d.get('speedup_ms',0))}  size={d.get('image_size_mb',0)}MB")

print()
print(f"  Full report: {sys.argv[1]}")
PYEOF
}

# ---------- main ----------

main() {
  log "Cache benchmarks started at $TIMESTAMP"
  log "Output directory: $OUTPUT_DIR"

  local nuget_file="{}" pico_file="{}" docker_file="{}"
  local nuget_json="{}" pico_json="{}" docker_json="{}"

  if [[ "$SKIP_NUGET" == "false" ]]; then
    nuget_file=$(run_benchmark "nuget" "$SCRIPT_DIR/measure-nuget-cache.sh")
    nuget_json=$(cat "$nuget_file" 2>/dev/null || echo '{}')
  fi

  if [[ "$SKIP_PICO" == "false" ]]; then
    pico_file=$(run_benchmark "pico_sdk" "$SCRIPT_DIR/measure-pico-sdk-cache.sh")
    pico_json=$(cat "$pico_file" 2>/dev/null || echo '{}')
  fi

  if [[ "$SKIP_DOCKER" == "false" ]]; then
    docker_file=$(run_benchmark "docker" "$SCRIPT_DIR/measure-docker-cache.sh")
    docker_json=$(cat "$docker_file" 2>/dev/null || echo '{}')
  fi

  local summary_file="$OUTPUT_DIR/summary.json"
  python3 - "$summary_file" "$TIMESTAMP" \
    "$nuget_json" "$pico_json" "$docker_json" \
    <<'PYEOF'
import json, sys

summary_file = sys.argv[1]
timestamp    = sys.argv[2]
nuget_raw    = sys.argv[3]
pico_raw     = sys.argv[4]
docker_raw   = sys.argv[5]

def safe_parse(raw):
    try:
        return json.loads(raw)
    except Exception:
        return {"error": "invalid json"}

summary = {
    "generated_at": timestamp,
    "benchmarks": {
        "nuget":    safe_parse(nuget_raw),
        "pico_sdk": safe_parse(pico_raw),
        "docker":   safe_parse(docker_raw),
    }
}

with open(summary_file, "w") as f:
    json.dump(summary, f, indent=2)

print(summary_file)
PYEOF

  print_summary "$summary_file"
  log "Done. Combined report: $summary_file"
}

main "$@"
