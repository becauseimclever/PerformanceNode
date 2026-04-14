#!/usr/bin/env bash
# setup-docker-image-cache.sh — Pre-pull Docker base images for .NET 10 and
# Pico SDK jobs on the Pi 5 (ARM64 only).
#
# Pre-pulling images eliminates cold-start latency on the first run and ensures
# that images are available offline.  Uses `docker image inspect` to skip images
# that are already present.
#
# Usage: sudo ./setup-docker-image-cache.sh [--with-local-registry]
#
# Options:
#   --with-local-registry   Also start a local Docker registry on
#                           localhost:${REGISTRY_PORT} (default 5001) and
#                           re-tag + push all images to it.  Subsequent jobs
#                           can then pull from 127.0.0.1:5001 rather than the
#                           upstream registries.
#
# Environment variables:
#   REGISTRY_PORT       Local registry port   (default: 5001)
#   REGISTRY_DATA_DIR   Local registry data   (default: /opt/runner-cache/docker-registry)

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_DATA_DIR="${REGISTRY_DATA_DIR:-/opt/runner-cache/docker-registry}"
WITH_LOCAL_REGISTRY=false

# Images to pre-pull.  All must have linux/arm64 variants.
# Update tags here when moving to a new runtime version.
IMAGES=(
  # .NET 10 — SDK (build) and Runtime (run) images for ARM64
  "mcr.microsoft.com/dotnet/sdk:10.0"
  "mcr.microsoft.com/dotnet/runtime:10.0"
  "mcr.microsoft.com/dotnet/aspnet:10.0"

  # Pico SDK / C/C++ jobs — lightweight ARM64 Debian base
  # Jobs install gcc-arm-none-eabi + cmake themselves, or use a custom image.
  "debian:bookworm-slim"

  # General-purpose CI base (used when no container: is specified)
  "ubuntu:22.04"
)

# ── Argument parsing ───────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --with-local-registry) WITH_LOCAL_REGISTRY=true ;;
    *) echo "ERROR: Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Root check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

# ── Docker check ───────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed. Run the Docker setup script first." >&2
  exit 1
fi

if ! systemctl is-active --quiet docker; then
  echo "ERROR: Docker daemon is not running." >&2
  exit 1
fi

echo "==> Pre-pulling Docker images for ARM64..."

# ── 1. Pull each image (idempotent) ───────────────────────────────────────
for image in "${IMAGES[@]}"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "  SKIP  ${image} (already cached)"
  else
    echo "  PULL  ${image}"
    docker pull --platform linux/arm64 "$image"
  fi
done

# ── 2. Optional: local Docker registry ────────────────────────────────────
if [ "$WITH_LOCAL_REGISTRY" = true ]; then
  echo ""
  echo "==> Setting up local Docker registry on port ${REGISTRY_PORT}..."

  # Create data directory
  if [ ! -d "$REGISTRY_DATA_DIR" ]; then
    echo "  Creating ${REGISTRY_DATA_DIR}"
    mkdir -p "$REGISTRY_DATA_DIR"
  else
    echo "  ${REGISTRY_DATA_DIR} already exists — skipping"
  fi

  # Pull the official registry image if not present
  REGISTRY_IMAGE="registry:2"
  if ! docker image inspect "$REGISTRY_IMAGE" >/dev/null 2>&1; then
    echo "  Pulling ${REGISTRY_IMAGE}..."
    docker pull --platform linux/arm64 "$REGISTRY_IMAGE"
  else
    echo "  ${REGISTRY_IMAGE} already cached — skipping pull"
  fi

  # Create systemd service for the local registry
  REGISTRY_SERVICE="/etc/systemd/system/docker-registry.service"
  if [ ! -f "$REGISTRY_SERVICE" ]; then
    echo "  Creating systemd service: $REGISTRY_SERVICE"
    cat > "$REGISTRY_SERVICE" <<EOF
[Unit]
Description=Local Docker image registry
Documentation=https://distribution.github.io/distribution/
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/docker rm -f local-registry
ExecStart=/usr/bin/docker run --rm \\
  --name local-registry \\
  --platform linux/arm64 \\
  -p 127.0.0.1:${REGISTRY_PORT}:5000 \\
  -v ${REGISTRY_DATA_DIR}:/var/lib/registry \\
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \\
  ${REGISTRY_IMAGE}
ExecStop=/usr/bin/docker stop local-registry

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable docker-registry
    systemctl start docker-registry

    echo "  Waiting for registry to be ready..."
    for i in $(seq 1 10); do
      if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
        echo "  Registry is ready."
        break
      fi
      [ "$i" -eq 10 ] && echo "  WARNING: Registry may not be ready yet." && break
      sleep 2
    done
  else
    echo "  Registry service already configured — skipping"
  fi

  # Re-tag and push all images to the local registry
  echo ""
  echo "  Pushing images to local registry (127.0.0.1:${REGISTRY_PORT})..."
  for image in "${IMAGES[@]}"; do
    local_tag="127.0.0.1:${REGISTRY_PORT}/${image}"
    # Normalise the tag: strip registry prefix so mcr.microsoft.com/... → mcr.microsoft.com/...
    # For local registry we keep the full path as the repository name.
    if docker image inspect "${local_tag}" >/dev/null 2>&1; then
      echo "  SKIP  ${local_tag} (already in local registry)"
    else
      echo "  PUSH  ${image} → ${local_tag}"
      docker tag "$image" "$local_tag"
      docker push "$local_tag"
    fi
  done

  echo ""
  echo "  Local registry: http://localhost:${REGISTRY_PORT}"
  echo "  Example usage in workflow:"
  echo "    jobs:"
  echo "      build:"
  echo "        container: 127.0.0.1:${REGISTRY_PORT}/mcr.microsoft.com/dotnet/sdk:10.0"
fi

echo ""
echo "==> Docker image cache setup complete."
echo "    Cached images:"
for image in "${IMAGES[@]}"; do
  echo "      • ${image}"
done
[ "$WITH_LOCAL_REGISTRY" = true ] && echo "    Local registry: http://localhost:${REGISTRY_PORT}"
