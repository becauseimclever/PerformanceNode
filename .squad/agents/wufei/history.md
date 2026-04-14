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

### 2026-04-10: UART Result Protocol and GitHub output format

Designed the complete wire protocol between MCU test firmware and the Pi parser, and the GitHub
Actions Step Summary rendering format.

**Protocol design decisions:**
- Line-based ASCII text (not binary) — human-readable with any serial monitor, easy to
  implement on bare-metal RP2040/RP2350 without printf complexity.
- 115200 baud 8N1 — reliable on Pi 5 PL011 and RP2040/RP2350 without fractional divider
  edge cases; ~140 ms for a 200-test run, negligible overhead.
- LF-only line endings — avoids CRLF stripping boilerplate in the parser.
- 256-byte max line length — safe for all MCU UART FIFO sizes.
- Free-text fields always last, colon-prefixed — avoids needing quoted strings or escaping
  spaces; simple `partition(':')` in the parser.
- 7 message types: TEST_START, PASS, FAIL, SKIP, METRIC, LOG, TEST_END — covers all needed
  result categories without overengineering.
- METRIC is not pass/fail — surfaced separately in GitHub Summary as a performance table.
- LOG lines are valid in normal mode, rejected in strict mode — supports firmware debug traces
  without polluting test results.
- Timeout detection is entirely parser-side (watchdog on inter-line silence) — firmware does
  not need a heartbeat mechanism.

**GitHub output design decisions:**
- `<details>` collapsible sections per MCU — avoids wall-of-text for large test suites.
- Emoji status at a glance in both overview table and section headers.
- FAIL table adds Error column; PASS-only tables omit it — keeps clean output when no failures.
- Duration displayed in human-readable ms/s form (converted from protocol's raw microseconds).
- Metrics in a separate sub-table — clear separation between pass/fail and performance data.
- Timed-out MCUs show tests received before timeout — partial data is better than nothing.

**Deliverables produced:**
- `docs/hardware/uart-result-protocol.md` — full protocol spec (firmware dev contract)
- `docs/hardware/github-output-format.md` — GitHub Step Summary template with example data
- `scripts/mcu/validate-uart-output.py` — protocol validator / debug utility
- `scripts/performance/cache-metrics/README.md` — updated with MCU metrics future section
- `.squad/decisions/inbox/wufei-uart-protocol-design.md` — team decision record

### 2026-04-11: UART protocol revised for single-stream topology

Fortinbra clarified the finalized hardware topology: the **harness RP2040** aggregates results
from all three DUT MCUs (RP2040-0, RP2350A, RP2350B) and reports them over **one UART** to the
Pi host. Previous protocol design assumed 4 independent UARTs (one per MCU).

**Topology update:**
- Single UART from harness RP2040 to Pi (e.g., `/dev/ttyAMA2` — exact pin TBD by Treize)
- Three DUT MCUs communicate results to harness MCU via on-HAT wiring (not directly to Pi)
- Pi parser receives one serial stream containing aggregated results

**Protocol revisions:**
- All result messages (PASS, FAIL, SKIP, METRIC, LOG) now **require** an `mcu=<id>` field
  to identify which DUT the result came from (essential for correct routing in single stream)
- TEST_START and TEST_END still include `mcu=<id>` to mark run boundaries per DUT
- Parser must maintain per-DUT state and route results by matching `mcu` field
- Single timeout watchdog architecture now tracks per-DUT silence separately

**Documentation updated:**
- `docs/hardware/uart-result-protocol.md` — replaced 4-UART references with single-stream model
- `docs/hardware/github-output-format.md` — updated wording for harness aggregation
- `scripts/mcu/validate-uart-output.py` — enforces `mcu` field presence on all result messages

**Validator testing:**
- Verified validator accepts correct single-stream captures (e.g., sequential per-DUT reports)
- Verified validator rejects PASS/FAIL/SKIP/METRIC/LOG lines missing `mcu` field (protocol error)
