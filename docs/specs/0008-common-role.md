# Spec: Common Base Role

**Spec ID:** `0008-common-role`  
**Stage:** 2 of 8  
**Status:** 📝 Draft — Awaiting Approval  
**Author:** Treize (Lead)  
**GitHub Issue:** _Not yet created_

---

## Overview

Create the `common` Ansible role that establishes a secure OS baseline: SSH hardening, essential packages, locale, timezone, and the `actions-runner` user.

## Problem

A fresh Pi OS Lite install has:
- Password-based SSH enabled (security risk)
- Missing packages needed for runner operation
- Default locale/timezone settings
- No dedicated user for running the GitHub Actions runner

This role transforms a fresh Pi into a hardened, ready-to-configure host.

## Solution

Create `roles/common/` with tasks that:
1. Harden SSH (disable password auth, restart sshd)
2. Install base packages
3. Configure locale and timezone
4. Create the `actions-runner` user with sudo privileges

### Directory Structure

```
roles/common/
  tasks/
    main.yml             # Orchestrates all tasks
    ssh.yml              # SSH hardening
    packages.yml         # Base package installation
    locale.yml           # Locale and timezone
    users.yml            # Runner user creation
  handlers/
    main.yml             # Handler for sshd restart
  defaults/
    main.yml             # Default variables
  templates/
    sshd_config.j2       # Hardened SSH config (optional)
```

### Key Tasks

**SSH Hardening (`tasks/ssh.yml`):**
```yaml
- name: Disable SSH password authentication
  lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PasswordAuthentication'
    line: 'PasswordAuthentication no'
  notify: restart sshd

- name: Disable SSH root login
  lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PermitRootLogin'
    line: 'PermitRootLogin no'
  notify: restart sshd
```

**Base Packages (`tasks/packages.yml`):**
```yaml
common_packages:
  - curl
  - wget
  - git
  - jq
  - htop
  - unzip
  - ca-certificates
  - gnupg
  - lsb-release
```

**Runner User (`tasks/users.yml`):**
```yaml
- name: Create actions-runner user
  user:
    name: "{{ runner_user }}"
    shell: /bin/bash
    groups: sudo
    append: yes
    create_home: yes
```

## Acceptance Criteria

- [ ] SSH password authentication disabled in `/etc/ssh/sshd_config`
- [ ] Root SSH login disabled
- [ ] Base packages installed (list in defaults)
- [ ] Timezone set to configured value (default: UTC)
- [ ] `actions-runner` user exists with sudo group membership
- [ ] Role is idempotent (second run reports no changes)
- [ ] All tasks tagged appropriately for selective runs

## Out of Scope

- Docker installation (Stage 3)
- GitHub runner installation (Stage 4)
- Any runner-specific configuration
- Firewall/ufw configuration (can add later if needed)

## Dependencies

- **Requires:**
  - Stage 1 complete (inventory, connectivity verified)
  - SSH key already in `~pi/.ssh/authorized_keys` (or you'll lock yourself out!)

- **Enables:**
  - Stage 3: Docker role (needs `actions-runner` user to add to docker group)
  - Stage 4: GitHub runner role (installs as `actions-runner` user)

## Agent Assignment

| Role | Agent |
|------|-------|
| Implement | Heero |
| Review | Treize |
| Validate | Noin |

## Verification

```bash
# Run the role
ansible-playbook playbooks/pi-runner.yml -i inventories/production --tags common

# Verify SSH hardening (from control machine)
ssh -o PasswordAuthentication=yes pi@<pi-ip>
# Expected: Permission denied (no password auth)

# Verify user exists (on Pi)
id actions-runner
# Expected: uid=1001(actions-runner) gid=1001(actions-runner) groups=...,sudo

# Verify packages
dpkg -l | grep -E "curl|git|jq"
# Expected: All packages listed as installed

# Verify idempotency
ansible-playbook playbooks/pi-runner.yml -i inventories/production --tags common
# Expected: changed=0
```

## Notes

### SSH Key Warning

**⚠️ CRITICAL:** Before running this role, ensure your SSH public key is already in `~pi/.ssh/authorized_keys`. Disabling password auth without key access will lock you out of the Pi.

The role should include a pre-flight check:
```yaml
- name: Verify SSH key access before hardening
  assert:
    that:
      - ansible_ssh_private_key_file is defined or lookup('env', 'SSH_AUTH_SOCK') != ''
    fail_msg: "SSH key access required before disabling password auth"
```

### Locale Considerations

Default to `en_US.UTF-8` and `UTC` timezone. Override via:
```yaml
# group_vars/pi_runners.yml
common_locale: en_GB.UTF-8
common_timezone: Europe/London
```

### Sudo Configuration

The `actions-runner` user needs passwordless sudo for certain runner operations:
```yaml
- name: Allow actions-runner passwordless sudo
  copy:
    content: "{{ runner_user }} ALL=(ALL) NOPASSWD:ALL"
    dest: "/etc/sudoers.d/{{ runner_user }}"
    mode: '0440'
    validate: 'visudo -cf %s'
```
