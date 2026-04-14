# Cache Scripts

Scripts in this directory set up persistent host-side caches on the Pi 5 and bind-mount them into every GitHub Actions job container via the `ACTIONS_RUNNER_CONTAINER_HOOKS` wrapper.

## Architecture overview

```
Pi 5 host
├── /opt/runner-cache/nuget        ← NuGet packages (shared across .NET jobs)
├── /opt/runner-cache/pico-sdk     ← Pico SDK source tree (read-only in containers)
├── /opt/runner-cache/ccache       ← ccache object cache (C/C++ compilation)
└── /opt/runner-hooks/
    ├── cache-hook-wrapper.js  ← injects mounts into every job container
    └── node_modules/@actions/runner-container-hooks/...  ← real Docker hook
```

Every job container gets three bind mounts automatically (no `volumes:` in workflow YAML required):

| Host path                    | Container path          | Mode |
|------------------------------|-------------------------|------|
| `/opt/runner-cache/nuget`    | `/root/.nuget/packages` | rw   |
| `/opt/runner-cache/pico-sdk` | `/opt/pico-sdk`         | ro   |
| `/opt/runner-cache/ccache`   | `/root/.ccache`         | rw   |

---

## Scripts

### `setup-nuget-cache.sh`

Creates `/opt/runner-cache/nuget`, sets sticky-bit permissions for container UID compatibility, and writes a runner systemd drop-in that exposes `NUGET_PACKAGES=/opt/runner-cache/nuget` to the runner process.

```bash
sudo ./setup-nuget-cache.sh
# With a local BaGet NuGet mirror on localhost:5000:
sudo ./setup-nuget-cache.sh --with-local-feed
```

**To update the NuGet cache:**  The cache is a plain directory; packages accumulate automatically.  To clear stale packages:
```bash
sudo rm -rf /opt/runner-cache/nuget/*
```

---

### `setup-pico-sdk-cache.sh`

Installs `gcc-arm-none-eabi`, `cmake`, `ninja-build`, and `ccache` via apt (pinned to Debian Bookworm versions), clones the Pico SDK at `PICO_SDK_VERSION` to `/opt/runner-cache/pico-sdk`, and creates `/opt/runner-cache/ccache` with sticky-bit permissions for container UID compatibility.

```bash
sudo ./setup-pico-sdk-cache.sh
# Override SDK version:
sudo PICO_SDK_VERSION=2.2.0 ./setup-pico-sdk-cache.sh
```

**To update the Pico SDK version:**

1. Set `PICO_SDK_VERSION` to the new tag (check https://github.com/raspberrypi/pico-sdk/releases).
2. Delete the existing directory: `sudo rm -rf /opt/runner-cache/pico-sdk`
3. Re-run: `sudo PICO_SDK_VERSION=<new-tag> ./setup-pico-sdk-cache.sh`
4. Run `sudo systemctl restart actions-runner` to apply the new path.

**Pinned apt versions** (verify after `apt-get upgrade`):

| Package             | Pinned version   | Override env var    |
|---------------------|------------------|---------------------|
| `gcc-arm-none-eabi` | `15:12.2.rel1-1` | `ARM_GCC_VERSION`   |
| `cmake`             | `3.25.1-1`       | `CMAKE_VERSION`     |
| `ninja-build`       | `1.11.1.1-1`     | `NINJA_VERSION`     |
| `ccache`            | `4.7.4-1`        | `CCACHE_APT_VERSION`|

---

### `setup-docker-image-cache.sh`

Pre-pulls Docker base images for .NET 10 and Pico SDK jobs so they are available locally (no network needed on first job run).

```bash
sudo ./setup-docker-image-cache.sh
# With a local Docker registry mirror on localhost:5001:
sudo ./setup-docker-image-cache.sh --with-local-registry
```

**Images pre-pulled:**
- `mcr.microsoft.com/dotnet/sdk:10.0` (ARM64)
- `mcr.microsoft.com/dotnet/runtime:10.0` (ARM64)
- `mcr.microsoft.com/dotnet/aspnet:10.0` (ARM64)
- `debian:bookworm-slim` (ARM64) — Pico SDK builds
- `ubuntu:22.04` (ARM64) — general-purpose CI base

**To update image tags:** Edit the `IMAGES` array in the script, then re-run.  The script skips images that are already cached, so only new tags are pulled.

---

### `inject-cache-mounts.sh`

Installs `/opt/runner-hooks/cache-hook-wrapper.js` and writes a systemd drop-in that routes `ACTIONS_RUNNER_CONTAINER_HOOKS` through the wrapper. If the runner has not been registered yet, the drop-in is staged and later synced to the real runner service on first runner setup.

The wrapper intercepts `prepare_job` and injects the three cache bind mounts plus environment variables (`NUGET_PACKAGES`, `PICO_SDK_PATH`, `CCACHE_DIR`) into the container spec before forwarding to the real Docker hook.

```bash
sudo ./inject-cache-mounts.sh
sudo systemctl restart actions-runner
```

**Workflow env overrides:** If a workflow sets `NUGET_PACKAGES` or `PICO_SDK_PATH` in its `env:` block, those values take priority over the wrapper's defaults.

**To update mount paths:** Edit `CACHE_MOUNTS` and `CACHE_ENV` at the top of `cache-hook-wrapper.js` (at `/opt/runner-hooks/cache-hook-wrapper.js`), then restart the runner.

---

## Required execution order

Run these scripts in order on first setup:

```
1. [Treize] Docker Engine + actions-runner setup
2. setup-nuget-cache.sh
3. setup-pico-sdk-cache.sh
4. setup-docker-image-cache.sh   (optional but recommended)
5. inject-cache-mounts.sh
6. sudo systemctl restart actions-runner
```

Scripts 2–5 are independently idempotent — safe to re-run at any time.

---

## Pending / needs review

- **Noin testing:** All four scripts need a full integration run on a real Pi 5 to verify apt version pins match actual Bookworm packages and that `prepare_job` JSON field names match the installed version of `@actions/runner-container-hooks`.
- **Treize review:** The `cache-hook-wrapper.js` JSON field names (`userMountVolumes`, `sourceVolumePath`, `targetVolumePath`, `environmentVariables`) should be verified against the installed package version.  If the package uses different field names, the wrapper will need updating.
- **ccache in containers:** The `arm-none-eabi-gcc` toolchain is installed on the host but not inside job containers.  Workflows targeting Pico SDK builds should use `debian:bookworm-slim` and install `gcc-arm-none-eabi` themselves (or Wufei can create a dedicated ARM builder image with the toolchain baked in).
