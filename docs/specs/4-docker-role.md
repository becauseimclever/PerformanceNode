# Spec: Docker Runtime Role

**Spec ID:** `4-docker-role`  
**Stage:** 3 of 8  
**Status:** 📝 Draft — Awaiting Approval  
**Author:** Treize (Lead)  
**GitHub Issue:** [#4](https://github.com/becauseimclever/PerformanceNode/issues/4)

---

## Overview

Create the `docker` Ansible role that installs Docker CE on the Pi 5 and configures it for GitHub Actions container execution.

## Problem

GitHub Actions jobs must run inside disposable containers (per team decision). This requires:
- Docker CE installed from the official Docker repository (not Debian's older version)
- Proper daemon configuration (storage driver, log rotation)
- Cgroup memory limits enabled in the kernel
- The `actions-runner` user able to run Docker commands

## Solution

Create `roles/docker/` that installs Docker CE (ARM64), configures the daemon, patches the kernel cmdline for cgroups, and adds the runner user to the docker group.

### Directory Structure

```
roles/docker/
  tasks/
    main.yml             # Orchestrates all tasks
    install.yml          # Docker CE installation
    daemon.yml           # Daemon configuration
    cgroups.yml          # Cgroup cmdline patch
    users.yml            # Add runner to docker group
  handlers/
    main.yml             # Handlers for daemon reload/restart
  defaults/
    main.yml             # Default variables
  templates/
    daemon.json.j2       # Docker daemon configuration
  files/
    (none initially)
```

### Key Tasks

**Docker Installation (`tasks/install.yml`):**
```yaml
- name: Add Docker GPG key
  apt_key:
    url: https://download.docker.com/linux/debian/gpg
    state: present

- name: Add Docker repository
  apt_repository:
    repo: "deb [arch=arm64] https://download.docker.com/linux/debian {{ ansible_distribution_release }} stable"
    state: present

- name: Install Docker CE
  apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
    state: present
    update_cache: yes
```

**Daemon Configuration (`templates/daemon.json.j2`):**
```json
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

**Cgroup Patch (`tasks/cgroups.yml`):**
```yaml
- name: Enable cgroup memory in cmdline.txt
  lineinfile:
    path: /boot/firmware/cmdline.txt
    regexp: '^(.*)$'
    line: '\1 cgroup_memory=1 cgroup_enable=memory'
    backrefs: yes
  register: cgroup_patch
  when: "'cgroup_memory=1' not in cmdline_content.stdout"

- name: Flag reboot required if cgroups patched
  set_fact:
    reboot_required: true
  when: cgroup_patch.changed
```

**User Setup (`tasks/users.yml`):**
```yaml
- name: Add actions-runner to docker group
  user:
    name: "{{ runner_user }}"
    groups: docker
    append: yes
```

## Acceptance Criteria

- [ ] Docker CE installed from official Docker repository (not Debian)
- [ ] `docker version` shows Docker 24.x or newer
- [ ] `/etc/docker/daemon.json` contains overlay2 and log rotation config
- [ ] `/boot/firmware/cmdline.txt` includes `cgroup_memory=1 cgroup_enable=memory`
- [ ] `actions-runner` user can run `docker run hello-world` without sudo
- [ ] Reboot-required flag surfaced when cgroups patched
- [ ] Role is idempotent (second run reports no changes after reboot)

## Out of Scope

- QEMU/binfmt for cross-architecture images (explicitly rejected per decision)
- Docker Compose installation (not needed for runner)
- Custom Docker networks or volumes
- Container image pre-pulling (Stage 6)

## Dependencies

- **Requires:**
  - Stage 2 complete (`actions-runner` user must exist)
  - Internet access for Docker repository

- **Enables:**
  - Stage 4: GitHub runner installation
  - Stage 5: Container hooks (needs Docker to run hook containers)

## Agent Assignment

| Role | Agent |
|------|-------|
| Implement | Heero |
| Review | Treize |
| Validate | Noin |

## Verification

```bash
# Run the role
ansible-playbook playbooks/pi-runner.yml -i inventories/production --tags docker

# Check for reboot requirement
# If changed, reboot Pi:
ansible pi5-runner -i inventories/production -m reboot

# Verify Docker installation (on Pi)
docker version
# Expected: Client and Server both show 24.x

# Verify daemon config
cat /etc/docker/daemon.json
# Expected: overlay2, log rotation settings

# Verify cgroups
cat /proc/cmdline | grep cgroup_memory
# Expected: cgroup_memory=1 cgroup_enable=memory

# Verify user access (as actions-runner)
sudo -u actions-runner docker run --rm hello-world
# Expected: "Hello from Docker!"

# Verify idempotency
ansible-playbook playbooks/pi-runner.yml -i inventories/production --tags docker
# Expected: changed=0 (after reboot)
```

## Notes

### Reboot Handling

The cgroup cmdline patch requires a reboot. The role should:
1. Register when the patch is applied
2. Set a fact (`reboot_required: true`)
3. Optionally trigger reboot via handler (user choice)

```yaml
# In handlers/main.yml
- name: reboot if required
  reboot:
    msg: "Rebooting for cgroup changes"
  when: reboot_required | default(false)
```

### ARM64 Architecture

The role explicitly targets ARM64:
- Repository uses `[arch=arm64]`
- No QEMU/binfmt means x86 images will fail (this is intentional)
- Workflows must use ARM64-compatible images

### Log Rotation

Critical for SD card/SSD longevity:
- `max-size: 10m` — rotate at 10MB
- `max-file: 3` — keep only 3 rotations

Total max log space per container: 30MB.

### Storage Driver

`overlay2` is the default and best choice for:
- Modern kernels (5.x+)
- ext4 filesystem (Pi OS default)
- Performance on flash storage
