# Ansible-First Architecture Proposal

**Date:** 2026-04-14  
**Author:** Treize (Lead)  
**Status:** 📝 Draft — Pending Review  
**Request:** Fortinbra

---

## Executive Summary

Reframe PerformanceNode as an **Ansible-first automation repository** instead of raw shell scripts. The first scope covers only the Raspberry Pi 5 self-hosted GitHub Actions runner; the structure is designed to extend to other systems on the network in future phases.

**Why Ansible:**
- **Idempotent by design** — Ansible modules naturally handle "already done" cases
- **Declarative & auditable** — YAML playbooks are easier to review than procedural shell scripts
- **Inventory-driven** — Easy to target one Pi now, add more hosts later
- **Role-based composition** — Encapsulate concerns (Docker, runner, caching) into reusable roles
- **Extensibility** — Add network switches, NAS, workstations to inventory without restructuring

---

## Proposed Repository Structure

```
PerformanceNode/
├── ansible.cfg                 # Ansible configuration (inventory path, roles path, etc.)
├── requirements.yml            # Ansible Galaxy collections/roles if needed
│
├── inventories/
│   ├── production/
│   │   ├── hosts.yml           # Production inventory (Pi runner, future hosts)
│   │   ├── group_vars/
│   │   │   ├── all.yml         # Vars applying to all hosts
│   │   │   └── pi_runners.yml  # Vars for Pi runner group
│   │   └── host_vars/
│   │       └── pi5-runner.yml  # Host-specific overrides for the Pi 5
│   └── development/            # (Future) local VM or test inventory
│       └── ...
│
├── playbooks/
│   ├── site.yml                # Master playbook (imports all roles for full setup)
│   ├── pi-runner.yml           # Pi 5 runner setup (first scope)
│   └── (future: nas.yml, workstation.yml, etc.)
│
├── roles/
│   ├── common/                 # Base OS hardening, SSH, packages shared by all hosts
│   │   ├── tasks/
│   │   ├── handlers/
│   │   ├── defaults/
│   │   └── templates/
│   ├── docker/                 # Docker Engine install, daemon config, cgroups
│   ├── github_runner/          # Runner download, registration, systemd service
│   ├── runner_hooks/           # Container hooks setup, cache-hook wrapper
│   ├── caching/                # NuGet, ccache, Pico SDK cache directories
│   └── mcu_flash/              # GPIO/SWD flash infrastructure (future phase)
│
├── docs/
│   ├── architecture/           # This proposal, ADRs, diagrams
│   ├── specs/                  # Feature specifications (per spec-driven process)
│   └── hardware/               # HAT contracts, pin tables (if MCU scope resumes)
│
├── .squad/                     # Team structure, decisions, agent histories
├── .github/                    # CI workflows, issue templates
├── .copilot/                   # Copilot CLI configuration
└── README.md                   # Project overview, quick start
```

---

## Role Breakdown (Pi 5 Runner Scope)

| Role | Responsibility | Key Tasks |
|------|----------------|-----------|
| **common** | Baseline OS config | SSH hardening (key-based auth), base packages, locale/timezone, sudoers |
| **docker** | Container runtime | Install Docker CE (ARM64), daemon.json (overlay2, log rotation), cgroup cmdline patch |
| **github_runner** | Runner registration | Download runner, configure, register with GitHub (PAT or app token), systemd service |
| **runner_hooks** | Container isolation | Install Node.js, `@actions/runner-container-hooks`, cache-hook wrapper, env vars |
| **caching** | Build acceleration | Create cache dirs (`/opt/runner-cache/*`), permissions, cron cleanup |

---

## Inventory Design

**Phase 1 (now):** Single Pi 5 runner
```yaml
# inventories/production/hosts.yml
all:
  children:
    pi_runners:
      hosts:
        pi5-runner:
          ansible_host: 192.168.x.x  # Or hostname
          ansible_user: pi           # Initial user; Ansible creates runner user
```

**Phase 2+ (future):** Extend to other hosts
```yaml
all:
  children:
    pi_runners:
      hosts:
        pi5-runner: ...
        pi5-runner-2: ...  # Second Pi
    nas:
      hosts:
        truenas: ...
    workstations:
      hosts:
        devbox: ...
```

---

## Configuration Layering

| Layer | Path | Example |
|-------|------|---------|
| Role defaults | `roles/*/defaults/main.yml` | `docker_version: "24.0"` |
| Group vars | `inventories/production/group_vars/pi_runners.yml` | `runner_labels: [self-hosted, ARM64, pi5]` |
| Host vars | `inventories/production/host_vars/pi5-runner.yml` | `github_runner_token: "{{ vault_runner_token }}"` |

Secrets managed via **Ansible Vault** (encrypted `host_vars` or separate `vault.yml`).

---

## Playbook Execution Model

```bash
# Full Pi 5 runner setup (first run)
ansible-playbook -i inventories/production playbooks/pi-runner.yml --ask-vault-pass

# Re-run (idempotent — skips completed tasks)
ansible-playbook -i inventories/production playbooks/pi-runner.yml

# Target only Docker role
ansible-playbook -i inventories/production playbooks/pi-runner.yml --tags docker

# Limit to single host (future)
ansible-playbook -i inventories/production playbooks/site.yml --limit pi5-runner
```

---

## What Carries Forward from Shell-Script Phase

| Concept | Disposition |
|---------|-------------|
| Container hooks architecture | ✅ Keep — implement in `runner_hooks` role |
| Cache bind-mount design | ✅ Keep — implement in `caching` role |
| Docker daemon config | ✅ Keep — implement in `docker` role |
| `/boot/firmware/cmdline.txt` cgroup patch | ✅ Keep — task in `docker` role |
| SSH hardening | ✅ Keep — implement in `common` role |
| MCU/GPIO flash infrastructure | ⏸️ Defer — `mcu_flash` role, out of Phase 1 scope |
| Performance metrics scripts | ⏸️ Defer — may become separate tooling or role |
| Example workflows | ⏸️ Defer — restore from archive when runner is working |

---

## Spec-Driven Process Continues

The **spec gate** remains in effect:
1. Each feature/role requires a spec in `docs/specs/` before implementation
2. Each spec links to a GitHub issue
3. Spec Review ceremony before implementation begins

**Proposed first spec:** `0007-ansible-pi-runner-role.md` — covering the core `pi-runner.yml` playbook and its dependent roles.

---

## Out of Scope for Phase 1

- Multi-Pi clustering or load balancing
- Non-Pi hosts (NAS, workstations) — structure supports them, implementation deferred
- MCU/GPIO flash infrastructure — deferred to Phase 2+
- Performance benchmarking suite — deferred; focus on working runner first
- Cloud/remote deployment — headless physical Pi only

---

## Open Questions

1. **Bootstrap SSH:** Ansible requires SSH access. How is the Pi's initial SSH key installed?
   - Option A: Raspberry Pi Imager pre-configures SSH + authorized_keys (recommended)
   - Option B: First-boot script via cloud-init/user-data on SD card
   - Option C: Manual one-time setup (acceptable for single Pi)

2. **Runner registration token:** How is the GitHub PAT or registration token provided?
   - Option A: Ansible Vault encrypted var
   - Option B: Environment variable passed at runtime
   - Option C: GitHub App token (more complex, better for org-scale)

3. **Collections:** Do we need any Ansible Galaxy collections?
   - `community.docker` for Docker module improvements?
   - `community.general` for misc modules?
   - Or rely on builtin modules only?

---

## Next Steps

1. **Approve this proposal** — Fortinbra + team review
2. **Write spec `0007-ansible-pi-runner-role.md`** — defines acceptance criteria for Phase 1
3. **Create GitHub issue** linking spec
4. **Heero implements** — roles and playbook
5. **Noin validates** — idempotency tests, fresh Pi smoke test

---

## References

- Archive branch: `archive/main-2026-04-13` — prior shell-script implementation
- Team decisions: `.squad/decisions.md`
- Spec template: (to be restored from archive or recreated)
