# Squad Decisions

## Active Decisions

---

### 2026-04-10: Project initialized
**By:** Fortinbra (via Squad Coordinator)  
**What:** PerformanceNode — Raspberry Pi 5 setup scripts for a GitHub Actions self-hosted performance runner, targeting Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm). Scripts must be idempotent and unattended.  
**Universe:** Gundam Wing  
**Team:** Treize (Lead), Heero (Infrastructure), Wufei (Performance Engineer), Noin (Tester/QA)  
**Why:** Project kickoff.

---

### 2026-04-10: User directive — Container isolation required
**By:** Fortinbra (via Copilot)  
**What:** GitHub Actions jobs must NOT run directly on the Pi host OS. All jobs must execute inside disposable containers. The runner itself lives on the host, but each job is isolated in a container that is torn down after the job completes.  
**Why:** User requirement — captured for team memory. Affects infrastructure design (Docker required on host), runner configuration (container hooks or Docker executor), and performance test design (Wufei must account for container overhead in metrics).

---

### 2026-04-10: Container execution architecture decision
**By:** Treize (Lead)  
**What:** All GitHub Actions jobs on the PerformanceNode Pi 5 runner MUST execute inside disposable Docker containers via **GitHub Actions Runner Container Hooks** (`ACTIONS_RUNNER_CONTAINER_HOOKS`). The runner process itself remains a persistent systemd service on the host OS; it orchestrates jobs but never directly executes job steps on the host.

**Rationale:** Four approaches were evaluated:
- **Container Hooks** (`ACTIONS_RUNNER_CONTAINER_HOOKS`) — ✅ **Recommended**. Officially supported GitHub mechanism, transparent to workflow authors, lightweight, persistent runner + disposable containers, ARM64 well-supported.
- Explicit `container:` in workflow YAML — ❌ Opt-in only, cannot enforce isolation at runner level.
- Ephemeral runner per job (ARC / Kubernetes) — ❌ Far too heavy for a single Pi 5.
- Docker-in-Docker (DIND) — ❌ Nested overhead, security complexity, discouraged by Docker.

**Key implications for implementation:**
1. Install Docker Engine 24.x+ via official Docker apt repository (ARM64, Bookworm)
2. Configure Docker daemon with overlay2 storage driver and JSON-file log rotation (max-size: 10m, max-file: 3)
3. Create `runner` user (non-root), add to `docker` group
4. Patch `/boot/firmware/cmdline.txt` with `cgroup_memory=1 cgroup_enable=memory` for container memory limits
5. Install Node.js (LTS, ARM64) and `@actions/runner-container-hooks` npm package
6. Set `ACTIONS_RUNNER_CONTAINER_HOOKS` env var in systemd service unit
7. Create systemd service unit for runner (persistent, runs at boot)
8. **Do NOT install QEMU emulation** — fail fast on missing ARM64 images

**Delegated to Heero:** Docker install, daemon config, cgroup cmdline patch, hooks install, runner systemd unit.  
**Delegated to Wufei:** Establish container overhead baseline; distinguish lifecycle time from benchmark time.

---

### 2026-04-10: Spec-driven development process adopted
**By:** Treize (Lead)  
**What:** All implementation work must have an associated spec in `docs/specs/` and a linked GitHub issue. No code merges without both.

**Specification framework:**
- **Spec format:** `docs/specs/{issue-number}-{slug}.md` using `TEMPLATE.md`
- **Definition of Ready:** Complete template sections, testable acceptance criteria, explicit agent assignment, GitHub issue link
- **Ceremony:** Spec Review added to `.squad/ceremonies.md` as a before-implementation gate
- **Retroactive specs:** `0001-pi5-base-setup` and `0002-dependency-caching` created for in-flight work

**Key pattern:** Retroactive specs force clarity on "what does done actually look like?" and catch implicit assumptions before they become bugs. The template's "Out of Scope" section prevents scope creep.

**Implication for Squad Coordinator:** Must verify spec + GitHub issue exist before spawning implementation agents.  
**Directive source:** Fortinbra — "All features should come from a spec, and each spec should be associated with an issue on GitHub."

---

### 2026-04-10: Dependency caching architecture
**By:** Treize (Lead)  
**What:** All persistent caches live on the host under `/opt/runner-cache/` (or `/var/cache/actions-runner/`) and are transparently bind-mounted into every disposable job container via a custom container hooks wrapper. No additional running services (BaGet, local Docker registry) needed at this scale.

**Cache design:**
1. **NuGet:** Directory cache at `/opt/runner-cache/nuget`, bind-mounted to `/home/runner/.nuget/packages` (rw), `NUGET_PACKAGES` env var injected. Weekly cleanup of unused packages (>30 days atime). Do NOT use `actions/cache` service — local disk faster, no quota limits.

2. **Pico SDK:** Hybrid approach:
   - **Toolchain (GCC, CMake, Ninja, SDK source):** Baked into a custom Docker image (`performancenode/pico-sdk:<version>`) built locally on the Pi. Rebuilt only when SDK version changes.
   - **Build cache (ccache):** Bind-mounted at `/opt/runner-cache/ccache` (rw), capped at 2 GB with LRU self-eviction. `CCACHE_MAXSIZE`, `CMAKE_C_COMPILER_LAUNCHER` set via env.

3. **Docker images:** Pre-pull strategy for 2–3 base images. No local registry — not justified at this scale.

4. **Hook wrapper:** Custom `/opt/runner-hooks/cache-hook.js` wraps `@actions/runner-container-hooks` Docker hook, injects bind mounts and env vars into `prepare_job` container spec. Transparent to workflows — no YAML changes needed.

**Host directory layout:**
```
/opt/runner-cache/
├── nuget/    # rw, owned actions-runner:actions-runner, max ~10 GB
├── ccache/   # rw, owned actions-runner:actions-runner, max 2 GB
└── pico-sdk/ # ro for jobs, maintained by root, ~700 MB (if not in image)
```

**UID-safe permissions:** Cache directories use `chmod 1777` (sticky-bit world-writable) to handle UID mismatch between host and container processes.

**Delegated to Heero:** Create host directories, implement cache-hook.js wrapper, build Pico SDK Docker image, write pre-pull and cron scripts, update systemd unit.  
**Delegated to Wufei:** Measure cache hit rates, establish warm-vs-cold baselines, evaluate ccache compression overhead.

---

### 2026-04-10: Dependency caching strategy (Wufei)
**By:** Wufei (Performance Engineer)  
**What:** Concrete host-volume caching strategy for .NET 10 (NuGet) and Pico SDK (git clone + ccache). Full analysis documented in `docs/caching-strategy.md`.

**Performance targets:**
- **.NET 10:** Cold 8–15 min → Warm 30–90 sec (7–14 min savings)
- **Pico SDK:** Cold 12–20 min → Warm 20–60 sec (11–19 min savings)
- **Network savings:** 200–800 MB per .NET run; ~820 MB per Pico run

**Host cache paths:**
- NuGet: `/var/cache/actions-runner/nuget/` (or `/opt/runner-cache/nuget/` per Treize's decision)
- Pico SDK: `/var/cache/actions-runner/pico-sdk/` (read-only for jobs)
- ccache: `/var/cache/actions-runner/ccache/` (rw, self-capped at 2 GB)

**Key choices:**
- ARM cross-compiler (`gcc-arm-none-eabi`) baked into custom Docker image, not host-mounted (avoids shared library fragility)
- Pico SDK version pinned to git tag (not `main`) — reproducible builds, controlled weekly updates
- BaGet (local NuGet mirror) and local Docker registry both optional — not justified for a single Pi runner
- Weekly atime-based NuGet cleanup removes unused packages (>30 days)

---

### 2026-04-10: Cache metrics benchmark suite
**By:** Wufei (Performance Engineer)  
**What:** Automated benchmarking infrastructure for measuring cache effectiveness (5 scripts in `scripts/performance/cache-metrics/`).

**Metrics captured:**
- **NuGet:** cold/warm build time, speedup factor, packages from cache, network/disk I/O (cold vs. warm)
- **Pico SDK + ccache:** cold/warm build time, ccache hit rate %, toolchain overhead
- **Docker:** cold/warm pull time, image size, speedup
- **Combined:** summary JSON aggregating all three

**Design highlights:**
- Timing via `date +%s%3N` (milliseconds); no `jq` dependency
- Network delta from `/proc/net/dev` byte counters (portable, no extra tools)
- NuGet warm-up reuses cold run artifacts to simulate real bind-mount cache
- Pico SDK: prepare-measure-reset pattern for clean ccache hit-rate numbers
- Docker: `docker rmi` before cold pull; warm pull tests local layer store
- Graceful error handling for missing tools (JSON error output, exit 0)

---

### 2026-04-10: Cache scripts implemented (Heero)
**By:** Heero (Infrastructure Dev)  
**What:** Idempotent cache setup scripts (`scripts/cache/`, 5 files).

**Scripts created:**
1. `setup-nuget-cache.sh` — Create NuGet cache at `/opt/cache/nuget`, ownership, systemd drop-in with `NUGET_PACKAGES`
2. `setup-pico-sdk-cache.sh` — Install toolchain packages (Bookworm-pinned versions), clone Pico SDK at pinned version, create ccache, systemd drop-in
3. `setup-docker-image-cache.sh` — Pre-pull .NET 10, Debian, Ubuntu ARM64 images
4. `inject-cache-mounts.sh` — Install hook wrapper, systemd drop-in for `ACTIONS_RUNNER_CONTAINER_HOOKS`
5. `README.md` — Setup order, per-script docs, version update procedures

**Key design decisions:**
- Hook wrapper intercepts `prepare_job`, injects bind mounts + env vars before delegating to real Docker hook
- Priority: wrapper defaults first, then workflow `env:` overrides (workflow can override `PICO_SDK_PATH`)
- Pico SDK mounted read-only into containers (jobs should not modify shared tree)
- ARM GCC toolchain not automatically bind-mounted (too spread across system paths)
- BaGet and local Docker registry both opt-in flags for lightweight default setup
- All scripts use `set -euo pipefail` (idempotent, fail-safe)

**Open item:** Verify `@actions/runner-container-hooks` field names (`userMountVolumes`, `sourceVolumePath`, `targetVolumePath`) against installed package version.

---

### 2026-04-10: Three new feature specs drafted (0003, 0004, 0005)
**By:** Treize (Lead)  
**What:** Three new feature specifications drafted and placed in `docs/specs/`:

1. **0003-ssh-key-setup.md** — SSH key-based authentication setup (assigned to Heero, idempotent)
2. **0004-single-entry-point.md** — Single `setup.sh` orchestrator (assigned to Heero, phased execution)
3. **0005-csharp-example-workflow.md** — C# / .NET 10 example GitHub Actions workflow (assigned to Heero, with Noin testing)

**Status:** 📝 Drafted — awaiting GitHub issues and Spec Review ceremony.

**Why:** Close gaps in PerformanceNode:
- SSH hardening — fresh Pi uses password auth; needs key-based setup
- Orchestration — multiple setup scripts scattered; need single entry point
- User guidance — no example workflows; users need to know how to build .NET on the Pi runner

### 2026-04-10: SSH hardening, setup orchestrator, example .NET workflow (Heero)
**By:** Heero (Infrastructure Dev)  
**What:** Three deliverables created for SSH security, setup orchestration, and example workflows.

**Files created:**
1. `scripts/setup/setup-ssh.sh` — SSH hardening: key import + sshd_config hardening
2. `setup.sh` — Top-level setup orchestrator (single entry point for fresh Pi setup, phased execution)
3. `examples/workflows/dotnet-test.yml` — Ready-to-copy .NET 10 GitHub Actions workflow
4. `examples/workflows/README.md` — Index and notes for example workflows

**Key assumptions documented:**
- Scripts must be run as root for `sshd_config` modification and `sshd` restart
- `$HOME` resolves to operator's home (use `sudo -u actions-runner` for non-root case)
- `systemctl restart sshd` (Debian/Bookworm default; alternate: `ssh`)
- NuGet cache path in workflow resolves through hook wrapper env injection (container sees `/root/.nuget/packages`)
- `--non-interactive` flag support for CI environments
- Color output guarded by TTY detection (no pollution of logs)

**Open validation items for Noin:**
- SSH key import test (fresh Pi, no authorized_keys)
- Idempotency test (run twice, second run skips without error)
- Service name verification (sshd vs ssh)
- Non-interactive flag end-to-end test
- Setup.sh `--only=<phase>` and `--skip=<phase>` options
- NuGet env var resolution inside running container (hook wrapper precedence)
- dotnet-test.yml smoke test on real .NET 10 repo
- Root vs. non-root execution behavior

---

### 2026-04-11: GPIO MCU flash & test architecture
**By:** Treize (Lead)  
**What:** Complete architecture for flashing firmware to 4 MCUs (2× RP2040, 1× RP2350B, 1× RP2350A) on a custom Pi HAT and collecting test results via UART, all from within containerized GitHub Actions jobs.

**Three key decisions:**

1. **Container device passthrough via hook wrapper** — Extend `cache-hook-wrapper.js` to inject `--device=/dev/gpiochip4 --device=/dev/ttyAMA0` (etc.) into every job container's `createOptions`. No new services, no privileged containers, no host step bypass. Natural extension of existing cache injection architecture. Rejected: host step bypass (non-standard), privileged sidecar (over-engineered), systemd socket service (too many moving parts).

2. **SWD flashing via GPIO (OpenOCD + linuxgpiod)** — All MCUs flashed via SWD bit-banged through the 40-pin header using OpenOCD's `linuxgpiod` adapter. 3 GPIO pins per MCU (SWDIO, SWCLK, RESET). Total: 12 pins. No USB connections needed — everything on the HAT PCB. Rejected: BOOTSEL+USB (USB can't route through GPIO header), picotool (same USB limitation).

3. **4 dedicated hardware UARTs** — One Pi 5 PL011 UART per MCU via device tree overlays. UART0 (GPIO15) → RP2040-0, UART2 (GPIO5) → RP2040-1, UART3 (GPIO9) → RP2350B, UART4 (GPIO13) → RP2350A. 115200 8N1. Deterministic `/dev/ttyAMA*` paths. UART1 skipped (Bluetooth conflict risk).

**GPIO budget:** 24 of 28 pins. 8 UART + 12 SWD/RESET + 4 status LEDs. GPIO 0–1 reserved (HAT EEPROM). GPIO 2–3 reserved (future I2C1).

**Deliverables:**
- Spec: `docs/specs/0006-gpio-mcu-flash-test-action.md`
- HAT contract: `docs/hardware/hat-design-contract.md`
- Decision record: `.squad/decisions/inbox/treize-gpio-mcu-architecture.md`

**Delegated to Heero:** Setup script, flash scripts, UART listener, hook wrapper extension, composite action.  
**Delegated to Wufei:** UART protocol and GitHub summary format (already delivered).  
**Delegated to Noin:** Hardware validation, timeout/failure edge case testing.  
**Delegated to Fortinbra:** HAT PCB design per the hardware contract.

---

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
- Spec-driven process: all features must have a spec + GitHub issue before implementation
- Retroactive specs capture in-flight work and force clarity on acceptance
