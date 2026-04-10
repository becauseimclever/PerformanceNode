# Spec: C# / .NET 10 Example Workflow

| Field            | Value                                      |
|------------------|--------------------------------------------|
| **Issue**        | TBD (create GitHub issue)                  |
| **Author**       | Treize                                     |
| **Status**       | 📝 Draft                                   |
| **Created**      | 2026-04-10                                 |
| **Last Updated** | 2026-04-10                                 |

---

## Overview

Provide a ready-to-copy GitHub Actions workflow example demonstrating how to build and test a C# (.NET 10) project on the PerformanceNode self-hosted runner. The example workflow serves as a reference for repo owners unfamiliar with GitHub Actions, container builds, or the PerformanceNode runner's cache mounts.

## Problem Statement

Repository owners want to use the PerformanceNode Pi 5 runner for their C# / .NET projects but lack documentation on:
- Correct `runs-on` label and container image to use
- How to configure NuGet caching via the bind-mounted `/opt/runner-cache/nuget` volume
- How to use the `dotnet` CLI correctly inside a container
- What to expect from the CI/CD integration (test results, logs, artifacts)

Without a concrete example, users may:
- Configure incorrect container images (e.g., multi-arch images, amd64-only images)
- Skip caching setup, resulting in slow builds and excessive SD card wear
- Assume the runner works like GitHub-hosted runners, missing container-specific gotchas
- Waste time troubleshooting instead of building

## Proposed Solution

A ready-to-use GitHub Actions workflow YAML file at `examples/workflows/dotnet-test.yml` that demonstrates:

1. **Runner selection** — uses `runs-on: [ self-hosted, linux, arm64 ]` to select the PerformanceNode Pi 5
2. **Container configuration** — runs jobs inside the official `mcr.microsoft.com/dotnet/sdk:10.0` container (ARM64-native)
3. **NuGet caching** — mounts the host's NuGet cache (`/opt/runner-cache/nuget`) into the container at the correct location
4. **Build steps** — demonstrates `dotnet restore`, `dotnet build`, and `dotnet test` with clear output
5. **Test reporting** — parses test results and publishes them to the GitHub Actions workflow summary
6. **Inline comments** — explains non-obvious lines (e.g., cache mounts, environment variables, container overrides)

The workflow is self-contained and includes:
- A link to a minimal example `.csproj` or instructions on what the user needs to supply
- References to relevant documentation (`docs/caching-strategy.md`, etc.)
- Environment variable setup for NuGet cache path
- Error handling and clear failure messages

## Acceptance Criteria

- [ ] The workflow file exists at `examples/workflows/dotnet-test.yml` and is valid GitHub Actions YAML
- [ ] The workflow runs without modification on the PerformanceNode runner and completes successfully with a sample .NET 10 project
- [ ] The workflow uses `runs-on: [ self-hosted, linux, arm64 ]` to route jobs to the PerformanceNode Pi 5
- [ ] The workflow specifies `container: mcr.microsoft.com/dotnet/sdk:10.0` (or a compatible version) and does not use any amd64-only images
- [ ] The workflow mounts the host NuGet cache at `/opt/runner-cache/nuget` into the container at the correct path (respecting container environment)
- [ ] The workflow sets the `NUGET_PACKAGES` environment variable to the correct mount point inside the container
- [ ] On a second run with the same project, NuGet restore uses cached packages (measurably faster than first run)
- [ ] Test results are parsed and published to the workflow summary (visible in the GitHub Actions UI)
- [ ] The workflow includes inline comments explaining container mounts, environment variables, and why certain lines are necessary
- [ ] The workflow includes a link or reference to documentation explaining cache setup and PerformanceNode-specific configuration
- [ ] The workflow runs `dotnet test` and exits non-zero (failure status) if any test fails, preventing false-positive CI runs
- [ ] A minimal example `.csproj` is provided (inline, linked, or documented) so users can test the workflow without supplying their own project
- [ ] The example includes at least one passing test and one skipped test (to demonstrate test result parsing)

## Out of Scope

- Custom Docker image builds (e.g., `pico-builder` or project-specific images) — use official base images only
- GitHub Actions caching via `actions/cache` — this runner uses local disk mounts instead
- Multi-platform builds (e.g., running the same workflow on macOS, Windows, and Linux) — this example is Pi 5 specific
- Deployment or artifact publishing steps — the example is focused on build and test
- Performance benchmarking — separate spec (Wufei's domain); this example is functional validation only
- Private NuGet feeds or authentication — assume public NuGet.org only

## Dependencies

- Spec 0001 (Pi 5 Base OS Setup) — the PerformanceNode runner must be installed and functional
- Spec 0002 (Dependency Caching) — NuGet cache directories must be created and the cache-hook.js wrapper must be installed
- Documentation: `docs/caching-strategy.md` — provides background on the caching architecture

## Agent Assignment

| Agent  | Role in this spec                                                              |
|--------|--------------------------------------------------------------------------------|
| Heero  | Primary implementer — writes the workflow YAML, example `.csproj`, documents cache setup |
| Noin   | Tests the workflow on PerformanceNode, validates test result parsing            |
| Treize | Architecture review, alignment with caching strategy                           |

## Notes

- ⚠️ GitHub issue required — create issue and update this spec with the issue number before merging.
- The example workflow should be **minimal but complete** — it should run end-to-end without modification, but it should not include unrelated features like deployment, artifact upload, or slack notifications.
- Consider providing two versions: (a) a minimal version for absolute clarity, and (b) an extended version showing optional features like matrix builds for multiple .NET versions.
- The `.NET SDK` container image tag should be pinned to a specific version (e.g., `10.0-noble` for Ubuntu Noble Numbat) to avoid surprise image updates.
- Inline comments should explain:
  - Why `container:` is used (isolation, cache mounts)
  - What `NUGET_PACKAGES` does and why it matters
  - How to adapt the workflow for different project structures
  - Gotchas: container user IDs, file permissions on cache volumes, etc.
- The example `.csproj` should include:
  - A reference to at least one NuGet package (e.g., `NUnit` or `xUnit`) to demonstrate cache behavior
  - A simple unit test so test result parsing can be validated
  - Instructions for users to replace it with their own project
- Reference: [official .NET container images](https://mcr.microsoft.com/catalog/dotnet/sdk), [GitHub Actions container docs](https://docs.github.com/en/actions/using-jobs/running-jobs-in-a-container), and `docs/caching-strategy.md` section on NuGet cache mount points.
