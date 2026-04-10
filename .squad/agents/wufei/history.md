# Project Context

- **Project:** PerformanceNode
- **What:** Bash/shell setup scripts for a Raspberry Pi 5 running as a GitHub Actions self-hosted performance runner. Starting from a fresh Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm) install.
- **Owner:** Fortinbra
- **Team:** Treize (Lead), Heero (Infrastructure Dev), Wufei (Performance Engineer), Noin (Tester/QA)

## Core Context

Wufei initialized as Performance Engineer on 2026-04-10.

## Learnings

### 2026-04-10: Cache metrics benchmark scripts

Designed and implemented a full suite of cache effectiveness benchmark scripts for the three main cache layers (NuGet, Pico SDK/ccache, Docker images).

**Design decisions:**
- All timing uses `date +%s%3N` (milliseconds) — avoids `time` stderr-capture complexity.
- Network delta uses `/proc/net/dev` byte counters — available on all Linux systems, no `nethogs` required.
- ccache hit rate parsed from `ccache -s` output using awk — works across ccache 3.x and 4.x.
- Missing tools cause graceful JSON error output rather than script abort — CI won't fail if a tool is absent.
- NuGet warm run reuses packages written during cold run (copies to `/opt/cache/nuget` if empty) — simulates real cache-priming flow.
- Pico SDK: pre-populate ccache with a prep build, reset stats, then measure warm run — gives clean hit-rate numbers.
- Docker: `docker rmi` before cold pull; warm pull is a no-op that validates local layer store.
- Orchestrator (`run-all-cache-benchmarks.sh`) uses `python3` for JSON assembly — avoids `jq` dependency.

**Deliverables produced:**
- `scripts/performance/cache-metrics/measure-nuget-cache.sh`
- `scripts/performance/cache-metrics/measure-pico-sdk-cache.sh`
- `scripts/performance/cache-metrics/measure-docker-cache.sh`
- `scripts/performance/cache-metrics/run-all-cache-benchmarks.sh`
- `scripts/performance/cache-metrics/README.md`

### 2026-04-10: Dependency caching strategy for containerized jobs

Researched and documented a complete host-volume caching strategy for the two primary project types on PerformanceNode.

**Key findings:**
- NuGet: Use `$NUGET_PACKAGES` env var + host bind-mount. Do not use `actions/cache` on self-hosted — local disk beats GitHub cache service network round-trips by a large margin.
- Pico SDK: Single host clone (~700 MB) mounted read-only. ARM toolchain belongs in the container image, not in a host mount — shared library paths make host-mounting toolchains fragile.
- ccache: Highly effective for Pico SDK C/C++ builds. `CCACHE_MAXSIZE=2G` self-manages eviction. Set `CMAKE_C_COMPILER_LAUNCHER=ccache` in env rather than patching CMakeLists.txt.
- Time savings: ~7–14 min per .NET 10 run; ~11–19 min per Pico SDK run once fully warm.
- Network savings: 200–800 MB per .NET run; ~820 MB per Pico run.

**Deliverables produced:**
- `docs/caching-strategy.md` — full strategy with workflow snippets, storage layout, cleanup scripts.
- `.squad/decisions/inbox/wufei-dependency-caching.md` — team decision record with Heero action items.
