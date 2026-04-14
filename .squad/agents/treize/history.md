# Project Context

- **Project:** PerformanceNode
- **What:** Bash/shell setup scripts for a Raspberry Pi 5 running as a GitHub Actions self-hosted performance runner. Starting from a fresh Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm) install.
- **Owner:** Fortinbra
- **Team:** Treize (Lead), Heero (Infrastructure Dev), Wufei (Performance Engineer), Noin (Tester/QA)

## Core Context

Treize initialized as Lead on 2026-04-10. Phase 1 (shell-script implementation) completed and archived to `archive/main-2026-04-13`. Phase 2 (Ansible-first reboot) proposal drafted 2026-04-14.

**Architectural Decisions Locked (Carry Forward to Phase 2):**
1. **Container isolation:** All GitHub Actions jobs execute inside disposable Docker containers via `ACTIONS_RUNNER_CONTAINER_HOOKS` (not opt-in, not privileged, not DIND).
2. **Spec-driven development:** Every feature requires a spec in `docs/specs/` + GitHub issue before implementation. Spec Review ceremony as before-implementation gate.
3. **Dependency caching:** Host-side `/opt/runner-cache/*` (NuGet, ccache) bind-mounted into containers via custom hook wrapper. No local package services.
4. **GPIO/MCU architecture:** SWD flashing via OpenOCD linuxgpiod (3 GPIO pins per MCU). Single UART from harness MCU aggregating results from 3 DUT MCUs. Container hook wrapper device injection for `/dev/gpiochip4` and `/dev/ttyAMA*`.
5. **SSH hardening:** Key-based auth only, password disabled.
6. **User directives:**
   - No implementation without written feature spec (established 2026-04-10; reinforced 2026-04-14)
   - No spec implementation without explicit user approval (established 2026-04-14)
   - Ansible-first reboot proposal awaiting approval (2026-04-14)

**Phase 1 Deliverables (Archived):**
- Specs 0001–0006 with acceptance criteria
- HAT design contract with GPIO pin table
- Full setup scripts (system, Docker, runner, cache, SSH)
- Example workflows (.NET 10, MCU test)
- Cache benchmarking suite
- MCU flash action with SWD via GPIO
- Agent histories and decision records

**Phase 2 Status (Current):**
- Ansible-first proposal drafted (`docs/architecture/ansible-reboot-proposal.md`)
- Five core roles planned: `common`, `docker`, `github_runner`, `runner_hooks`, `caching`
- Scope: Pi 5 runner only; MCU/GPIO, metrics deferred
- Next: Fortinbra approval → Treize writes spec `0007-ansible-pi-runner-role.md` → Heero implements

**Patterns Established:**
- Retroactive specs force clarity on acceptance criteria and catch assumptions early
- Container hook wrapper is the single integration point for all host-to-container injection (caches, devices, env)
- Hardware interface contracts define pin tables first; all agents reference same authoritative source
- Archive + reset as completion practice: Phase 1 done, auditable, clean foundation for Phase 2

## Learnings

_Recent learnings consolidated in Core Context above. Full history of per-session decisions at end._

---

## Phase 1 Work History (2026-04-10 to 2026-04-13)

### 2026-04-10: Three new feature specs written (0003, 0004, 0005)

SSH key setup, single entry-point orchestrator, C# example workflow specs drafted. All require GitHub issues before implementation.

### 2026-04-10: Container execution architecture decision

All jobs in Docker containers via `ACTIONS_RUNNER_CONTAINER_HOOKS`. Persistent runner, disposable containers. Docker 24.x ARM64, Node.js for hooks, cgroup memory limits patched into `/boot/firmware/cmdline.txt`.

### 2026-04-10: Spec-driven development process adopted

Directive from Fortinbra: all features need spec + GitHub issue. Spec Review ceremony added to `.squad/ceremonies.md` as before-implementation gate. Retroactive specs for in-progress work (0001, 0002).

### 2026-04-10: Dependency caching architecture

Host `/opt/runner-cache/` (NuGet, ccache) bind-mounted into containers via custom hook wrapper. No local servers. NuGet weekly cleanup (>30 days atime). Pico SDK toolchain baked into Docker image. ccache LRU with 2 GB cap.

### 2026-04-10: Dependency caching strategy (Wufei)

NuGet: cold 8–15 min → warm 30–90 sec (7–14 min savings, 200–800 MB network). Pico SDK: cold 12–20 min → warm 20–60 sec (11–19 min savings, ~820 MB network).

### 2026-04-10: Cache metrics benchmark suite (Wufei)

Five scripts measuring cache effectiveness (NuGet, Pico SDK, Docker). Timing via `date +%s%3N`, network delta from `/proc/net/dev`, per-tool error handling (JSON output, exit 0).

### 2026-04-10: MCU topology — harness RP2040, three DUTs (Fortinbra)

1 harness RP2040 (coordinator, UART to Pi) + 3 DUT MCUs (RP2040, RP2350B, RP2350A). All 4 MCUs flashed via SWD from Pi GPIO. Harness aggregates results over inter-MCU link.

### 2026-04-10: No host USB to MCUs (Fortinbra)

All MCU flashing through GPIO (SWD + OpenOCD linuxgpiod). No BOOTSEL, no picotool, no USB routing.

### 2026-04-10: Single UART — harness only (Fortinbra)

One UART from harness RP2040 to Pi (e.g., `/dev/ttyAMA2`). DUT MCUs don't connect to Pi directly; communicate with harness via on-HAT wiring.

### 2026-04-10: UART Protocol Design (Wufei)

Line-based ASCII text (115200 8N1, LF-only). Free-text fields colon-prefixed at end. METRIC separate from PASS/FAIL. Timeout detection parser-side (per-MCU watchdog). Two modes: normal (LOG allowed), strict (LOG rejected).

### 2026-04-11: GPIO MCU flash & test architecture (Treize)

Three decisions: (1) Container device passthrough via hook wrapper. (2) SWD flashing via GPIO+OpenOCD (3 pins per MCU × 4 = 12 pins). (3) Single UART from harness. GPIO budget: 24 of 28 pins (12 SWD+RESET, 2 UART, 4 LEDs).

### 2026-04-11: GPIO architecture finalized (Treize)

User confirmed: SWD/OpenOCD, no host USB, single UART, harness MCU topology, 14 GPIO min. Docs updated: `hat-design-contract.md` v2.0, `specs/0006-gpio-mcu-flash-test-action.md`, `.squad/decisions/inbox/treize-gpio-arch-final.md`.

### 2026-04-11: UART Protocol Updated for Single-Stream Topology (Wufei)

All result messages now require `mcu=<id>` field to identify source DUT in aggregated stream. Parser maintains per-DUT state, routes by `mcu` field. Breaking change from 4-UART protocol.

### 2026-04-13: Clean-State Validation Decision (Heero)

Support stable `actions-runner` compatibility service name. Real runner unit is registration-dependent; cache scripts sync drop-ins to detected unit and create alias.

### 2026-04-13: Noin QA Refresh — LF line ending enforcement

Add `.gitattributes` to enforce LF endings on `*.sh`, `*.py`, `*.yml`, `*.yaml`, `*.md`. Required for Bash parsing on Pi OS.

### 2026-04-13: Archive Previous Implementation & Reset Main to Clean Slate

Created `archive/main-2026-04-13` (commit de6a291) with full Phase 1 implementation. Reset main to team scaffolding only. Kept `.squad/`, `.github/`, README, repo metadata. Removed `docs/specs/`, `docs/hardware/`, `scripts/`, `examples/`, `setup.sh`.

---

## Phase 2 Work History (Current)

### 2026-04-14: Ansible-First Architecture Reboot

**Directive from Fortinbra (2026-04-14T00:38:15Z):** Reboot as Ansible playbook/workbook for reproducibility, idempotency, extensibility to additional network hosts.

**Directive from Fortinbra (2026-04-14T00:40:07Z):** Follow spec-driven pattern. Do not implement without feature spec written first. Do not implement spec without explicit user approval.

**Proposal drafted:**
- `docs/architecture/ansible-reboot-proposal.md` — full architecture with repo structure, role breakdown, inventory design
- `.squad/decisions/inbox/treize-ansible-reboot.md` — decision record

**Key choices:**
- Ansible as primary tool (idempotent, declarative, inventory-driven)
- Standard repo layout: `inventories/{production,development}/`, `playbooks/`, `roles/`, `group_vars/`, `host_vars/`
- Five core roles for Phase 1: `common`, `docker`, `github_runner`, `runner_hooks`, `caching`
- Phase 1 scope: Pi 5 runner only (base OS, Docker, runner registration, hooks, caching)
- Phase 2+ deferred: MCU/GPIO, performance metrics, multi-host networking
- Spec-driven process continues: next spec `0007-ansible-pi-runner-role.md`

**Decisions carried forward:**
- Container hooks architecture (`ACTIONS_RUNNER_CONTAINER_HOOKS`)
- Cache bind-mount design (`/opt/runner-cache/*`)
- Docker daemon config (overlay2, log rotation)
- Cgroup cmdline patch for memory limits
- SSH hardening (key-based auth)

**Open questions for Fortinbra:**
1. Bootstrap method (Raspberry Pi Imager recommended, cloud-init, manual)
2. Runner token management (Ansible Vault, runtime env, GitHub App)
3. Ansible Galaxy collections (community.docker or builtins)

**Status:** Proposal awaiting Fortinbra approval. Spec gate remains: no implementation without `0007-ansible-pi-runner-role.md` spec + GitHub issue.

**Pattern reinforced:** When pivoting automation strategy, keep architectural decisions but change implementation vehicle. The "what" (container hooks, caching, SSH) remains valid; only "how" (shell → Ansible) changes. Preserves design work while gaining benefits of new tooling.

### 2026-04-14: Staged Rollout Plan Created

**Directive from Fortinbra:** "Split implementation into small understandable chunks for incremental approval."

**What was created:**
- `docs/architecture/staged-rollout.md` — Master plan defining 8 stages with dependencies and rationale
- `docs/specs/TEMPLATE.md` — Spec template for staged specs
- `docs/specs/0007-inventory-bootstrap.md` — Stage 1 spec (Ansible connectivity)
- `docs/specs/0008-common-role.md` — Stage 2 spec (SSH, packages, runner user)
- `docs/specs/0009-docker-role.md` — Stage 3 spec (Docker CE installation)
- `.squad/decisions/inbox/treize-staged-rollout.md` — Decision record for the staged approach
- Updated `README.md` to show staged rollout status

**Eight stages defined:**

| Stage | Name | Key Deliverable |
|-------|------|-----------------|
| 1 | Inventory & Bootstrap | `ansible.cfg`, inventory, connectivity |
| 2 | Common Base | `roles/common/` — SSH, packages, user |
| 3 | Docker Runtime | `roles/docker/` — Docker CE, config |
| 4 | GitHub Runner Core | `roles/github_runner/` — registration |
| 5 | Container Hooks | `roles/runner_hooks/` — isolation |
| 6 | Cache Infrastructure | `roles/caching/` — bind mounts |
| 7 | Validation | Idempotency + smoke test |
| 8 | Documentation | README, runbook |

**Key design decisions:**
- Each stage ~1–2 hours of implementation work
- Clear dependency chain (no circular dependencies)
- Explicit approval gate before each stage begins
- Spec + GitHub issue required per stage
- First 3 stages establish foundation (connectivity, OS baseline, container runtime)

**Pattern learned:** When users want to follow along with implementation, break work into stages that each produce visible, verifiable output. Stages should be small enough to review in one sitting (~2 hours max). The approval gate between stages builds trust incrementally and catches misalignment early.

**Pattern learned:** Stage boundaries should align with "what does this prove" milestones:
- Stage 1 proves: Ansible can reach the Pi
- Stage 2 proves: OS is secure and ready
- Stage 3 proves: Containers can run
- Stage 4 proves: Jobs can be picked up
- Stage 5 proves: Jobs are isolated
- Stage 6 proves: Caches work
- Stage 7 proves: Full stack operational
- Stage 8 proves: User can operate independently

Each stage unlocks a capability that the next stage builds on. This creates natural checkpoints where the user can assess progress and decide whether to continue.

**Status:** Staged rollout plan created. Specs 0007–0009 drafted. All stages awaiting Fortinbra approval before implementation begins.

### 2026-04-14: WSL/Ubuntu Control Node Requirement Documented

**Directive from Fortinbra:** "Ansible does not run well from Windows, so we will need to use the WSL instance running Ubuntu as the control."

**Response:**
- Updated `docs/architecture/ansible-reboot-proposal.md` with "Operator Workflow" section explaining:
  - WSL 2 + Ubuntu 22.04 LTS requirement
  - Typical setup (one-time `apt install ansible`)
  - Command flow (navigate repo path in WSL, run playbooks from WSL terminal)
  - Why: File permissions, SSH key strictness, module behavior all require POSIX environment

- Updated `docs/architecture/staged-rollout.md` with:
  - Prominent ⚠️ warning at top: "All Ansible playbook execution must happen inside Ubuntu WSL terminal"
  - Link to operator workflow for detailed setup
  - Note that this requirement affects all 8 stages

- Updated `README.md` staged rollout section:
  - Added reminder about WSL requirement
  - Link to ansible-reboot-proposal.md#operator-workflow

- Created decision record at `.squad/decisions/inbox/treize-wsl-control.md`:
  - Problem statement, decision, rationale (5 points)
  - Implications for operators, docs, and implementation
  - Alternatives considered and rejected
  - Status: Firm constraint, not preference

**Key learning:** When infrastructure constraints emerge (like "Ansible needs Unix control node"), document them at the architecture level, not just in runbooks. Propagate the constraint through all related docs (proposals, rollout, README) so operators encounter the requirement consistently. Decision record captures why the constraint exists (for future agents' context).

### 2026-04-14: Stage 2 Spec Gate Review and Approval

**Spec:** `docs/specs/3-common-role.md` (Common Base Role)

**Gate criteria reviewed:**
1. ✅ Template completeness: All 9 sections present
2. ✅ Acceptance criteria testability: 7 specific, measurable criteria; no vague language
3. ✅ Agent assignment: Heero (Implement), Treize (Review), Noin (Validate)
4. ✅ GitHub issue: #3 linked and verified open

**DECISION: APPROVED** for implementation. Spec status updated from "📝 Draft" to "✅ Approved".

**Key spec strengths:**
- SSH key pre-flight check (lines 161–166) prevents common lockout mistake
- Idempotency explicitly tested (Criterion 6: `changed=0` on rerun)
- Clear dependencies: requires Stage 1, enables Stage 3
- Out of Scope prevents creep (Docker, runner, firewall deferred)

**Pattern reinforced:** Pre-flight checks documented in spec Notes (not just acceptance criteria) are valuable safeguards. Future specs should include "gotchas that could cause failure" even if they can't be unit-tested. Idempotency should always be an explicit acceptance criterion for infrastructure specs.

**Status:** Decision record created at `.squad/decisions/inbox/treize-stage2-approval.md`. Ready for Heero to begin implementation. Treize will review PRs; Noin will validate.
