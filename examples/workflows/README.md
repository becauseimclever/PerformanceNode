# Example Workflows

These example workflows are ready to copy into your repo's `.github/workflows/` directory.
They are pre-configured for the PerformanceNode Raspberry Pi 5 self-hosted runner.

## Prerequisites

1. **Runner set up** — the Pi must be fully configured with the PerformanceNode setup scripts.
   Clone this repo onto the Pi and run `./setup.sh`.
2. **Cache initialised** — run the relevant cache scripts before the first workflow execution
   (e.g. `sudo scripts/cache/setup-nuget-cache.sh` for .NET projects).
3. **Runner registered** — the Pi runner must be registered with GitHub Actions using the
   labels listed in each workflow's `runs-on` field.

## Runner Labels

All example workflows target:

```yaml
runs-on: [self-hosted, linux, arm64, performancenode]
```

Adjust the labels if you registered the runner with different names.
The runner registration command is managed by `scripts/setup/setup-runner.sh`.

## Workflows

| File | Description |
|---|---|
| [`dotnet-test.yml`](dotnet-test.yml) | Build and test a .NET 10 C# project inside the official `mcr.microsoft.com/dotnet/sdk:10.0` container. Uses the host-mounted NuGet cache for fast, network-free package restores. |
| [`mcu-performance-test.yml`](mcu-performance-test.yml) | Flash the four HAT-connected MCUs, collect the aggregated harness UART report, and publish artifacts/results from the Pi runner. |

## How Caching Works

Caches are **not** managed with `actions/cache`. Instead, the runner's
`cache-hook-wrapper.js` (installed by `scripts/cache/inject-cache-mounts.sh`)
intercepts the `prepare_job` hook and bind-mounts host cache directories into
every job container automatically:

| Host path | Container path | Access |
|---|---|---|
| `/opt/runner-cache/nuget` | `/root/.nuget/packages` | read-write |
| `/opt/runner-cache/pico-sdk` | `/opt/pico-sdk` | read-only |
| `/opt/runner-cache/ccache` | `/root/.ccache` | read-write |

See [`docs/caching-strategy.md`](../../docs/caching-strategy.md) for the full strategy.
