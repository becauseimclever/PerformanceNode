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

### 2026-04-10: Approval gate before implementation
**By:** Fortinbra (via Copilot)  
**What:** No implementation work begins without explicit approval from Fortinbra. Specs, architecture decisions, and designs may be drafted, but no code or scripts are written until the user reviews and approves.  
**Why:** User directive — captured for team memory and process enforcement.

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

### 2026-04-10: MCU topology — harness is RP2040, three DUTs
**By:** Fortinbra (via Copilot)  
**What:** The test harness MCU is an RP2040. The three Devices Under Test (DUTs) are: 1x RP2040, 1x RP2350B, 1x RP2350A. Total: 4 MCUs on the HAT.  
**Why:** User clarification — defines roles for all MCUs on the HAT.  
**Impact:**
- Harness RP2040: has 1x UART back to the Pi host; aggregates and reports results
- DUT RP2040: receives flashed firmware, no UART to Pi
- DUT RP2350B: receives flashed firmware, no UART to Pi
- DUT RP2350A: receives flashed firmware, no UART to Pi
- All 4 MCUs still need SWD flash connections from Pi GPIO (per Treize's OpenOCD decision)
- GPIO pin table must include: SWD (SWDIO+SWDCLK) per MCU × 4, RESET per MCU × 4, UART TX/RX × 1 (harness only)
- Harness RP2040 likely communicates with DUTs via on-HAT wiring (not via Pi)

---

### 2026-04-10: No host USB to MCUs
**By:** Fortinbra (via Copilot)  
**What:** The Raspberry Pi host will NOT use USB to communicate with or flash any MCU. All MCU flashing goes through GPIO (SWD via OpenOCD linuxgpiod). No BOOTSEL/USB mass storage approach.  
**Why:** User directive — confirms Treize's SWD architecture decision and definitively rules out Heero's original BOOTSEL/USB approach.  
**Impact:** flash-mcu.py must be fully rewritten around OpenOCD SWD. No picotool, no USB mount logic needed anywhere in the action.

---

### 2026-04-10: Single UART — harness only
**By:** Fortinbra (via Copilot)  
**What:** Only ONE UART is required. The test harness MCU (one of the RP2040s) is the sole reporter — it aggregates results and sends them back to the Pi host. The other three MCUs (1x RP2040, 1x RP2350B, 1x RP2350A) receive only flashed firmware; they do not communicate over UART.  
**Why:** User clarification — simplifies GPIO pin allocation, config.txt overlays, and the UART result protocol.  
**Impact:**
- Treize's architecture (4x PL011 UARTs) must be revised → 1x UART
- Wufei's UART protocol spec may assume 4 independent streams → needs review
- HAT pin contract frees up significant GPIO pins previously reserved for 3 extra UARTs
- `config.txt` overlay requirements drop from 4 UARTs to 1

---

### 2026-04-10: UART Protocol Design and GitHub Summary Format
**By:** Wufei (Performance Engineer)  
**What:** Line-based ASCII text protocol (115200 8N1) for MCU → Pi UART communication. Test results use structured fields (test ID, duration, etc.); free-text messages colon-prefixed at end of line. GitHub Actions Step Summary uses collapsible `<details>` sections per MCU with overview table.

**Design decisions:**
1. **ASCII text, not binary** — human-readable via serial terminal, 140 ms for 200-test run
2. **Baud rate 115200 8N1** — universal standard, Pi PL011 native, zero rounding error
3. **LF-only** (not CRLF) — Pi Linux standard, reduces parsing
4. **Free-text fields last, colon-prefixed** (`msg:free text`) — avoids quoted strings, simple parser
5. **METRIC separate from PASS/FAIL** — performance data in distinct table, not mixed with verdicts
6. **Timeout detection parser-side** — firmware doesn't need heartbeat; parser watches inter-line silence
7. **Two parser modes:** normal (LOG allowed), strict (LOG rejected) — useful for development vs. CI
8. **GitHub summary uses collapsible sections** — 4 MCUs with 10–20 tests each; avoids wall-of-text

**Deliverables:**
- `docs/hardware/uart-result-protocol.md` — firmware dev contract
- `docs/hardware/github-output-format.md` — GitHub Step Summary template
- `scripts/mcu/validate-uart-output.py` — protocol validator

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

---

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

---

### 2026-04-11: GPIO MCU flash & test architecture
**By:** Treize (Lead)  
**What:** Complete architecture for flashing firmware to 4 MCUs (2× RP2040, 1× RP2350B, 1× RP2350A) on a custom Pi HAT and collecting test results via UART, all from within containerized GitHub Actions jobs.

**Three key decisions:**

1. **Container device passthrough via hook wrapper** — Extend `cache-hook-wrapper.js` to inject `--device=/dev/gpiochip4 --device=/dev/ttyAMA0` (etc.) into every job container's `createOptions`. No new services, no privileged containers, no host step bypass. Natural extension of existing cache injection architecture.

2. **SWD flashing via GPIO (OpenOCD + linuxgpiod)** — All MCUs flashed via SWD bit-banged through the 40-pin header using OpenOCD's `linuxgpiod` adapter. 3 GPIO pins per MCU (SWDIO, SWCLK, RESET). Total: 12 pins. No USB connections needed — everything on the HAT PCB.

3. **Single UART from harness MCU only** — Harness RP2040 aggregates results from 3 DUTs and sends over one UART to Pi (`/dev/ttyAMA2`). DUT MCUs do not connect directly to Pi UART.

**GPIO budget:** 18 of 28 pins allocated (10 available for future use). Layout: GPIO 0–1 reserved (HAT EEPROM), GPIO 2–3 reserved (I2C1), GPIO 4–5 (UART2 to harness), GPIO 6–9 (status LEDs), GPIO 16–27 (SWD + RESET for all 4 MCUs).

**Deliverables:**
- Spec: `docs/specs/0006-gpio-mcu-flash-test-action.md`
- HAT contract: `docs/hardware/hat-design-contract.md`

**Delegated to Heero:** Setup script, flash scripts, UART listener, hook wrapper extension, composite action.  
**Delegated to Wufei:** UART protocol and GitHub summary format (delivered).  
**Delegated to Noin:** Hardware validation, timeout/failure edge case testing.  
**Delegated to Fortinbra:** HAT PCB design per the hardware contract.

---

### 2026-04-11: UART Protocol Revised for Single-Stream Topology
**By:** Wufei (Performance Engineer)  
**What:** UART Result Protocol updated to support single-stream aggregation from harness MCU. All result messages (PASS, FAIL, SKIP, METRIC, LOG) now **require** an `mcu=<id>` field to identify source DUT within aggregated stream.

**Protocol changes:**
- **Physical layer:** Single UART from harness RP2040 to Pi (e.g., `/dev/ttyAMA2`)
- **Message format:** All result types now require `mcu=<id>` first field (TEST_START and TEST_END already had this)
- **Parser changes:** Per-DUT state tracking instead of per-port; per-DUT timeout watchdog

**Example:** 
```
TEST_START mcu=rp2040-0 fw=1.0.0 tests=2
PASS mcu=rp2040-0 gpio_test duration_us=500
PASS mcu=rp2040-0 uart_test duration_us=300
TEST_END mcu=rp2040-0 passed=2 failed=0 skipped=0
```

**Impact:** Breaking change — old 4-UART protocol format rejected; all firmware must include `mcu` field.

---

### 2026-04-13: Heero — Clean-State Validation Decision
**By:** Heero (Infrastructure Dev)  
**What:** PerformanceNode will support a **stable compatibility service name** of `actions-runner` even though `svc.sh install` creates the real GitHub runner unit as `actions.runner.<owner>-<repo>.<runner-name>.service`.

---

### 2026-04-13: User directive — Create GitHub issue first
**By:** Fortinbra (via Copilot)  
**What:** Going forward, create the GitHub issue first, then create the spec file.
**Why:** User request — clarifies workflow order to prevent spec drift from issues.

---

### 2026-04-14: User directive — Spec filenames must include GitHub issue number
**By:** Fortinbra (via Copilot)  
**What:** Every feature spec must correspond to a GitHub issue, and the spec filename must include the GitHub issue number.
**Why:** User request — enables traceability and clear linking between development tracking (issues) and design (specs).

---

### 2026-04-14: User directive — Ansible control node must be WSL/Ubuntu
**By:** Fortinbra (via Copilot)  
**What:** Ansible should not be run from Windows directly. Use the Ubuntu WSL instance as the Ansible control node.
**Why:** User requirement — captured for team memory. Ansible modules, SSH, and file permissions require POSIX semantics not available from Windows native shells.

---

### 2026-04-14: WSL `/mnt/c` Ansible config invocation
**By:** Heero (Infrastructure Dev)  
**What:** When the repo is run from Ubuntu WSL on a Windows-mounted path such as `/mnt/c/ws/PerformanceNode`, operators must export `ANSIBLE_CONFIG=$PWD/ansible.cfg` before invoking Ansible, or clone the repo into the WSL filesystem instead.  
**Why:** Real Stage 1 validation showed ansible-core ignores project-local `ansible.cfg` in world-writable directories, which makes inventory-based commands silently fall back to implicit localhost unless the config is passed explicitly.

---

### 2026-04-14: Stage 2 Common Base Role Spec Approved
**By:** Treize (Lead)  
**Status:** ✅ APPROVED — Ready for implementation
**Spec:** `docs/specs/3-common-role.md` (Stage 2)  
**Issue:** #3 (Stage 2: Common Base)

**Gate criteria review outcome:**
- ✅ Template completeness: All 9 sections present
- ✅ Acceptance criteria testability: 7 specific, measurable, testable criteria; no vague language
- ✅ Agent assignment: Heero (Implement), Treize (Review), Noin (Validate)
- ✅ GitHub issue: #3 verified open

**Key strengths:**
- SSH hardening justified by Stage 1 requirement
- Idempotency explicit (Criterion 6: `changed=0` on second run)
- SSH pre-flight check (test actual key login) catches operator mistakes before lockout
- Dependencies clear: Stage 1 prerequisite, Stage 3 enabler
- Out of Scope prevents creep

**Delegated to:** Heero for implementation; Treize for PR review; Noin for validation

---

### 2026-04-14: Staged Rollout Plan for Ansible Implementation
**By:** Treize (Lead)  
**Status:** Proposed and drafted
**Request:** Fortinbra — "Split implementation into small understandable chunks for incremental approval"

**Decision: Break implementation into 8 stages**, each with spec + GitHub issue + approval gate:

| Stage | Name | Key Deliverable |
|-------|------|-----------------|
| 1 | Inventory & Bootstrap | `ansible.cfg`, inventory, connectivity test |
| 2 | Common Base | `roles/common/` — SSH, packages, runner user |
| 3 | Docker Runtime | `roles/docker/` — Docker CE, daemon config |
| 4 | GitHub Runner Core | `roles/github_runner/` — download, register, systemd |
| 5 | Container Hooks | `roles/runner_hooks/` — Node.js, hooks, wrapper |
| 6 | Cache Infrastructure | `roles/caching/` — directories, bind mounts |
| 7 | Validation | Idempotency test, smoke test workflow |
| 8 | Documentation | README, runbook, architecture docs |

**Rationale:** Each stage 1–2 hours work, reviewable, produces visible output, unblocks next stage. Spec-driven gate respected throughout.

**Artifacts:** `docs/architecture/staged-rollout.md`, `docs/specs/TEMPLATE.md`, Stage 1–3 specs drafted (now numbered 2–4 per issue requirement).

---

### 2026-04-14: WSL/Ubuntu Control Node for Ansible Execution (Decision Record)
**By:** Treize (Lead)  
**Status:** Firm constraint

**Decision:** All Ansible playbook execution for PerformanceNode must happen inside Ubuntu WSL terminal, not Windows native shells.

**Rationale:**
1. Ansible requires POSIX semantics (file permissions, SSH client behavior, shell invocation)
2. Windows cmd.exe/PowerShell don't provide this; module failures occur
3. WSL 2 provides full Linux compatibility
4. SSH key management simpler (Unix filesystem enforces `600` permissions; NTFS incompatible)
5. Minimal setup (one-time WSL feature; `apt install ansible`)

**Implications:**
- ansible-reboot-proposal.md updated with "Operator Workflow" section
- staged-rollout.md updated with prominent ⚠️ warning
- README.md staged rollout section updated with WSL reminder
- All future specs assume WSL/Ubuntu control node

**Alternatives rejected:** Windows native Ansible (module behavior differs), Cygwin/MSYS2 (uncommon, still incompatible), move repo to WSL filesystem (limits flexibility), document workarounds (brittle).

**Status:** Firm constraint, not preference.

**Why:**
- Cache scripts and hook wiring need a deterministic place to stage systemd drop-ins before the runner is registered.
- Operators need a stable restart/status target that matches the documentation and verification flow.
- The real runner service name is registration-dependent, so scripts must discover it and sync staged drop-ins to the installed unit after registration.

**Implementation:**
- Cache scripts write drop-ins through a shared helper that targets the detected runner unit and also stages compatibility drop-ins under `actions-runner.service.d`.
- `setup-runner.sh` syncs staged drop-ins to the real installed unit and creates an `actions-runner.service` compatibility alias.

---

### 2026-04-13: Noin QA Refresh — LF line ending enforcement
**By:** Noin (Tester/QA)  
**What:** Add repository-level line-ending rules so shell, Python, YAML, and Markdown files are stored and checked out with **LF** endings via `.gitattributes`.

**Why:** PerformanceNode targets Raspberry Pi OS and relies heavily on Bash. CRLF endings break `bash -n` parsing on host-side validation, which would also break direct execution on the Pi.

**Scope:**
- `*.sh`, `*.py`, `*.yml`, `*.yaml`, `*.md`

---

### 2026-04-13: Archive Previous Implementation & Reset Main to Clean Slate
**By:** Treize (Lead)  
**What:** Completed implementation phase (Pi setup, runner, caching, MCU flash) archived on `archive/main-2026-04-13` branch; `main` reset to clean slate with team/squad scaffolding and decision history intact.

**What was archived:**
- `docs/specs/0001–0006` — Feature specifications with acceptance criteria
- `docs/hardware/` — HAT contract, UART protocol, GitHub output format
- `scripts/` — Full implementation (setup, cache, MCU, benchmarks)
- `examples/workflows/` — Example GitHub Actions workflows
- `setup.sh` — Top-level orchestrator

**What was kept on main:**
- `.squad/` — Team configuration, decisions, agent histories
- `.github/` — Workflows, CI/CD
- `README.md` — Updated to reflect reset state
- Repository metadata (`.gitignore`, `.gitattributes`)

**Why:** Preserve complete history and implementation for future reference, auditing, or rollback if needed. Clean foundation for next iteration.

---

### 2026-04-14: Ansible-First Architecture Reboot
**By:** Treize (Lead)  
**Status:** Proposed  
**What:** Pivot PerformanceNode from shell-script-first approach to **Ansible-first automation framework**. Phase 1 scope covers Raspberry Pi 5 self-hosted GitHub Actions runner setup.

**Decision summary:**
1. **Ansible as primary tool** — Idempotency built-in, declarative YAML, inventory-driven, role composition, reproducibility
2. **Phase 1 scope:** Pi 5 runner only (base OS, Docker, runner registration, container hooks, caching)
3. **Repository structure:** Standard Ansible layout with `playbooks/`, `roles/`, `inventories/`
4. **Spec-driven process continues** — Every role/playbook requires spec in `docs/specs/` before implementation
5. **Shell-script implementation archived** — Prior implementation on `archive/main-2026-04-13` branch remains for reference

**Key design decisions carried forward:**
- Container hooks architecture (jobs run in disposable containers via `ACTIONS_RUNNER_CONTAINER_HOOKS`)
- Cache bind-mount design (`/opt/runner-cache/*` bind-mounted into containers)
- Docker daemon config (overlay2 storage, JSON-file log rotation)
- Cgroup cmdline patch (`cgroup_memory=1 cgroup_enable=memory`)
- SSH hardening (key-based auth only)
- Non-root runner user

**Phase 2 deferred:**
- MCU/GPIO flash infrastructure
- Performance benchmarking suite
- Multi-host networking

**Open questions for Fortinbra:**
1. Bootstrap method (Raspberry Pi Imager, cloud-init, manual)
2. Runner token management (Vault, env var, GitHub App)
3. Ansible Galaxy collections (community.docker or builtins)

**Next steps:**
1. Fortinbra approves/amends proposal
2. Treize writes spec `0007-ansible-pi-runner-role.md`
3. GitHub issue created linking spec
4. Heero implements roles and playbook
5. Noin validates on fresh Pi

---

## Standing Principles

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
- Spec-driven process: all features must have a spec + GitHub issue before implementation
- Retroactive specs capture in-flight work and force clarity on acceptance
- No implementation without written feature spec first
- No feature spec implementation without explicit user approval
