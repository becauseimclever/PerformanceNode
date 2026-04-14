#!/usr/bin/env bash
# measure-pico-sdk-cache.sh — Measures Pico SDK build performance with/without ccache.
# Outputs JSON: cold/warm build times, ccache hit rate, speedup factor.
set -euo pipefail

PICO_SDK_PATH="${PICO_SDK_PATH:-/opt/pico-sdk}"
CCACHE_DIR="${CCACHE_DIR:-/opt/runner-cache/ccache}"
WORK_DIR="${WORK_DIR:-${PWD}/.performancenode/pico-bench}"
TOOLCHAIN_PREFIX="${TOOLCHAIN_PREFIX:-arm-none-eabi}"

# ---------- helpers ----------

log()  { echo "[pico-sdk-cache] $*" >&2; }
warn() { echo "[pico-sdk-cache] WARN: $*" >&2; }

require_tool() {
  command -v "$1" >/dev/null 2>&1
}

now_ms() { date +%s%3N; }

# ---------- minimal blink project ----------

create_blink_project() {
  local dir="$1"
  mkdir -p "$dir"

  cat >"$dir/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.13)
include(\$ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)
project(blink C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
pico_sdk_init()
add_executable(blink blink.c)
target_link_libraries(blink pico_stdlib)
pico_add_extra_outputs(blink)
EOF

  cat >"$dir/blink.c" <<'EOF'
#include "pico/stdlib.h"

int main() {
    const uint LED_PIN = 25;
    gpio_init(LED_PIN);
    gpio_set_dir(LED_PIN, GPIO_OUT);
    while (true) {
        gpio_put(LED_PIN, 1);
        sleep_ms(500);
        gpio_put(LED_PIN, 0);
        sleep_ms(500);
    }
    return 0;
}
EOF
}

# ---------- toolchain overhead ----------

measure_toolchain_overhead() {
  local gcc="${TOOLCHAIN_PREFIX}-gcc"
  if ! require_tool "$gcc"; then
    warn "$gcc not found — skipping toolchain overhead measurement"
    echo 0
    return
  fi

  local t0 t1
  t0=$(now_ms)
  "$gcc" --version >/dev/null 2>&1
  t1=$(now_ms)
  echo $(( t1 - t0 ))
}

# ---------- ccache stats ----------

parse_ccache_hit_rate() {
  if ! require_tool ccache; then
    echo "0"
    return
  fi
  local stats
  stats=$(ccache -s 2>/dev/null || true)

  local hits misses total
  # ccache 4.x format: "cache hit (direct)   N"
  hits=$(echo "$stats" | awk '/cache hit/ { sum += $NF } END { print sum+0 }')
  misses=$(echo "$stats" | awk '/cache miss/ { sum += $NF } END { print sum+0 }')
  total=$(( hits + misses ))

  if [[ "$total" -gt 0 ]]; then
    awk "BEGIN { printf \"%.1f\", ($hits / $total) * 100 }"
  else
    echo "0"
  fi
}

# ---------- build ----------

run_cmake_build() {
  local src_dir="$1"
  local build_dir="$2"
  local use_ccache="$3"  # "true" or "false"

  mkdir -p "$build_dir"
  local cmake_args=("-S" "$src_dir" "-B" "$build_dir" "-DPICO_SDK_PATH=$PICO_SDK_PATH")

  if [[ "$use_ccache" == "true" ]] && require_tool ccache; then
    cmake_args+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache" "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
    export CCACHE_DIR
  fi

  cmake "${cmake_args[@]}" 2>&1 | tail -5 >&2
  make -C "$build_dir" -j"$(nproc)" 2>&1 | tail -10 >&2
}

measure_build() {
  local label="$1"
  local src_dir="$2"
  local build_dir="$3"
  local use_ccache="$4"

  log "Running $label build (ccache=$use_ccache)…"
  local t0 t1
  t0=$(now_ms)
  run_cmake_build "$src_dir" "$build_dir" "$use_ccache"
  t1=$(now_ms)
  echo $(( t1 - t0 ))
}

# ---------- main ----------

main() {
  # Verify required tools
  if ! require_tool cmake; then
    warn "cmake not found — skipping Pico SDK cache measurement"
    echo '{"error":"cmake not found","cold_build_ms":0,"warm_build_ms":0,"ccache_hit_rate_pct":0,"speedup_factor":0,"toolchain_overhead_ms":0}'
    exit 0
  fi

  if ! require_tool make; then
    warn "make not found — skipping Pico SDK cache measurement"
    echo '{"error":"make not found","cold_build_ms":0,"warm_build_ms":0,"ccache_hit_rate_pct":0,"speedup_factor":0,"toolchain_overhead_ms":0}'
    exit 0
  fi

  if [[ ! -d "$PICO_SDK_PATH" ]]; then
    warn "PICO_SDK_PATH=$PICO_SDK_PATH not found — skipping"
    echo '{"error":"pico-sdk not found","cold_build_ms":0,"warm_build_ms":0,"ccache_hit_rate_pct":0,"speedup_factor":0,"toolchain_overhead_ms":0}'
    exit 0
  fi

  mkdir -p "$WORK_DIR"
  local src_dir="$WORK_DIR/blink"
  create_blink_project "$src_dir"

  # Toolchain startup overhead
  local toolchain_ms
  toolchain_ms=$(measure_toolchain_overhead)
  log "Toolchain startup overhead: ${toolchain_ms}ms"

  # --- Cold build (no ccache) ---
  if require_tool ccache; then
    ccache -C >/dev/null 2>&1 || true  # clear cache for fair cold measurement
    ccache -z >/dev/null 2>&1 || true  # reset stats
  fi
  local cold_ms
  cold_ms=$(measure_build "COLD" "$src_dir" "$WORK_DIR/build-cold" "false")

  # --- Warm build (with ccache populated from cold run object files) ---
  # For a true ccache warm run: build with ccache once to populate, then rebuild
  if require_tool ccache; then
    ccache -z >/dev/null 2>&1 || true  # reset stats before warm run
    log "Pre-populating ccache…"
    run_cmake_build "$src_dir" "$WORK_DIR/build-warm-prep" "true" 2>/dev/null || true
    ccache -z >/dev/null 2>&1 || true  # reset stats so warm run stats are clean
  fi

  local warm_ms
  warm_ms=$(measure_build "WARM" "$src_dir" "$WORK_DIR/build-warm" "true")

  local ccache_hit_rate
  ccache_hit_rate=$(parse_ccache_hit_rate)

  local speedup
  if [[ "$warm_ms" -gt 0 ]]; then
    speedup=$(awk "BEGIN { printf \"%.2f\", $cold_ms / $warm_ms }")
  else
    speedup="0"
  fi

  cat <<JSON
{
  "cold_build_ms": $cold_ms,
  "warm_build_ms": $warm_ms,
  "ccache_hit_rate_pct": $ccache_hit_rate,
  "speedup_factor": $speedup,
  "toolchain_overhead_ms": $toolchain_ms
}
JSON

  rm -rf "$WORK_DIR" 2>/dev/null || true
}

main "$@"
