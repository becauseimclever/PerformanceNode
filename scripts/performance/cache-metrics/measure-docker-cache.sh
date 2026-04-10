#!/usr/bin/env bash
# measure-docker-cache.sh — Measures Docker image pull performance (cold vs cached).
# Outputs JSON: cold/warm pull times, image sizes, speedup.
set -euo pipefail

IMAGE="${IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"
LOCAL_REGISTRY="${LOCAL_REGISTRY:-}"  # Optional: e.g. "192.168.1.100:5000"

# ---------- helpers ----------

log()  { echo "[docker-cache] $*" >&2; }
warn() { echo "[docker-cache] WARN: $*" >&2; }

require_tool() {
  command -v "$1" >/dev/null 2>&1
}

now_ms() { date +%s%3N; }

# ---------- image size ----------

image_size_mb() {
  local img="$1"
  local size_bytes
  size_bytes=$(docker image inspect "$img" \
    --format '{{.Size}}' 2>/dev/null || echo 0)
  awk "BEGIN { printf \"%.1f\", $size_bytes / (1024*1024) }"
}

# Docker Hub reports compressed manifest size differently; approximate via
# the layers stored on disk (uncompressed).
image_compressed_mb() {
  local img="$1"
  # Sum compressed layer sizes reported in manifest (best-effort via skopeo)
  if require_tool skopeo; then
    skopeo inspect --raw "docker://$img" 2>/dev/null | \
      python3 -c "
import json, sys
d = json.load(sys.stdin)
total = sum(l.get('size', 0) for l in d.get('layers', []))
print(f'{total / (1024*1024):.1f}')
" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ---------- pull measurement ----------

measure_cold_pull() {
  local img="$1"
  log "Removing image (if present) for cold pull…"
  docker rmi "$img" >/dev/null 2>&1 || true

  local t0 t1
  t0=$(now_ms)
  docker pull "$img" 2>&1 | tail -3 >&2
  t1=$(now_ms)
  echo $(( t1 - t0 ))
}

measure_warm_pull() {
  local img="$1"
  log "Measuring warm pull (image already in local store)…"
  local t0 t1
  t0=$(now_ms)
  docker pull "$img" 2>&1 | tail -3 >&2
  t1=$(now_ms)
  echo $(( t1 - t0 ))
}

measure_registry_pull() {
  local hub_img="$1"
  local registry="$2"
  # Tag image into local registry, push, then time the pull-back
  local local_img="${registry}/$(basename "$hub_img")"

  log "Tagging and pushing to local registry $registry…"
  docker tag "$hub_img" "$local_img" 2>/dev/null || true
  docker push "$local_img" 2>/dev/null | tail -3 >&2 || { warn "push failed"; echo 0; return; }
  docker rmi "$local_img" >/dev/null 2>&1 || true

  local t0 t1
  t0=$(now_ms)
  docker pull "$local_img" 2>&1 | tail -3 >&2
  t1=$(now_ms)
  echo $(( t1 - t0 ))
}

# ---------- main ----------

main() {
  if ! require_tool docker; then
    warn "docker not found — skipping Docker cache measurement"
    echo '{"error":"docker not found","cold_pull_ms":0,"warm_pull_ms":0,"image_size_mb":0,"compressed_size_mb":0,"speedup_ms":0,"registry_pull_ms":0}'
    exit 0
  fi

  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon not accessible — skipping"
    echo '{"error":"docker daemon not accessible","cold_pull_ms":0,"warm_pull_ms":0,"image_size_mb":0,"compressed_size_mb":0,"speedup_ms":0,"registry_pull_ms":0}'
    exit 0
  fi

  log "Target image: $IMAGE"

  # Compressed size query (best-effort, before any local pull changes things)
  local compressed_mb
  compressed_mb=$(image_compressed_mb "$IMAGE")

  # Cold pull
  local cold_ms
  cold_ms=$(measure_cold_pull "$IMAGE")
  log "Cold pull: ${cold_ms}ms"

  # Uncompressed size (now that image is local)
  local size_mb
  size_mb=$(image_size_mb "$IMAGE")

  # Warm pull (image already in local store — should be near-instant)
  local warm_ms
  warm_ms=$(measure_warm_pull "$IMAGE")
  log "Warm pull: ${warm_ms}ms"

  local speedup_ms=$(( cold_ms - warm_ms ))

  # Optional: local registry measurement
  local registry_pull_ms=0
  if [[ -n "$LOCAL_REGISTRY" ]]; then
    registry_pull_ms=$(measure_registry_pull "$IMAGE" "$LOCAL_REGISTRY")
    log "Registry pull: ${registry_pull_ms}ms"
  fi

  cat <<JSON
{
  "cold_pull_ms": $cold_ms,
  "warm_pull_ms": $warm_ms,
  "image_size_mb": $size_mb,
  "compressed_size_mb": $compressed_mb,
  "speedup_ms": $speedup_ms,
  "registry_pull_ms": $registry_pull_ms,
  "image": "$IMAGE"
}
JSON
}

main "$@"
