# Spec: Ansible Inventory & Bootstrap

**Spec ID:** `0007-inventory-bootstrap`  
**Stage:** 1 of 8  
**Status:** 📝 Draft — Awaiting Approval  
**Author:** Treize (Lead)  
**GitHub Issue:** _Not yet created_

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
- Host key checking: warn (first run) → strict (production)
- Retry files disabled (no clutter)

**hosts.yml:**
```yaml
all:
  children:
    pi_runners:
      hosts:
        pi5-runner:
          ansible_host: "{{ pi5_ip }}"    # Set in host_vars
          ansible_user: pi                 # Default Pi OS user
```

**group_vars/pi_runners.yml:**
```yaml
runner_user: actions-runner
runner_home: /opt/actions-runner
cache_base: /opt/runner-cache
```

## Acceptance Criteria

- [ ] `ansible.cfg` exists with documented configuration
- [ ] Inventory follows standard Ansible layout (`inventories/{env}/hosts.yml`)
- [ ] `group_vars/` and `host_vars/` directories established
- [ ] `ansible-playbook playbooks/ping.yml -i inventories/production` succeeds
- [ ] Sensitive value placeholders documented (IP, token locations)
- [ ] Second run produces identical results (idempotent by nature)

## Out of Scope

- Creating the `actions-runner` user (Stage 2)
- Installing any packages on the Pi (Stage 2+)
- Docker, runner, or hooks setup (Stages 3–6)
- Development inventory population (future)

## Dependencies

- **Requires:**
  - Fresh Raspberry Pi 5 with:
    - Raspberry Pi OS Lite (64-bit, Bookworm) installed
    - SSH enabled (via Pi Imager or `raspi-config`)
    - Network connectivity
    - Known IP address or hostname
  - SSH key access configured (public key in Pi's `~pi/.ssh/authorized_keys`)

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
# From control machine (where Ansible is installed)
cd PerformanceNode

# Test connectivity
ansible-playbook playbooks/ping.yml -i inventories/production

# Expected output:
# pi5-runner : ok=1  changed=0  unreachable=0  failed=0
```

## Notes

### Bootstrap SSH Access

This stage assumes SSH is already configured on the Pi. Recommended bootstrap methods:

1. **Pi Imager (recommended):** When flashing the SD card, use the gear icon to:
   - Enable SSH
   - Set username/password
   - Add your SSH public key

2. **Manual:** After first boot, run `sudo raspi-config` to enable SSH, then copy your public key.

### Secrets Strategy

The runner registration token will be needed in Stage 4. This stage only establishes the pattern:
- Sensitive values marked with comments: `# Set via --extra-vars or vault`
- Actual vault setup deferred until needed

### IP Address

The Pi's IP can be:
- Static (configured in router or Pi's `/etc/dhcpcd.conf`)
- Dynamic with mDNS (`pi5-runner.local` if avahi-daemon is running)
- Set at runtime: `ansible-playbook ... -e "pi5_ip=192.168.1.100"`
