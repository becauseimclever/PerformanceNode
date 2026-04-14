# PerformanceNode

**Status:** ✅ Stage 1 complete — Inventory & Bootstrap is validated for the first Pi target.

An **Ansible-based automation framework** for setting up Raspberry Pi 5 as a self-hosted GitHub Actions runner for local performance testing. Designed for reproducibility, idempotency, and extensibility to other network hosts.

## Staged Rollout

Implementation is broken into **8 small stages** for incremental review and approval:

| Stage | Name | Status |
|-------|------|--------|
| 1 | [Inventory & Bootstrap](docs/specs/2-inventory-bootstrap.md) | ✅ Complete |
| 2 | [Common Base](docs/specs/3-common-role.md) | 📝 Draft |
| 3 | [Docker Runtime](docs/specs/4-docker-role.md) | 📝 Draft |
| 4 | GitHub Runner Core | Pending |
| 5 | Container Hooks | Pending |
| 6 | Cache Infrastructure | Pending |
| 7 | Validation | Pending |
| 8 | Documentation | Pending |

**Process:** Each stage requires spec approval → GitHub issue → implementation → validation.

⚠️ **Important:** All Ansible playbook execution must happen inside a Ubuntu WSL terminal, not from Windows. See [`docs/architecture/ansible-reboot-proposal.md`](docs/architecture/ansible-reboot-proposal.md#operator-workflow) for setup instructions.

If the repository is opened from `/mnt/c/...` in WSL, run commands with `ANSIBLE_CONFIG=$PWD/ansible.cfg` so Ansible uses the repo-local configuration file.

See [`docs/architecture/staged-rollout.md`](docs/architecture/staged-rollout.md) for the full plan.

## Architecture

**Phase 1 scope:** Raspberry Pi 5 runner setup only.

```
inventories/          # Production/development host inventories
playbooks/            # Ansible playbooks (pi-runner.yml, site.yml)
roles/                # Reusable roles (common, docker, github_runner, runner_hooks, caching)
docs/architecture/    # Architecture proposals and decisions
docs/specs/           # Feature specifications (spec-driven development)
```

See [`docs/architecture/ansible-reboot-proposal.md`](docs/architecture/ansible-reboot-proposal.md) for the full architecture proposal.

## Team

This project uses the **Squad AI team framework**:

| Agent | Role |
|-------|------|
| **Treize** | Lead — architecture, decisions, reviews |
| **Heero** | Infrastructure — Ansible roles, Pi setup |
| **Wufei** | Performance — metrics, benchmarking (Phase 2) |
| **Noin** | QA — validation, idempotency tests |

Team structure, decisions, and history: [`.squad/`](.squad/)

## Status

- **Prior shell-script implementation:** Archived at `archive/main-2026-04-13`
- **Current:** Stage 1 inventory and bootstrap validation are complete for `PiTester` (`192.168.27.222`) over SSH as `fortinbra`
- **Next:** Stage 2 can begin after approval

## Quick Links

- [Architecture Proposal](docs/architecture/ansible-reboot-proposal.md)
- [Decision Record](/.squad/decisions/inbox/treize-ansible-reboot.md)
- [Team Decisions](/.squad/decisions.md)
