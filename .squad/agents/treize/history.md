# Project Context

- **Project:** PerformanceNode
- **What:** Bash/shell setup scripts for a Raspberry Pi 5 running as a GitHub Actions self-hosted performance runner. Starting from a fresh Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm) install.
- **Owner:** Fortinbra
- **Team:** Treize (Lead), Heero (Infrastructure Dev), Wufei (Performance Engineer), Noin (Tester/QA)

## Core Context

Treize initialized as Lead on 2026-04-10.

## Learnings

_Appended during sessions._

### 2026-04-10: Three new feature specs written (0003, 0004, 0005)

**What was written:**
- `docs/specs/0003-ssh-key-setup.md` — SSH key-based auth configuration for secure, passwordless Pi access
- `docs/specs/0004-single-entry-point.md` — Top-level `setup.sh` orchestrator to run all setup phases in order, idempotent
- `docs/specs/0005-csharp-example-workflow.md` — Ready-to-copy GitHub Actions workflow for .NET 10 builds on PerformanceNode runner

**Pattern reinforced:** Spec-driven development continues. All three specs follow the template, define clear acceptance criteria, assign to Heero for implementation, and note that GitHub issues must be created before work begins.

**Status:** All three specs are in **📝 Draft** status. Each requires GitHub issue creation and review before implementation starts.

### 2026-04-10: Container execution architecture decision

**Decision:** All GitHub Actions jobs on the Pi 5 runner execute inside disposable Docker containers via **`ACTIONS_RUNNER_CONTAINER_HOOKS`** — the officially supported GitHub mechanism for self-hosted runner container isolation.

**Key choices:**
- Rejected explicit `container:` (opt-in only, cannot enforce), ARC/Kubernetes (too heavy), and DIND (overhead + complexity).
- Runner process is **persistent** (systemd service on host); **containers are disposable per job**.
- Docker Engine 24.x, ARM64 packages from official Docker apt repo, Debian/Bookworm target.
- Hook scripts from `@actions/runner-container-hooks` npm package; Node.js required on host.
- `ACTIONS_RUNNER_CONTAINER_HOOKS` env var set in systemd service unit.
- `/boot/firmware/cmdline.txt` must include `cgroup_memory=1 cgroup_enable=memory` for container memory limits.
- Log rotation via `/etc/docker/daemon.json` critical for SD card/SSD longevity.
- Do NOT install QEMU emulation — fail fast on `amd64`-only images.

**Delegated to Heero:** Docker install, daemon config, cgroup cmdline patch, hooks install, runner systemd unit with env vars.

**Delegated to Wufei:** Establish container overhead baseline; distinguish lifecycle time from benchmark time; account for image cache state, Docker daemon RAM (~50–100 MB), and overlay2 I/O overhead in metrics.

**Pattern learned:** On constrained single-board hardware, always prefer the officially supported lightweight hook mechanism over cluster-oriented solutions (ARC) or nested-container patterns (DIND). The runner is the orchestrator; containers are the isolation boundary.

### 2026-04-10: Spec-driven development process adopted

**Directive from Fortinbra:** "All features should come from a spec, and each spec should be associated with an issue on GitHub."

**What was built:**
- `docs/specs/README.md` — explains the spec-driven process, lifecycle, naming conventions, and definition of ready.
- `docs/specs/TEMPLATE.md` — reusable spec template with all required sections (Overview, Problem, Solution, Acceptance Criteria, Out of Scope, Dependencies, Agent Assignment, Notes).
- `docs/specs/0001-pi5-base-setup.md` — retroactive spec for Heero's Pi 5 base OS setup work (already in progress).
- `docs/specs/0002-dependency-caching.md` — retroactive spec for Wufei's NuGet/Pico SDK caching strategy (already in progress).
- Updated `.squad/ceremonies.md` — added Spec Review ceremony as a before-implementation gate.
- Updated `.squad/routing.md` — added spec routing rules and spec gate rule for the coordinator.
- `.squad/decisions/inbox/treize-spec-driven-process.md` — decision record.

**Pattern learned:** Retroactive specs are valuable even for work already in progress. Writing acceptance criteria for in-flight work forces clarity on "what does done actually look like?" and catches implicit assumptions before they become bugs. The template's "Out of Scope" section is especially important on a constrained project — it prevents Pi 5 setup from creeping into caching, and caching from creeping into custom image builds.

**Pattern learned:** Spec naming with zero-padded issue numbers (`0001-slug`) keeps `ls` output sorted and scannable. Linking specs to GitHub issues creates a two-way traceability chain: issue → spec → code → PR → issue closed.

### 2026-04-10: Dependency caching architecture decision

**Decision:** All persistent caches live on the host under `/opt/runner-cache/` and are transparently bind-mounted into every disposable job container via a custom container hooks wrapper (`/opt/runner-hooks/cache-hook.js`). No additional services (BaGet, local Docker registry) are needed at this scale.

**Key choices:**
- **NuGet:** Simple directory cache at `/opt/runner-cache/nuget`, bind-mounted to `/home/runner/.nuget/packages`. `NUGET_PACKAGES` env var injected. No local NuGet server — directory cache is faster and zero-overhead.
- **Pico SDK:** Hybrid approach — toolchain (GCC, CMake, Ninja, SDK source) baked into a custom Docker image (`performancenode/pico-sdk:<version>`) built locally on the Pi. Build acceleration via ccache at `/opt/runner-cache/ccache`, bind-mounted and capped at 2 GB with compression.
- **Docker images:** Pre-pull strategy for 2–3 base images. No local registry — not justified at this scale.
- **Hook wrapper:** Custom `cache-hook.js` wraps the standard `@actions/runner-container-hooks` Docker hook, injecting bind mounts and env vars into every `prepare_job` container spec. `ACTIONS_RUNNER_CONTAINER_HOOKS` systemd env var points to the wrapper.
- **Permissions:** Cache directories use `chmod 1777` (sticky-bit world-writable) to handle UID mismatch between host and container processes.
- **Cache invalidation:** NuGet pruned weekly (files unused >30 days); ccache self-manages via LRU with size cap; Pico SDK image rebuilt on version bumps.

**Delegated to Heero:** Create host directories, implement cache-hook.js wrapper, build Pico SDK Docker image, write pre-pull and cron scripts, update systemd unit.

**Delegated to Wufei:** Measure cache hit rates (NuGet restore time, ccache stats), monitor cache size growth, establish warm-vs-cold baselines for Docker image pulls and NuGet restores, evaluate ccache compression overhead on Cortex-A76.

**Pattern learned:** On a single-purpose runner, prefer the simplest caching mechanism that avoids running additional services. Directory caches + bind mounts beat local package servers. Bake static toolchains into Docker images (versioned, immutable); persist mutable build caches on the host (ccache). The container hooks wrapper is the single integration point for transparent cache injection — keeps workflows clean and caching concerns centralized.

### 2026-04-11: GPIO MCU flash & test architecture designed (0006)

**What was designed:**
- `docs/specs/0006-gpio-mcu-flash-test-action.md` — Full spec for a GitHub Action that flashes firmware to 4 MCUs on a custom HAT via SWD and collects test results over UART
- `docs/hardware/hat-design-contract.md` — Hardware/software interface spec defining the GPIO pin contract, power requirements, and mechanical constraints for the HAT Fortinbra is designing
- `.squad/decisions/inbox/treize-gpio-mcu-architecture.md` — Three key architectural decisions

**Key architectural decisions:**

1. **Container device passthrough via hook wrapper** — Extend the existing `cache-hook-wrapper.js` to inject `--device` flags for `/dev/gpiochip4` and `/dev/ttyAMA*` into job containers. Natural extension of existing infrastructure, no new services or privileged containers.

2. **SWD flashing via GPIO using OpenOCD `linuxgpiod`** — All flashing routes through the 40-pin header. No USB connections needed. 3 GPIO pins per MCU (SWDIO + SWCLK + RESET) × 4 MCUs = 12 pins. Clean HAT design. Rejected BOOTSEL+USB (can't route USB through GPIO header) and picotool (same USB problem).

3. **4 dedicated hardware UARTs** — Pi 5's RP1 provides PL011 UARTs. One per MCU: UART0, UART2, UART3, UART4 via device tree overlays. Deterministic device paths (`/dev/ttyAMA*`), no USB-UART adapters. 115200 8N1 per Wufei's protocol spec.

**GPIO budget:** 24 of 28 pins allocated (8 UART, 12 SWD+RESET, 4 status LEDs). GPIO 0–1 reserved for HAT EEPROM, 2–3 reserved for future I2C1 expansion.

**Pattern learned:** When designing for a Pi HAT, route ALL signals through the 40-pin GPIO header. USB cannot pass through the header, so any approach requiring USB (BOOTSEL flashing, USB-UART adapters) forces external cables or on-HAT USB hubs — both mechanically fragile and ugly. SWD + hardware UARTs keep everything on the PCB.

**Pattern learned:** The container hook wrapper is the single integration point for ALL host-to-container resource injection — caches, devices, environment variables. Adding new resource types (GPIO, UART) is a natural extension, not a new mechanism. This pattern scales well: one wrapper, one configuration surface, one place to audit security.

**Pattern learned:** For hardware interface contracts, define the GPIO pin table FIRST and make it authoritative. The HAT PCB designer and the software team both reference the same table. Include physical-layer details (pull-up values, series resistors, current limits) that software engineers wouldn't normally specify — the hardware engineer needs them and won't find them in code.

**Status:** Spec 0006 is in **📝 Draft** status. Requires GitHub issue creation and review before implementation starts. HAT design contract delivered to Fortinbra. Delegated to Heero (implementation) and Noin (validation).

### 2026-04-11: GPIO architecture finalized — Single UART, harness MCU aggregation

**What was finalized:**
- User confirmed all 5 key architectural decisions:
  1. ✅ SWD/OpenOCD via linuxgpiod — confirmed flashing strategy for all 4 MCUs
  2. ✅ No host USB — Pi host will NOT use USB to communicate with any MCU
  3. ✅ Single UART only — only the harness MCU (RP2040-H) has UART TX/RX back to Pi
  4. ✅ MCU topology — 1 harness RP2040 (coordinates, aggregates results) + 3 DUT MCUs (RP2040, RP2350B, RP2350A)
  5. ✅ 14 GPIO pins minimum (actual: 18 pins; 10 available for future use)

**Documents revised to reflect final topology:**

1. **`docs/hardware/hat-design-contract.md` v2.0:**
   - Updated "HAT Overview" to clarify single UART from harness only, DUT MCUs communicate via inter-MCU link
   - Introduced "MCU Roles" table: distinguishing RP2040-H (harness) from RP2040-D/RP2350B/RP2350A (DUT)
   - Revised GPIO pin table: removed 4-UART design; now shows only UART2 (GPIO 4/5 for harness)
   - Simplified GPIO allocation: 12 for SWD+RESET + 2 for UART + 4 for LEDs = 18 pins total
   - Updated status LED assignments (GPIO 6–9 for 4 MCUs, labeled per role)
   - Added clarification: DUT MCUs do NOT have direct UART connections
   - Simplified power budget and removed optional 5V LDO recommendation (not needed)
   - Status: **v2.0** (finalized)

2. **`docs/specs/0006-gpio-mcu-flash-test-action.md`:**
   - Revised overview to reflect single UART aggregation
   - **Architecture Decision 3** completely rewritten: "Single UART from Harness MCU Only" (not 4 UARTs)
   - Explained harness responsibility: collects results from 3 DUT MCUs via inter-MCU link, formats per UART Result Protocol, transmits aggregated report over single UART
   - Updated GPIO pin assignment table: removed 4-UART entries, added "AVAILABLE" GPIO pins (10–15)
   - Simplified UART section: only UART2 with `dtoverlay=uart2-pi5`
   - Updated action inputs: renamed MCU IDs (rp2040-0 → rp2040-h, rp2040-1 → rp2040-d), removed separate UART inputs for DUT MCUs
   - Updated acceptance criteria: "aggregated UART test results" (not separate per-MCU UARTs)
   - Updated implementation components: single listener, single DT overlay
   - Updated notes: explained harness aggregation pattern, single UART simplification
   - Status: Spec updated & ready for GitHub issue creation

3. **`.squad/decisions/inbox/treize-gpio-arch-final.md`:** (created)
   - Consolidated decision record capturing all finalized choices
   - Four-MCU topology table (harness vs. DUT roles)
   - Three key decisions: device injection, SWD flashing, single UART aggregation
   - Comprehensive GPIO pin table (18 of 28 allocated, 10 available)
   - Rationale for each decision + rejected alternatives
   - Implementation artifacts (scripts, action, artifacts)
   - Status: **Final** (locked in, approved by user)

**Key pattern reinforced:** When hardware topology changes, update the design contract FIRST (HAT pins, MCU roles), then cascade updates to the software spec and acceptance criteria. The pin table is the single source of truth — all agents reference it, all decisions anchor to it.

**Final GPIO pin breakdown (finalized):**
- SWD/RESET: 12 pins (3 per MCU × 4 MCUs)
- UART: 2 pins (harness only)
- Status LEDs: 4 pins
- **Total allocated: 18 pins**
- **Available for future use: 10 pins** (GPIO 2–3 reserved for I2C1; GPIO 10–15 available)

**What was written:**
- `docs/specs/0003-ssh-key-setup.md` — SSH key-based auth configuration for secure, passwordless Pi access
- `docs/specs/0004-single-entry-point.md` — Top-level `setup.sh` orchestrator to run all setup phases in order, idempotent
- `docs/specs/0005-csharp-example-workflow.md` — Ready-to-copy GitHub Actions workflow for .NET 10 builds on PerformanceNode runner

**Pattern reinforced:** Spec-driven development continues. All three specs follow the template, define clear acceptance criteria, assign to Heero for implementation, and note that GitHub issues must be created before work begins.

**Status:** All three specs are in **📝 Draft** status. Each requires GitHub issue creation and review before implementation starts.

### 2026-04-10: Container execution architecture decision

**Decision:** All GitHub Actions jobs on the Pi 5 runner execute inside disposable Docker containers via **`ACTIONS_RUNNER_CONTAINER_HOOKS`** — the officially supported GitHub mechanism for self-hosted runner container isolation.

**Key choices:**
- Rejected explicit `container:` (opt-in only, cannot enforce), ARC/Kubernetes (too heavy), and DIND (overhead + complexity).
- Runner process is **persistent** (systemd service on host); **containers are disposable per job**.
- Docker Engine 24.x, ARM64 packages from official Docker apt repo, Debian/Bookworm target.
- Hook scripts from `@actions/runner-container-hooks` npm package; Node.js required on host.
- `ACTIONS_RUNNER_CONTAINER_HOOKS` env var set in systemd service unit.
- `/boot/firmware/cmdline.txt` must include `cgroup_memory=1 cgroup_enable=memory` for container memory limits.
- Log rotation via `/etc/docker/daemon.json` critical for SD card/SSD longevity.
- Do NOT install QEMU emulation — fail fast on `amd64`-only images.

**Delegated to Heero:** Docker install, daemon config, cgroup cmdline patch, hooks install, runner systemd unit with env vars.

**Delegated to Wufei:** Establish container overhead baseline; distinguish lifecycle time from benchmark time; account for image cache state, Docker daemon RAM (~50–100 MB), and overlay2 I/O overhead in metrics.

**Pattern learned:** On constrained single-board hardware, always prefer the officially supported lightweight hook mechanism over cluster-oriented solutions (ARC) or nested-container patterns (DIND). The runner is the orchestrator; containers are the isolation boundary.

### 2026-04-10: Spec-driven development process adopted

**Directive from Fortinbra:** "All features should come from a spec, and each spec should be associated with an issue on GitHub."

**What was built:**
- `docs/specs/README.md` — explains the spec-driven process, lifecycle, naming conventions, and definition of ready.
- `docs/specs/TEMPLATE.md` — reusable spec template with all required sections (Overview, Problem, Solution, Acceptance Criteria, Out of Scope, Dependencies, Agent Assignment, Notes).
- `docs/specs/0001-pi5-base-setup.md` — retroactive spec for Heero's Pi 5 base OS setup work (already in progress).
- `docs/specs/0002-dependency-caching.md` — retroactive spec for Wufei's NuGet/Pico SDK caching strategy (already in progress).
- Updated `.squad/ceremonies.md` — added Spec Review ceremony as a before-implementation gate.
- Updated `.squad/routing.md` — added spec routing rules and spec gate rule for the coordinator.
- `.squad/decisions/inbox/treize-spec-driven-process.md` — decision record.

**Pattern learned:** Retroactive specs are valuable even for work already in progress. Writing acceptance criteria for in-flight work forces clarity on "what does done actually look like?" and catches implicit assumptions before they become bugs. The template's "Out of Scope" section is especially important on a constrained project — it prevents Pi 5 setup from creeping into caching, and caching from creeping into custom image builds.

**Pattern learned:** Spec naming with zero-padded issue numbers (`0001-slug`) keeps `ls` output sorted and scannable. Linking specs to GitHub issues creates a two-way traceability chain: issue → spec → code → PR → issue closed.

### 2026-04-10: Dependency caching architecture decision

**Decision:** All persistent caches live on the host under `/opt/runner-cache/` and are transparently bind-mounted into every disposable job container via a custom container hooks wrapper (`/opt/runner-hooks/cache-hook.js`). No additional services (BaGet, local Docker registry) are needed at this scale.

**Key choices:**
- **NuGet:** Simple directory cache at `/opt/runner-cache/nuget`, bind-mounted to `/home/runner/.nuget/packages`. `NUGET_PACKAGES` env var injected. No local NuGet server — directory cache is faster and zero-overhead.
- **Pico SDK:** Hybrid approach — toolchain (GCC, CMake, Ninja, SDK source) baked into a custom Docker image (`performancenode/pico-sdk:<version>`) built locally on the Pi. Build acceleration via ccache at `/opt/runner-cache/ccache`, bind-mounted and capped at 2 GB with compression.
- **Docker images:** Pre-pull strategy for 2–3 base images. No local registry — not justified at this scale.
- **Hook wrapper:** Custom `cache-hook.js` wraps the standard `@actions/runner-container-hooks` Docker hook, injecting bind mounts and env vars into every `prepare_job` container spec. `ACTIONS_RUNNER_CONTAINER_HOOKS` systemd env var points to the wrapper.
- **Permissions:** Cache directories use `chmod 1777` (sticky-bit world-writable) to handle UID mismatch between host and container processes.
- **Cache invalidation:** NuGet pruned weekly (files unused >30 days); ccache self-manages via LRU with size cap; Pico SDK image rebuilt on version bumps.

**Delegated to Heero:** Create host directories, implement cache-hook.js wrapper, build Pico SDK Docker image, write pre-pull and cron scripts, update systemd unit.

**Delegated to Wufei:** Measure cache hit rates (NuGet restore time, ccache stats), monitor cache size growth, establish warm-vs-cold baselines for Docker image pulls and NuGet restores, evaluate ccache compression overhead on Cortex-A76.

**Pattern learned:** On a single-purpose runner, prefer the simplest caching mechanism that avoids running additional services. Directory caches + bind mounts beat local package servers. Bake static toolchains into Docker images (versioned, immutable); persist mutable build caches on the host (ccache). The container hooks wrapper is the single integration point for transparent cache injection — keeps workflows clean and caching concerns centralized.

### 2026-04-11: GPIO MCU flash & test architecture designed (0006)

**What was designed:**
- `docs/specs/0006-gpio-mcu-flash-test-action.md` — Full spec for a GitHub Action that flashes firmware to 4 MCUs on a custom HAT via SWD and collects test results over UART
- `docs/hardware/hat-design-contract.md` — Hardware/software interface spec defining the GPIO pin contract, power requirements, and mechanical constraints for the HAT Fortinbra is designing
- `.squad/decisions/inbox/treize-gpio-mcu-architecture.md` — Three key architectural decisions

**Key architectural decisions:**

1. **Container device passthrough via hook wrapper** — Extend the existing `cache-hook-wrapper.js` to inject `--device` flags for `/dev/gpiochip4` and `/dev/ttyAMA*` into job containers. Natural extension of existing infrastructure, no new services or privileged containers.

2. **SWD flashing via GPIO using OpenOCD `linuxgpiod`** — All flashing routes through the 40-pin header. No USB connections needed. 3 GPIO pins per MCU (SWDIO + SWCLK + RESET) × 4 MCUs = 12 pins. Clean HAT design. Rejected BOOTSEL+USB (can't route USB through GPIO header) and picotool (same USB problem).

3. **4 dedicated hardware UARTs** — Pi 5's RP1 provides PL011 UARTs. One per MCU: UART0, UART2, UART3, UART4 via device tree overlays. Deterministic device paths (`/dev/ttyAMA*`), no USB-UART adapters. 115200 8N1 per Wufei's protocol spec.

**GPIO budget:** 24 of 28 pins allocated (8 UART, 12 SWD+RESET, 4 status LEDs). GPIO 0–1 reserved for HAT EEPROM, 2–3 reserved for future I2C1 expansion.

**Pattern learned:** When designing for a Pi HAT, route ALL signals through the 40-pin GPIO header. USB cannot pass through the header, so any approach requiring USB (BOOTSEL flashing, USB-UART adapters) forces external cables or on-HAT USB hubs — both mechanically fragile and ugly. SWD + hardware UARTs keep everything on the PCB.

**Pattern learned:** The container hook wrapper is the single integration point for ALL host-to-container resource injection — caches, devices, environment variables. Adding new resource types (GPIO, UART) is a natural extension, not a new mechanism. This pattern scales well: one wrapper, one configuration surface, one place to audit security.

**Pattern learned:** For hardware interface contracts, define the GPIO pin table FIRST and make it authoritative. The HAT PCB designer and the software team both reference the same table. Include physical-layer details (pull-up values, series resistors, current limits) that software engineers wouldn't normally specify — the hardware engineer needs them and won't find them in code.

**Status:** Spec 0006 is in **📝 Draft** status. Requires GitHub issue creation and review before implementation starts. HAT design contract delivered to Fortinbra. Delegated to Heero (implementation) and Noin (validation).


### 2026-04-13: Archive & Reset - Pivot to Clean Slate

Complete first implementation cycle archived to archive/main-2026-04-13. Main reset to team scaffolding only.

What shipped: OS setup, runner registration, container isolation, caching infrastructure, cache metrics, MCU flash system, SSH hardening, setup orchestrator, example workflows, specs 0001-0006, full team history.

Archival: Created archive/main-2026-04-13 branch (commit de6a291). Reset main: removed docs/specs/, docs/hardware/, docs/qa/, scripts/, examples/, setup.sh. Kept .squad/, .github/, .copilot/, README.md, repo metadata.

Rationale: Fortinbra pivot request. All prior work auditable. Clean foundation for Phase 2. Decisions, specs, and agent learnings accessible via .squad/ and archive branch.

Key insight: Archival as completion practice. Phase 1 established decision framework (spec-driven, squad structure, patterns). Phase 2 builds with different technical approach if needed.

Next: Await Fortinbra's new direction. Treize breaks it into specs for Phase 2.

### 2026-04-14: Ansible-First Architecture Reboot

**Directive from Fortinbra:** Pivot from shell-script-first to Ansible-first automation. Goals: reproducibility, idempotency, extensibility to other network hosts.

**What was proposed:**
- `docs/architecture/ansible-reboot-proposal.md` — comprehensive architecture proposal with repo structure, role breakdown, inventory design
- `.squad/decisions/inbox/treize-ansible-reboot.md` — decision record capturing rationale and implications

**Key architectural choices:**
- **Ansible as primary tool** — Idempotent by design, declarative YAML, inventory-driven targeting
- **Standard layout** — `inventories/`, `playbooks/`, `roles/`, `group_vars/`, `host_vars/`
- **Five core roles for Phase 1:** `common`, `docker`, `github_runner`, `runner_hooks`, `caching`
- **Phase 1 scope: Pi 5 runner only** — MCU/GPIO, performance metrics, multi-host deferred
- **Spec-driven process continues** — Next spec: `0007-ansible-pi-runner-role.md`

**What carries forward from shell-script phase:**
- Container hooks architecture (ACTIONS_RUNNER_CONTAINER_HOOKS)
- Cache bind-mount design (/opt/runner-cache/*)
- Docker daemon config (overlay2, log rotation)
- Cgroup cmdline patch for container memory limits
- SSH hardening (key-based auth)

**What is deferred:**
- MCU/GPIO flash infrastructure (Phase 2+)
- Performance benchmarking suite
- Additional network hosts (NAS, workstations)

**Open questions for Fortinbra:**
1. Bootstrap method for initial SSH access (Pi Imager recommended)
2. Runner token management (Ansible Vault vs runtime env)
3. Ansible Galaxy collections (community.docker?)

**Pattern learned:** When pivoting automation strategy, keep the architectural decisions but change the implementation vehicle. The "what" (container hooks, cache design, SSH hardening) remains valid; only the "how" (shell scripts → Ansible) changes. This preserves months of design work while gaining the benefits of the new tooling.

**Status:** Proposal drafted. Awaiting Fortinbra approval before spec writing begins. Spec gate remains in effect — no implementation without `0007-ansible-pi-runner-role.md` spec and linked GitHub issue.
