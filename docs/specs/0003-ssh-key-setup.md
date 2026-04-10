# Spec: SSH Key-Based Authentication Setup

| Field            | Value                                      |
|------------------|--------------------------------------------|
| **Issue**        | TBD (create GitHub issue)                  |
| **Author**       | Treize                                     |
| **Status**       | 📝 Draft                                   |
| **Created**      | 2026-04-10                                 |
| **Last Updated** | 2026-04-10                                 |

---

## Overview

Configure SSH key-based authentication on a fresh Pi OS installation, allowing secure passwordless login via SSH keys while disabling the insecure and inconvenient password authentication method. This setup is a prerequisite for automated administration and unattended remote access.

## Problem Statement

A stock Raspberry Pi OS installation uses password-based SSH authentication, which is:
- **Insecure** — weak passwords are common; brute-force attacks are viable on exposed Pi instances
- **Inconvenient for automation** — passwords cannot be safely baked into automation scripts or CI/CD workflows
- **Error-prone** — manual password entry during setup is tedious and easy to forget after configuration changes

Without a key-based setup process, Fortinbra must manually generate keys, copy them to the Pi, and remember to disable PasswordAuthentication — each step is a potential failure point.

## Proposed Solution

An idempotent bash setup script that:

1. **Detects SSH key configuration** — checks whether `~/.ssh/authorized_keys` exists and contains at least one valid public key
2. **Adds the user's public key if missing** — either by:
   - Prompting the user to paste their public key content directly, or
   - Printing instructions for running `ssh-copy-id` from the user's local machine
3. **Verifies key-based login** — attempts an SSH connection with a key to confirm it works
4. **Disables password authentication** — sets `PasswordAuthentication no` in `/etc/ssh/sshd_config`
5. **Restarts sshd** — applies the configuration change
6. **Validates permissions** — ensures `~/.ssh/authorized_keys` has mode `600` and `~/.ssh` has mode `700`

The script logs each step clearly and exits with a meaningful status code, allowing it to be re-run safely on an already-configured system without side effects.

## Acceptance Criteria

- [ ] Running the script on a fresh Pi OS installation with a valid public key (either pasted or via ssh-copy-id) results in successful key-based SSH login
- [ ] After setup, SSH login using password authentication is rejected with an authentication error
- [ ] Running the script a second time on an already-configured system completes without errors and without re-prompting the user
- [ ] The `~/.ssh/authorized_keys` file has mode `600` after setup (world-readable keys are a security vulnerability)
- [ ] The `~/.ssh` directory has mode `700` after setup
- [ ] `/etc/ssh/sshd_config` contains `PasswordAuthentication no` and sshd is restarted after the change
- [ ] The script produces clear, timestamped log output indicating each step (check, add key, verify, apply config, restart)
- [ ] The script uses `set -euo pipefail` and exits with code 0 on success, non-zero on error
- [ ] The script does NOT delete or overwrite existing keys in `authorized_keys`; it appends new keys if they are not already present

## Out of Scope

- Key generation — users must generate their own SSH key pair (`ssh-keygen -t ed25519`) on their local machine
- Multi-user SSH setup — this spec assumes a single user (typically `root` or the setup user) manages the key; enterprise multi-user or LDAP/AD integration are not covered
- GitHub deploy keys — this spec is for human SSH access, not for GitHub-to-Pi authentication
- SSH agent configuration or key forwarding (`ssh -A`)
- SSH certificate-based authentication (CA-signed keys) — future enhancement

## Dependencies

- Spec 0001 (Pi 5 Base OS Setup) — the Pi must be running a functional OS with sshd installed and running before this script can configure SSH
- Optional: Spec 0004 (Single Entry Point) — this SSH setup script may be called as one phase of the top-level `setup.sh` orchestrator

## Agent Assignment

| Agent  | Role in this spec                                                              |
|--------|--------------------------------------------------------------------------------|
| Heero  | Primary implementer — writes the SSH setup script, validates idempotency       |
| Noin   | Tests on a fresh image, verifies key-based login succeeds and password fails   |
| Treize | Architecture review, security sign-off                                         |

## Notes

- ⚠️ GitHub issue required — create issue and update this spec with the issue number before merging.
- The script should run as `root` (or via `sudo`) because it modifies `/etc/ssh/sshd_config` and manages the root user's SSH keys. Consider the implications for non-root key setup (future enhancement).
- Security: Do NOT log the actual public key content; only confirm that a key was added and verified.
- The script should handle both `authorized_keys` not existing (create it) and `authorized_keys` existing but empty (append to it).
- After restarting sshd, test that at least one working key-based login method remains before declaring success. This prevents locking out the user.
- Reference: [OpenSSH authorized_keys format](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT) and [sshd_config(5)](https://man.openbsd.org/sshd_config) documentation.
