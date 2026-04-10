#!/usr/bin/env bash
# measure-nuget-cache.sh — Measures .NET 10 build cache effectiveness.
# Outputs JSON: cold/warm build times, speedup, packages from cache, network bytes.
set -euo pipefail

NUGET_CACHE_DIR="${NUGET_CACHE_DIR:-/opt/cache/nuget}"
WORK_DIR="${WORK_DIR:-/tmp/nuget-bench}"
TEST_PROJECT="${TEST_PROJECT:-}"  # Path to a .csproj; auto-generated if empty

# ---------- helpers ----------

log()  { echo "[nuget-cache] $*" >&2; }
warn() { echo "[nuget-cache] WARN: $*" >&2; }

require_tool() {
  command -v "$1" >/dev/null 2>&1
}

now_ms() { date +%s%3N; }

net_bytes() {
  # Sum RX + TX bytes across all non-loopback interfaces from /proc/net/dev
  awk 'NR>2 && !/lo:/ { gsub(/:/, " "); rx+=$2; tx+=$10 } END { print rx+tx }' \
    /proc/net/dev 2>/dev/null || echo 0
}

disk_read_bytes() {
  # Sum read bytes from /proc/diskstats (sectors * 512)
  awk '{ reads+=$6 } END { print reads*512 }' /proc/diskstats 2>/dev/null || echo 0
}

# ---------- project scaffolding ----------

create_test_project() {
  local dir="$1"
  mkdir -p "$dir/TestApp"
  cat >"$dir/TestApp/TestApp.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <!-- Common packages that exercise the NuGet cache -->
    <PackageReference Include="Microsoft.Extensions.Logging" Version="9.0.0" />
    <PackageReference Include="Microsoft.Extensions.DependencyInjection" Version="9.0.0" />
    <PackageReference Include="System.Text.Json" Version="9.0.0" />
  </ItemGroup>
</Project>
EOF
  cat >"$dir/TestApp/Program.cs" <<'EOF'
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.DependencyInjection;

var services = new ServiceCollection();
services.AddLogging(b => b.AddConsole());
var sp = services.BuildServiceProvider();
var logger = sp.GetRequiredService<ILogger<Program>>();
logger.LogInformation("NuGet cache benchmark");
EOF
}

# ---------- measurement ----------

measure_build() {
  local label="$1"
  local nuget_home="$2"   # NUGET_PACKAGES env var
  local project_dir="$3"

  local net_before disk_before t0 t1 net_after disk_after elapsed_ms

  net_before=$(net_bytes)
  disk_before=$(disk_read_bytes)
  t0=$(now_ms)

  NUGET_PACKAGES="$nuget_home" dotnet restore "$project_dir" --no-cache 2>&1 | \
    grep -E "^  (Restored|Installing|Writing)" >&2 || true
  NUGET_PACKAGES="$nuget_home" dotnet build "$project_dir" --no-restore 2>&1 | \
    tail -5 >&2 || true

  t1=$(now_ms)
  net_after=$(net_bytes)
  disk_after=$(disk_read_bytes)

  elapsed_ms=$(( t1 - t0 ))
  net_delta=$(( net_after - net_before ))
  disk_delta=$(( disk_after - disk_before ))

  log "$label: ${elapsed_ms}ms, net_bytes=${net_delta}, disk_read_bytes=${disk_delta}"
  echo "$elapsed_ms $net_delta $disk_delta"
}

count_packages_from_cache() {
  local nuget_home="$1"
  local project_dir="$2"
  # Count .nupkg files in the NuGet home to proxy cache hits
  find "$nuget_home" -name "*.nupkg" 2>/dev/null | wc -l || echo 0
}

# ---------- main ----------

main() {
  if ! require_tool dotnet; then
    warn "dotnet not found — skipping NuGet cache measurement"
    echo '{"error":"dotnet not found","cold_build_ms":0,"warm_build_ms":0,"speedup_factor":0,"packages_from_cache":0,"network_bytes_cold":0,"network_bytes_warm":0}'
    exit 0
  fi

  mkdir -p "$WORK_DIR"

  local project_dir
  if [[ -n "$TEST_PROJECT" ]]; then
    project_dir="$TEST_PROJECT"
  else
    create_test_project "$WORK_DIR"
    project_dir="$WORK_DIR/TestApp"
  fi

  local cold_cache_dir="$WORK_DIR/nuget-cold"
  local warm_cache_dir="$NUGET_CACHE_DIR"
  mkdir -p "$cold_cache_dir"

  # --- Cold build (empty local cache, packages must be downloaded) ---
  log "Running COLD build (empty cache)…"
  read -r cold_ms cold_net cold_disk < <(measure_build "cold" "$cold_cache_dir" "$project_dir")

  # --- Warm build (reuse packages from cold run as populated cache) ---
  log "Running WARM build (cache populated from cold run)…"
  # Copy cold cache to warm location if the designated cache dir is empty
  if [[ -d "$warm_cache_dir" ]] && [[ -z "$(ls -A "$warm_cache_dir" 2>/dev/null)" ]]; then
    cp -r "$cold_cache_dir/." "$warm_cache_dir/" 2>/dev/null || true
  elif [[ ! -d "$warm_cache_dir" ]]; then
    cp -r "$cold_cache_dir" "$warm_cache_dir"
  fi

  read -r warm_ms warm_net warm_disk < <(measure_build "warm" "$warm_cache_dir" "$project_dir")

  local packages_from_cache
  packages_from_cache=$(count_packages_from_cache "$warm_cache_dir" "$project_dir")

  local speedup
  if [[ "$warm_ms" -gt 0 ]]; then
    # Use awk for float division
    speedup=$(awk "BEGIN { printf \"%.2f\", $cold_ms / $warm_ms }")
  else
    speedup="0"
  fi

  # Output JSON
  cat <<JSON
{
  "cold_build_ms": $cold_ms,
  "warm_build_ms": $warm_ms,
  "speedup_factor": $speedup,
  "packages_from_cache": $packages_from_cache,
  "network_bytes_cold": $cold_net,
  "network_bytes_warm": $warm_net,
  "disk_read_bytes_cold": $cold_disk,
  "disk_read_bytes_warm": $warm_disk
}
JSON

  # Cleanup scratch dir (not the persistent cache)
  rm -rf "$cold_cache_dir" "$WORK_DIR/TestApp" 2>/dev/null || true
}

main "$@"
