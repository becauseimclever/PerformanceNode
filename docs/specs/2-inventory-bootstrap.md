# Spec: Ansible Inventory & Bootstrap

**Spec ID:** `2-inventory-bootstrap`  
**Stage:** 1 of 8  
**Status:** ✅ Approved  
**Author:** Treize (Lead)  
**GitHub Issue:** [#2](https://github.com/becauseimclever/PerformanceNode/issues/2)

---

## Overview

Establish the Ansible inventory structure and verify basic connectivity to the Raspberry Pi 5. This is the foundation for all subsequent Ansible automation.

## Problem

Before any Ansible automation can run, we need:
1. A working `ansible.cfg` with sensible defaults
2. An inventory that describes our Pi 5 target
3. Verified SSH connectivity from the control machine to the Pi
4. A structure that can scale to multiple hosts later (even though we start with one)

## Solution

Create the standard Ansible inventory layout with production/development separation, group and host variables, and a simple ping playbook to verify connectivity.

### Files to Create

```
ansible.cfg                           # Ansible configuration
inventories/
  production/
    hosts.yml                         # Host inventory (pi_runners group)
    group_vars/
      all.yml                         # Variables for all hosts
      pi_runners.yml                  # Variables for pi_runners group
    host_vars/
      pi5-runner.yml                  # Host-specific variables
playbooks/
  ping.yml                            # Connectivity test playbook
```

### Key Configuration

**ansible.cfg:**
- Inventory path: `inventories/production`
- Roles path: `roles`
- Host key checking: strict by default after first SSH trust is established from WSL
- Retry files disabled (no clutter)

**hosts.yml:**
```yaml
all:
  children:
    pi_runners:
      hosts:
        pi5-runner:
          ansible_host: "{{ pi5_ip }}"
          ansible_user: "{{ pi5_ssh_user }}"
```

**group_vars/pi_runners.yml:**
```yaml
runner_user: actions-runner
runner_home: /opt/actions-runner
cache_base: /opt/runner-cache
```

## Acceptance Criteria

- [x] `ansible.cfg` exists with documented configuration
- [x] Inventory follows standard Ansible layout (`inventories/{env}/hosts.yml`)
- [x] `group_vars/` and `host_vars/` directories established
- [ ] `ansible-playbook playbooks/ping.yml -i inventories/production` succeeds
- [x] Sensitive value placeholders documented (IP, token locations)
- [x] Second run produces identical results (idempotent by nature)

## Out of Scope

- Creating the `actions-runner` user (Stage 2)
- Installing any packages on the Pi (Stage 2+)
- Docker, runner, or hooks setup (Stages 3–6)
- Development inventory population (future)

## Dependencies

- **Requires:**
  - Fresh Raspberry Pi 5 with:
    - Raspberry Pi OS Lite (64-bit, Bookworm) installed
    - SSH enabled
    - Network connectivity
    - Known IP address or hostname
  - SSH key access configured for the control node

- **Enables:**
  - Stage 2: Common base role (SSH hardening, user creation)
  - All subsequent stages (they all use this inventory)

## Agent Assignment

| Role | Agent |
|------|-------|
| Implement | Heero |
| Review | Treize |
| Validate | Noin |

## Verification

```bash
# From Ubuntu WSL
cd /mnt/c/ws/PerformanceNode

# Test connectivity
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook -i inventories/production playbooks/ping.yml
```

## Notes

### Bootstrap SSH Access

This stage assumes SSH is already configured on the Pi. For the current target:
- Inventory alias: `pi5-runner`
- Pi hostname: `PiTester`
- SSH host: `192.168.27.222`
- SSH user: `fortinbra`

### WSL Path Note

If the repository is stored on the Windows filesystem and accessed from WSL via `/mnt/c/...`, run Ansible with `ANSIBLE_CONFIG=$PWD/ansible.cfg` so Ansible uses the repo-local configuration explicitly.

### Secrets Strategy

The runner registration token will be needed in Stage 4. This stage only establishes the pattern:
- Sensitive values marked with comments: `# Set via --extra-vars or vault`
- Actual vault setup deferred until needed
