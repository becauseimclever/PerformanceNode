# Spec: Dependency Caching (NuGet + Pico SDK)

| Field            | Value                                      |
|------------------|--------------------------------------------|
| **Issue**        | TBD (retroactive — create GitHub issue)    |
| **Author**       | Treize (based on Wufei's caching strategy) |
| **Status**       | 🚧 In Progress                             |
| **Created**      | 2026-04-10                                 |
| **Last Updated** | 2026-04-10                                 |

---

## Overview

Implement host-mounted cache directories on the Pi 5 so that containerized GitHub Actions jobs reuse previously downloaded .NET NuGet packages, the Pico SDK git clone, and compiled C/C++ object files (via ccache). This eliminates redundant network downloads and recompilation on every job, cutting build times from 10–20 minutes (cold) to under 2 minutes (warm).

## Problem Statement

Every containerized job starts from a clean filesystem. Without caching, each run:

- **NuGet:** Downloads 200–800 MB of .NET packages over the network, extracts them on the Pi's constrained I/O (8–15 minutes on a cold run).
- **Pico SDK:** Clones ~600–700 MB of git repositories (SDK + submodules) from GitHub, then installs ARM toolchain packages (~120 MB) — 12–20 minutes cold.
- **C/C++ compilation:** Recompiles every object file from scratch, even when source hasn't changed — 3–6 minutes for a typical Pico project.

This wastes bandwidth, burns SD card/SSD write cycles, and makes build times unacceptable for a performance testing node where fast iteration matters.

## Proposed Solution

Persistent cache directories on the Pi host filesystem, bind-mounted into job containers at runtime. Caches survive container teardown because they live on the host.

### NuGet Cache
- Host path: `/var/cache/actions-runner/nuget/`
- Mounted read-write into containers at `/root/.nuget/packages`
- `NUGET_PACKAGES` env var set explicitly for defensive correctness
- Weekly atime-based cleanup (packages not accessed in 30 days are removed)

### Pico SDK Cache
- Host path: `/var/cache/actions-runner/pico-sdk/`
- Single `git clone --depth=1` with `--recurse-submodules`, maintained by root
- Mounted **read-only** into containers at `/opt/pico-sdk`
- `PICO_SDK_PATH=/opt/pico-sdk` set as container env var
- Weekly update via systemd timer or maintenance workflow

### ccache (C/C++ Object Cache)
- Host path: `/var/cache/actions-runner/ccache/`
- Mounted read-write into containers
- `CCACHE_DIR`, `CCACHE_MAXSIZE=2G`, and `CMAKE_C_COMPILER_LAUNCHER=ccache` set as container env vars
- Self-managing: ccache evicts LRU entries when the size cap is exceeded

### ARM Cross-Compilation Toolchain
- **Not cached on host** — baked into a custom Docker image (`pico-builder`) instead
- Rationale: mounting system-level binary trees (`/usr/lib/gcc-arm-none-eabi`) across container boundaries is fragile; the toolchain belongs in the image layer

### Host Directory Layout
```
/var/cache/actions-runner/
├── nuget/      # rw, actions-runner:actions-runner, ~10 GB cap
├── pico-sdk/   # rw for maintenance (root), ro for jobs, ~700 MB
└── ccache/     # rw, actions-runner:actions-runner, 2 GB self-cap
```

Total storage budget: ~15 GB recommended cap. A 32 GB+ SD card or NVMe SSD is assumed.

## Acceptance Criteria

- [ ] `/var/cache/actions-runner/nuget/` exists with ownership `actions-runner:actions-runner` and mode `755`
- [ ] `/var/cache/actions-runner/ccache/` exists with ownership `actions-runner:actions-runner` and mode `755`
- [ ] `/var/cache/actions-runner/pico-sdk/` exists with ownership `root:root`, contains a valid Pico SDK git clone with submodules initialized
- [ ] A .NET 10 build job using the NuGet cache mount completes successfully; second run is measurably faster than first (warm vs. cold)
- [ ] NuGet packages downloaded during a build persist in `/var/cache/actions-runner/nuget/` after the container exits
- [ ] A Pico SDK build job using the SDK mount (`:ro`) and ccache mount (`:rw`) completes successfully
- [ ] ccache statistics (`ccache --show-stats`) show cache hits on the second build of the same project
- [ ] The NuGet cleanup cron/timer removes packages with atime > 30 days when executed
- [ ] The Pico SDK update script pulls the latest main branch and updates submodules without errors
- [ ] Cache setup scripts are idempotent — running them on an already-configured system produces no errors and no duplicate work
- [ ] All cache directories have correct ownership and permissions; container users can read/write as designed
- [ ] Cold vs. warm build time improvement is documented with measured numbers (Wufei's cache-metrics benchmarks)

## Out of Scope

- Docker image caching / registry setup (Docker's local image cache is implicit and managed by Docker Engine)
- `actions/cache` GitHub service integration — explicitly rejected for this runner (local disk is faster)
- Building and publishing the `pico-builder` custom Docker image (separate task, may get its own spec)
- Cache strategies for languages/tools beyond .NET and Pico SDK
- Network proxy or mirror configuration for package downloads

## Dependencies

- Spec 0001 (Pi 5 Base OS Setup) — Docker and the runner must be installed before caches can be mounted into containers

## Agent Assignment

| Agent  | Role in this spec                                                          |
|--------|----------------------------------------------------------------------------|
| Heero  | Primary implementer — cache directory creation, permissions, cron/timers, Pico SDK clone |
| Wufei  | Performance measurement — cold vs. warm benchmarks, cache-metrics scripts  |
| Noin   | Validates idempotency, permission correctness, cleanup behavior            |
| Treize | Review and sign-off                                                        |

## Notes

- The full caching strategy analysis is documented in `docs/caching-strategy.md` (authored by Wufei, 2026-04-10). This spec is the actionable subset — it defines what to build and how to verify it.
- Wufei has already written cache-metrics benchmark scripts in `scripts/performance/cache-metrics/`. These measure cold vs. warm performance for NuGet, Pico SDK, and Docker image pulls.
- The `actions/cache` service was explicitly rejected for this runner. See `docs/caching-strategy.md` §1 for rationale (local disk > network round-trip on a self-hosted runner).
- 2026-04-10: Retroactive spec created as part of the spec-driven process adoption. Wufei's caching strategy and Heero's implementation planning were already underway.
