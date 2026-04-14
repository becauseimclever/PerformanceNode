# Ansible-First Staged Rollout Plan

**Date:** 2026-04-14  
**Author:** Treize (Lead)  
**Status:** 📝 Draft — Awaiting Approval

---

## Important: WSL/Ubuntu Control Node Requirement

**⚠️ All Ansible playbook execution must happen inside a Ubuntu WSL terminal, not from Windows Command Prompt or PowerShell.**

Before beginning ANY stage implementation, ensure:
1. WSL 2 with Ubuntu 22.04 LTS or later is installed on Windows
2. Ansible is installed in Ubuntu: `sudo apt install ansible openssh-client`
3. Repository is cloned (to Windows or WSL — both work)
4. All playbook commands are run from **inside WSL terminal** only

See [Operator Workflow](ansible-reboot-proposal.md#operator-workflow) in the Ansible Reboot Proposal for detailed setup and typical workflow.

---

## Purpose

Break the Ansible-first Pi runner implementation into **8 small, understandable stages** that can be reviewed and approved incrementally. Each stage has a focused scope, clear acceptance criteria, and explicit approval gate.

**Ground rules:**
1. Each stage requires a spec in `docs/specs/` before implementation
2. Each spec must be linked to a GitHub issue
3. **Nothing is implemented until the stage is explicitly approved**
4. Stages build on each other but are small enough for comfortable review

---

## Stage Overview

| Stage | Name | Scope | Proves |
|-------|------|-------|--------|
| 1 | **Inventory & Bootstrap** | Inventory structure, `ansible.cfg`, connectivity test | Ansible can reach the Pi |
| 2 | **Common Base** | SSH hardening, base packages, locale, sudoers | Secure baseline OS |
| 3 | **Docker Runtime** | Docker CE install, daemon config, cgroups | Container runtime works |
| 4 | **GitHub Runner Core** | Runner download, registration, systemd service | Jobs can be picked up |
| 5 | **Container Hooks** | Node.js, hooks package, hook wrapper scaffolding | Jobs run in containers |
| 6 | **Cache Infrastructure** | Cache directories, bind mounts, hook injection | Caches persist across jobs |
| 7 | **Validation & Smoke Test** | Idempotency test, end-to-end workflow test | Full stack works |
| 8 | **Documentation & Handoff** | README, runbook, troubleshooting guide | User can operate independently |

---

## Stage 1: Inventory & Bootstrap

**Spec:** `0007-inventory-bootstrap.md`  
**Goal:** Establish Ansible connectivity to the Pi.

### Deliverables
- `ansible.cfg` with sensible defaults
- `inventories/production/hosts.yml` with `pi_runners` group
- `inventories/production/group_vars/all.yml` (shared vars)
- `inventories/production/host_vars/pi5-runner.yml` (host-specific)
- Simple `playbooks/ping.yml` that verifies connectivity

### Acceptance Criteria
- [ ] `ansible-playbook playbooks/ping.yml` succeeds
- [ ] Inventory structure follows Ansible best practices
- [ ] Sensitive data placeholders identified (runner token, etc.)

### Proves
Ansible can reach the Pi over SSH. Foundation for all subsequent stages.

### Dependencies
- Requires: Fresh Pi with SSH enabled (manual or via Pi Imager)
- Enables: All subsequent stages

---

## Stage 2: Common Base

**Spec:** `0008-common-role.md`  
**Goal:** Secure the OS baseline.

### Deliverables
- `roles/common/` with tasks for:
  - SSH hardening (key-based auth, disable password)
  - Base packages (curl, git, jq, htop, etc.)
  - Locale & timezone
  - Sudoers configuration
  - Runner user creation (`actions-runner`)

### Acceptance Criteria
- [ ] SSH password auth disabled after role runs
- [ ] Runner user exists with correct groups
- [ ] Role is idempotent (second run changes nothing)

### Proves
Baseline OS security and user setup complete.

### Dependencies
- Requires: Stage 1 (connectivity)
- Enables: Stage 3 (Docker needs runner user)

---

## Stage 3: Docker Runtime

**Spec:** `0009-docker-role.md`  
**Goal:** Install and configure Docker for containerized job execution.

### Deliverables
- `roles/docker/` with tasks for:
  - Docker CE installation (ARM64, official repo)
  - `/etc/docker/daemon.json` (overlay2, log rotation)
  - Cgroup memory enablement in `/boot/firmware/cmdline.txt`
  - Add `actions-runner` user to `docker` group

### Acceptance Criteria
- [ ] `docker run hello-world` succeeds as `actions-runner` user
- [ ] Daemon config matches spec (log rotation, storage driver)
- [ ] Cgroup memory enabled (reboot required flag surfaced)
- [ ] Role is idempotent

### Proves
Container runtime ready for GitHub Actions.

### Dependencies
- Requires: Stage 2 (`actions-runner` user must exist)
- Enables: Stage 4 (runner needs Docker for hook execution)

---

## Stage 4: GitHub Runner Core

**Spec:** `0010-github-runner-role.md`  
**Goal:** Install and register the GitHub Actions runner.

### Deliverables
- `roles/github_runner/` with tasks for:
  - Download runner tarball (ARM64)
  - Unpack to `/opt/actions-runner/`
  - Configure with organization/repo URL and token
  - Create systemd service unit
  - Enable and start service

### Acceptance Criteria
- [ ] Runner appears in GitHub org/repo settings as online
- [ ] Service survives reboot
- [ ] Token is handled securely (Ansible Vault or runtime var)
- [ ] Role is idempotent (re-register handled gracefully)

### Proves
Runner can receive jobs from GitHub.

### Dependencies
- Requires: Stage 3 (Docker available)
- Enables: Stage 5 (hooks extend runner behavior)

---

## Stage 5: Container Hooks

**Spec:** `0011-runner-hooks-role.md`  
**Goal:** Run all jobs inside disposable containers.

### Deliverables
- `roles/runner_hooks/` with tasks for:
  - Install Node.js LTS (ARM64)
  - Install `@actions/runner-container-hooks` package
  - Create hook wrapper scaffolding at `/opt/runner-hooks/`
  - Set `ACTIONS_RUNNER_CONTAINER_HOOKS` env var in systemd unit
  - Restart runner service

### Acceptance Criteria
- [ ] Test job runs inside container (verify via `uname` or container ID)
- [ ] Job does NOT have direct host access
- [ ] Hook wrapper installed and referenced correctly
- [ ] Role is idempotent

### Proves
Container isolation enforced at runner level.

### Dependencies
- Requires: Stage 4 (runner must be running)
- Enables: Stage 6 (hooks wrapper will inject cache mounts)

---

## Stage 6: Cache Infrastructure

**Spec:** `0012-caching-role.md`  
**Goal:** Persistent caches available to containerized jobs.

### Deliverables
- `roles/caching/` with tasks for:
  - Create `/opt/runner-cache/{nuget,ccache,pico-sdk}` directories
  - Set permissions (sticky bit for UID-safe access)
  - Extend hook wrapper to inject bind mounts
  - Inject `NUGET_PACKAGES`, `CCACHE_DIR` env vars
  - Create cleanup cron job (weekly NuGet prune)

### Acceptance Criteria
- [ ] Cache directories exist with correct permissions
- [ ] Test job can write to and read from cache mount
- [ ] Env vars visible inside container
- [ ] Role is idempotent

### Proves
Build caches persist across job runs and are transparent to workflows.

### Dependencies
- Requires: Stage 5 (hook wrapper must exist)
- Enables: Stage 7 (full stack ready for validation)

---

## Stage 7: Validation & Smoke Test

**Spec:** `0013-validation.md`  
**Goal:** Prove the entire stack works end-to-end.

### Deliverables
- Ansible playbook `playbooks/validate.yml` that:
  - Runs all roles with `--check` mode (dry-run idempotency)
  - Triggers a real GitHub Actions workflow
  - Verifies job completed in container with cache access
- Test workflow in `.github/workflows/smoke-test.yml`

### Acceptance Criteria
- [ ] `ansible-playbook --check` reports no changes on configured Pi
- [ ] Smoke test workflow completes successfully
- [ ] Workflow logs confirm container execution
- [ ] Cache hit observed on second run (NuGet or ccache)

### Proves
Full Ansible-managed Pi runner stack operational.

### Dependencies
- Requires: Stages 1–6 complete
- Enables: Stage 8 (documentation)

---

## Stage 8: Documentation & Handoff

**Spec:** `0014-documentation.md`  
**Goal:** User can operate the runner independently.

### Deliverables
- Updated `README.md` with quick-start instructions
- `docs/runbook.md` covering:
  - First-time setup from fresh Pi
  - Re-running playbook (idempotent update)
  - Troubleshooting common issues
  - Token rotation procedure
- `docs/architecture/ansible-structure.md` explaining repo layout

### Acceptance Criteria
- [ ] New user can follow README and get runner online
- [ ] Runbook covers at least 5 common operations
- [ ] Architecture doc explains each role's purpose

### Proves
Project is self-documenting and maintainable.

### Dependencies
- Requires: Stages 1–7 complete
- Enables: MCU/GPIO Phase 2 (future)

---

## Approval Process

For each stage:

1. **Treize drafts spec** → `docs/specs/{NNNN}-{slug}.md`
2. **Fortinbra reviews** → Comments or approves
3. **GitHub issue created** → Links to spec
4. **Explicit approval given** → "Approved for implementation"
5. **Heero implements** → PR references issue
6. **Noin validates** → Acceptance criteria checked
7. **Treize reviews** → Merge or request changes
8. **Stage marked complete** → Move to next stage

**⚠️ Gate:** No stage begins implementation until explicitly approved.

---

## First Three Stages (Immediate Focus)

| Order | Stage | Spec | First Deliverable |
|-------|-------|------|-------------------|
| 1 | Inventory & Bootstrap | `0007-inventory-bootstrap.md` | `ansible.cfg` + inventory |
| 2 | Common Base | `0008-common-role.md` | `roles/common/` |
| 3 | Docker Runtime | `0009-docker-role.md` | `roles/docker/` |

These three stages establish connectivity, OS baseline, and container runtime — the minimum for any subsequent work.

---

## Timeline Estimate

| Stage | Estimated Effort | Cumulative |
|-------|------------------|------------|
| 1 | 1 hour | 1 hour |
| 2 | 2 hours | 3 hours |
| 3 | 2 hours | 5 hours |
| 4 | 2 hours | 7 hours |
| 5 | 2 hours | 9 hours |
| 6 | 2 hours | 11 hours |
| 7 | 1 hour | 12 hours |
| 8 | 2 hours | 14 hours |

**Total: ~14 hours** of implementation across all stages, spread over multiple approval cycles.

---

## References

- [Ansible Reboot Proposal](ansible-reboot-proposal.md)
- [Team Decisions](../../.squad/decisions.md)
- Archive: `archive/main-2026-04-13` (prior shell-script implementation)
