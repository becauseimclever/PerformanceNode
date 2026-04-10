# Cache Metrics Benchmarks

Scripts in this directory measure the effectiveness of the dependency caches
used by the PerformanceNode GitHub Actions self-hosted runner.

## Scripts

| Script | What it measures |
|---|---|
| `measure-nuget-cache.sh` | .NET 10 restore + build cold vs warm |
| `measure-pico-sdk-cache.sh` | Pico SDK cmake/make build cold vs warm (ccache) |
| `measure-docker-cache.sh` | Docker image pull cold vs cached |
| `run-all-cache-benchmarks.sh` | Orchestrator — runs all three, writes `summary.json` |

---

## 1. NuGet Cache (`measure-nuget-cache.sh`)

### What it measures
- **Cold build** — `dotnet restore` + `dotnet build` with an empty local NuGet package store.
  All packages must be downloaded from NuGet.org.
- **Warm build** — same build with packages already in `/opt/cache/nuget` (the bind-mounted cache).
  Packages are resolved from disk, no network required.
- **Network delta** — bytes sent/received (from `/proc/net/dev`) for each run.
- **Packages from cache** — number of `.nupkg` files in the warm store.

### JSON output
```json
{
  "cold_build_ms": 45200,
  "warm_build_ms": 8100,
  "speedup_factor": 5.58,
  "packages_from_cache": 42,
  "network_bytes_cold": 12345678,
  "network_bytes_warm": 1024,
  "disk_read_bytes_cold": 2048000,
  "disk_read_bytes_warm": 98304000
}
```

### Interpreting results
| Metric | Good | Investigate |
|---|---|---|
| `speedup_factor` | ≥ 3× | < 2× |
| `network_bytes_warm` | < 50 KB | > 1 MB (packages leaking to network) |
| `packages_from_cache` | matches project deps | 0 (cache miss) |

### Environment variables
| Variable | Default | Description |
|---|---|---|
| `NUGET_CACHE_DIR` | `/opt/cache/nuget` | Host-mounted NuGet package cache |
| `WORK_DIR` | `/tmp/nuget-bench` | Scratch directory |
| `TEST_PROJECT` | *(auto-generated)* | Path to a `.csproj` to build |

---

## 2. Pico SDK Cache (`measure-pico-sdk-cache.sh`)

### What it measures
- **Cold build** — full `cmake` configure + `make` of the blink example with no ccache.
- **Warm build** — same build with ccache populated (object files already cached).
  The warm run should only invoke the compiler for changed translation units.
- **ccache hit rate** — parsed from `ccache -s` after the warm build.
- **Toolchain startup overhead** — time to run `arm-none-eabi-gcc --version`
  (baseline for per-invocation latency).

### JSON output
```json
{
  "cold_build_ms": 120400,
  "warm_build_ms": 9800,
  "ccache_hit_rate_pct": 97.3,
  "speedup_factor": 12.29,
  "toolchain_overhead_ms": 45
}
```

### Interpreting results
| Metric | Good | Investigate |
|---|---|---|
| `speedup_factor` | ≥ 5× | < 2× |
| `ccache_hit_rate_pct` | ≥ 90 % | < 70 % (cache eviction or key mismatch) |
| `toolchain_overhead_ms` | < 100 ms | > 300 ms (NFS/SD card latency) |

### Environment variables
| Variable | Default | Description |
|---|---|---|
| `PICO_SDK_PATH` | `/opt/pico-sdk` | Path to the Pico SDK |
| `CCACHE_DIR` | `/opt/cache/ccache` | Host-mounted ccache directory |
| `WORK_DIR` | `/tmp/pico-bench` | Scratch directory |
| `TOOLCHAIN_PREFIX` | `arm-none-eabi` | Cross-compiler prefix |

---

## 3. Docker Cache (`measure-docker-cache.sh`)

### What it measures
- **Cold pull** — `docker pull` after removing the image from the local store.
  All layers must be downloaded from the registry.
- **Warm pull** — `docker pull` when all layers are already present locally.
  Should complete in < 2 s (just manifest check, no data transfer).
- **Image size** — uncompressed size (bytes stored on disk).
- **Compressed size** — compressed layer size from the registry manifest
  (requires `skopeo`; reported as `0` if unavailable).
- **Registry pull** — if `LOCAL_REGISTRY` is set, also measures pull latency
  from a local registry (e.g. a Pi-hosted registry mirror).

### JSON output
```json
{
  "cold_pull_ms": 95000,
  "warm_pull_ms": 1200,
  "image_size_mb": 820.4,
  "compressed_size_mb": 310.2,
  "speedup_ms": 93800,
  "registry_pull_ms": 4100,
  "image": "mcr.microsoft.com/dotnet/sdk:10.0"
}
```

### Interpreting results
| Metric | Good | Investigate |
|---|---|---|
| `warm_pull_ms` | < 2000 ms | > 5000 ms (layer revalidation slow) |
| `speedup_ms` | ≥ 60 000 ms | < 10 000 ms (network is very fast or cache not working) |
| `registry_pull_ms` | < 5000 ms | > 30 000 ms (local registry too slow) |

### Environment variables
| Variable | Default | Description |
|---|---|---|
| `IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0` | Docker image to measure |
| `LOCAL_REGISTRY` | *(empty)* | Optional local registry address (e.g. `192.168.1.100:5000`) |

---

## Running all benchmarks

```bash
# Run everything, output to default /tmp/cache-benchmarks/
./run-all-cache-benchmarks.sh

# Custom output directory
./run-all-cache-benchmarks.sh --output-dir /var/log/perf/cache-$(date +%Y%m%d)

# Skip Docker benchmark (e.g. no internet access in CI)
./run-all-cache-benchmarks.sh --skip-docker

# Skip Pico SDK benchmark
./run-all-cache-benchmarks.sh --skip-pico
```

### Output files
```
<output-dir>/
  nuget.json           # NuGet benchmark results
  pico_sdk.json        # Pico SDK benchmark results
  docker.json          # Docker benchmark results
  summary.json         # Combined report with all three
```

---

## Running in CI as a regression check

Add a step to your GitHub Actions workflow after a build:

```yaml
- name: Cache effectiveness benchmark
  run: |
    chmod +x scripts/performance/cache-metrics/*.sh
    scripts/performance/cache-metrics/run-all-cache-benchmarks.sh \
      --output-dir "${{ runner.temp }}/cache-benchmarks"

- name: Assert cache speedup regression
  run: |
    python3 - <<'EOF'
    import json, sys
    with open("${{ runner.temp }}/cache-benchmarks/summary.json") as f:
        d = json.load(f)

    failed = []
    nuget = d["benchmarks"].get("nuget", {})
    if nuget.get("speedup_factor", 0) < 2.0:
        failed.append(f"NuGet speedup {nuget['speedup_factor']}x < 2.0x threshold")

    pico = d["benchmarks"].get("pico_sdk", {})
    if pico.get("ccache_hit_rate_pct", 0) < 70:
        failed.append(f"ccache hit rate {pico['ccache_hit_rate_pct']}% < 70% threshold")

    if failed:
        print("CACHE REGRESSION DETECTED:")
        for f in failed:
            print(f"  ✗ {f}")
        sys.exit(1)
    else:
        print("Cache effectiveness OK ✓")
    EOF

- name: Upload cache benchmark results
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: cache-benchmarks-${{ github.run_number }}
    path: ${{ runner.temp }}/cache-benchmarks/
```

### Suggested regression thresholds
| Benchmark | Threshold | Rationale |
|---|---|---|
| NuGet `speedup_factor` | ≥ 2× | Cache saves at least half the restore time |
| NuGet `network_bytes_warm` | < 1 MB | Warm build should not download packages |
| ccache `ccache_hit_rate_pct` | ≥ 70 % | Majority of compile units served from cache |
| Pico SDK `speedup_factor` | ≥ 3× | ccache should significantly outpace cold |
| Docker `warm_pull_ms` | < 5 000 ms | Cached pull is near-instant |
