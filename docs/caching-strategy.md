# Dependency Caching Strategy for PerformanceNode

**Author:** Wufei (Performance Engineer)  
**Date:** 2026-04-10  
**Status:** Approved — pending Heero implementation

---

## Context

PerformanceNode is a Raspberry Pi 5 (ARM64, Raspberry Pi OS Lite Bookworm) running as a GitHub Actions
self-hosted runner. Jobs execute in **disposable containers** (container isolation directive). Caches must
live on the Pi host filesystem and be mounted into containers at job start, because containers are torn
down after every job and carry no persistent state.

Two primary project types drive cache requirements:

| Project type | Cold-run bottleneck |
|---|---|
| .NET 10 | NuGet package restore (network download, ARM64 binary extraction) |
| Pico SDK (C/C++) | Pico SDK git clone + submodule init (~600 MB), ARM toolchain install, CMake compile |

---

## 1. NuGet Cache for .NET 10 in Containers

### Where NuGet Stores Packages

NuGet resolves the package cache directory in this priority order:

1. `$NUGET_PACKAGES` environment variable (explicit override — **use this**)
2. `~/.nuget/packages` (default when env var is unset)

Inside a container, `~` resolves to the container user's home directory, which is ephemeral.
Setting `NUGET_PACKAGES` to a host-mounted path is the correct override.

### ARM64-Specific Considerations

- .NET 10 ships native ARM64 RIDs (`linux-arm64`). NuGet downloads the ARM64 variant of native
  dependencies automatically — no cross-arch concern.
- The package cache is RID-tagged internally, so an ARM64 cache cannot be confused with an x64 cache
  if the host path is shared across architectures (not a concern here — Pi 5 is ARM64-only).
- Avoid using `actions/cache` with S3/blob backends for NuGet on self-hosted runners; the host-volume
  approach below is faster (local NVMe/SD vs. network round-trip).

### Recommended Host Path

```
/var/cache/actions-runner/nuget/
```

This directory is owned and writable by the `actions-runner` user (see §3).

### Mounting into Job Containers

In a GitHub Actions workflow, use the `container` key's `volumes` option to bind-mount:

```yaml
jobs:
  build-dotnet:
    runs-on: self-hosted
    container:
      image: mcr.microsoft.com/dotnet/sdk:10.0
      volumes:
        - /var/cache/actions-runner/nuget:/root/.nuget/packages
      env:
        NUGET_PACKAGES: /root/.nuget/packages
```

The `volumes` key accepts `host-path:container-path` syntax, identical to Docker `-v`.
Bind-mounting directly into `/root/.nuget/packages` means no env var override is needed, but setting
`NUGET_PACKAGES` explicitly is defensive and avoids surprises if the dotnet image uses a non-root user.

### `actions/cache` Integration Notes

`actions/cache` on self-hosted runners uploads/downloads to the GitHub cache service by default, which
requires network I/O and negates the local-disk speed advantage. **Do not use `actions/cache` for NuGet
on this runner.** The host-volume bind-mount described above is the canonical approach and is both
faster and free of storage quota limits.

If a workflow author insists on `actions/cache` for portability, set the cache key to
`nuget-arm64-${{ hashFiles('**/*.csproj') }}` and restore-keys to `nuget-arm64-`.

---

## 2. Pico SDK Dependency Cache

### 2a. Pico SDK Git Clone

The Pico SDK repository with all submodules is approximately **600–700 MB** on disk. Cloning it fresh on
every container run is unacceptable on a Pi (network-constrained, slow I/O).

**Strategy:** Clone once on the host. Mount read-only into every job container.

```
Host path:       /var/cache/actions-runner/pico-sdk/
Mount mode:      read-only (:ro)
Container path:  /opt/pico-sdk  (or wherever PICO_SDK_PATH points)
```

Host clone command (run once, or via Heero's setup script):

```bash
git clone --depth=1 https://github.com/raspberrypi/pico-sdk.git \
    /var/cache/actions-runner/pico-sdk
cd /var/cache/actions-runner/pico-sdk
git submodule update --init --recursive
```

Keep the SDK updated with a weekly cron or `workflow_dispatch` maintenance job:

```bash
cd /var/cache/actions-runner/pico-sdk
git fetch --depth=1 origin main
git reset --hard origin/main
git submodule update --recursive --remote
```

### 2b. ARM Cross-Compilation Toolchain (gcc-arm-none-eabi)

**Recommendation: Install in the base container image, not mounted from host.**

Rationale:
- The toolchain is a system-level binary tree (`/usr/lib/gcc-arm-none-eabi`, `/usr/bin/arm-none-eabi-*`).
  Mounting it correctly across container boundaries (shared libraries, PATH, ld.so) is fragile.
- `gcc-arm-none-eabi` is available in Debian/Ubuntu package repos and installs in ~2–3 minutes.
  Using a pre-built custom Docker image with the toolchain baked in is the correct solution.
- Build the custom image once, push to a local registry or Docker Hub, and reference it in workflows.

Suggested base image recipe (`Dockerfile.pico-builder`):

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-arm-none-eabi \
        libnewlib-arm-none-eabi \
        cmake \
        ninja-build \
        ccache \
        git \
        python3 \
    && rm -rf /var/lib/apt/lists/*
```

### 2c. CMake Build Artifacts (ccache)

ccache wraps the compiler and caches preprocessed object files. On a Pico project, ccache can reduce
incremental rebuild time from ~4 minutes to under 30 seconds after the first warm run.

**ccache configuration in containers:**

```yaml
env:
  CCACHE_DIR: /ccache          # container-visible path, mounted from host
  CCACHE_MAXSIZE: 2G
  CMAKE_C_COMPILER_LAUNCHER: ccache
  CMAKE_CXX_COMPILER_LAUNCHER: ccache
```

**Host path:** `/var/cache/actions-runner/ccache/`

Mount as read-write so ccache can populate on each run:

```yaml
volumes:
  - /var/cache/actions-runner/ccache:/ccache
  - /var/cache/actions-runner/pico-sdk:/opt/pico-sdk:ro
```

### 2d. `PICO_SDK_PATH` in Containers

Set `PICO_SDK_PATH` as a container environment variable pointing to the mount target:

```yaml
env:
  PICO_SDK_PATH: /opt/pico-sdk
```

CMake's `pico_sdk_import.cmake` reads this variable automatically. No CMakeLists.txt modification is
needed if `PICO_SDK_PATH` is set before `cmake` is invoked.

---

## 3. Host Storage Layout

### Proposed Directory Structure

```
/var/cache/actions-runner/
├── nuget/                   # NuGet package cache (rw, actions-runner:actions-runner)
│   └── [package]/[version]/ # NuGet internal layout — do not modify manually
├── pico-sdk/                # Pico SDK git clone + submodules (rw for maintenance, ro for jobs)
│   ├── src/
│   ├── lib/
│   └── ...
└── ccache/                  # ccache object cache for C/C++ builds (rw, actions-runner:actions-runner)
    └── [hash shards]/
```

### Estimated Storage Requirements

| Cache | Typical size | Maximum recommended cap |
|---|---|---|
| NuGet | 2–8 GB for typical .NET 10 projects | 10 GB |
| Pico SDK | ~700 MB (stable, updated weekly) | 1 GB |
| ccache | 500 MB–2 GB per project | 4 GB total |
| **Total** | **~4–11 GB** | **~15 GB** |

A 32 GB or 64 GB SD card / NVMe SSD is recommended to leave headroom for the OS and runner workspace.

### Cleanup / Cap Strategy

**NuGet cleanup** — run weekly via cron or maintenance workflow:

```bash
# Remove NuGet packages not accessed in 30 days
find /var/cache/actions-runner/nuget -mindepth 2 -maxdepth 2 -type d \
    -atime +30 -exec rm -rf {} +
```

Or use the dotnet CLI:

```bash
dotnet nuget locals global-packages --clear
# Then warm the cache from a representative project
```

**ccache** self-manages via `CCACHE_MAXSIZE`. When the cache exceeds the configured limit, ccache evicts
the least-recently-used entries automatically. No external cleanup needed.

**Pico SDK** does not grow — it is a fixed git tree. Only manual update via the maintenance script.

### File Permission Setup

```bash
# Run as root during initial Pi setup (Heero's setup script)
install -d -o actions-runner -g actions-runner -m 755 \
    /var/cache/actions-runner/nuget \
    /var/cache/actions-runner/ccache

# Pico SDK — root writes during maintenance, jobs mount read-only
install -d -o root -g root -m 755 /var/cache/actions-runner/pico-sdk
# Maintenance script runs as root or with sudo
```

Container users (`root` inside the container, or a configured non-root user) must match or the mount
will be permission-denied. For simplicity, use `root` inside builder containers or set
`--user $(id -u actions-runner):$(id -g actions-runner)` on the container.

---

## 4. GitHub Actions Workflow Snippets

### 4a. .NET 10 Build Job

```yaml
jobs:
  build-dotnet:
    runs-on: [self-hosted, pi5, arm64]
    container:
      image: mcr.microsoft.com/dotnet/sdk:10.0
      volumes:
        - /var/cache/actions-runner/nuget:/root/.nuget/packages
      env:
        NUGET_PACKAGES: /root/.nuget/packages
        DOTNET_CLI_TELEMETRY_OPTOUT: "1"
    steps:
      - uses: actions/checkout@v4
      - name: Restore NuGet packages
        run: dotnet restore
      - name: Build
        run: dotnet build --no-restore -c Release
      - name: Test
        run: dotnet test --no-build -c Release
```

### 4b. Pico SDK Build Job

```yaml
jobs:
  build-pico:
    runs-on: [self-hosted, pi5, arm64]
    container:
      image: ghcr.io/fortinbra/pico-builder:latest   # custom image with toolchain baked in
      volumes:
        - /var/cache/actions-runner/pico-sdk:/opt/pico-sdk:ro
        - /var/cache/actions-runner/ccache:/ccache
      env:
        PICO_SDK_PATH: /opt/pico-sdk
        CCACHE_DIR: /ccache
        CCACHE_MAXSIZE: 2G
        CMAKE_C_COMPILER_LAUNCHER: ccache
        CMAKE_CXX_COMPILER_LAUNCHER: ccache
    steps:
      - uses: actions/checkout@v4
      - name: Configure CMake
        run: cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
      - name: Build
        run: cmake --build build --parallel $(nproc)
      - name: ccache stats
        run: ccache --show-stats
```

### 4c. Weekly SDK Maintenance Workflow

```yaml
name: Maintain Pico SDK Cache
on:
  schedule:
    - cron: '0 2 * * 0'   # Sundays at 02:00 UTC
  workflow_dispatch:

jobs:
  update-pico-sdk:
    runs-on: [self-hosted, pi5, arm64]
    steps:
      - name: Update Pico SDK on host
        run: |
          cd /var/cache/actions-runner/pico-sdk
          git fetch --depth=1 origin main
          git reset --hard origin/main
          git submodule update --recursive --remote
```

---

## 5. Performance Impact Estimate

### .NET 10 Build

| Scenario | Estimated time |
|---|---|
| Cold (no cache, full NuGet download) | 8–15 min on Pi 5 (network + extraction) |
| Warm (all packages cached on host) | 30–90 sec (disk I/O only, no network) |
| **Time saving** | **~7–14 min per run** |

Key driver: NuGet downloads can pull 200–800 MB of packages for a typical .NET 10 solution. On a
constrained uplink (home/office broadband) and the Pi's limited storage I/O bandwidth (~40 MB/s on SD),
cold restores are severely penalized. NVMe SSD on Pi 5 via PCIe improves warm reads to ~300–500 MB/s,
further reducing warm-cache times.

**Network traffic reduction:** ~200–800 MB per build run (essentially zero once cache is warm).

### Pico SDK Build

| Scenario | Estimated time |
|---|---|
| Cold (clone SDK + submodules, build everything) | 12–20 min |
| Warm SDK mount + cold ccache (no object reuse) | 3–6 min |
| Warm SDK + warm ccache (most objects cached) | 20–60 sec |
| **Time saving vs. cold** | **~11–19 min per run (full warm)** |

Key drivers:
- Pico SDK clone + submodule init dominates cold time (~600–700 MB clone).
- The ARM cross-compiler (`arm-none-eabi-gcc`) is slow on the Pi's Cortex-A76 cores vs. x86 hosts;
  ccache object reuse cuts compile time by 80–90% on incremental builds.
- CMake configuration (scanning, dependency resolution) is ~10–20 sec and is not cached by ccache;
  persisting the `build/` directory in a named volume could further reduce this, but adds complexity
  (cache invalidation on source changes).

**Network traffic reduction:** ~700 MB per Pico SDK run (clone bypassed); toolchain APT download
~120 MB bypassed (baked into image).

---

## Summary

| Concern | Solution |
|---|---|
| NuGet packages | Host bind-mount `/var/cache/actions-runner/nuget` → `/root/.nuget/packages` in container |
| Pico SDK clone | Single host clone at `/var/cache/actions-runner/pico-sdk`, mounted `:ro` |
| ARM toolchain | Baked into custom Docker image (not mounted) |
| C/C++ objects | ccache at `/var/cache/actions-runner/ccache`, mounted `rw`, `CCACHE_MAXSIZE=2G` |
| Cache cleanup | NuGet: atime-based weekly cron; ccache: self-managing via MAXSIZE |
| Permissions | `actions-runner:actions-runner` owns nuget + ccache dirs; pico-sdk owned by root |
