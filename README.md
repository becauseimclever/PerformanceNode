# PerformanceNode

A dedicated performance-testing environment built on a **Raspberry Pi 5**.
PerformanceNode runs containerised benchmark suites and hardware-assisted
latency tests for the [GP2040-CE](https://github.com/OpenStickCommunity/GP2040-CE)
gamepad firmware, reporting results directly to GitHub via a self-hosted
GitHub Actions runner.

---

## Overview

| Component | Purpose |
|---|---|
| **Raspberry Pi 5** | Bare-metal host for all tests |
| **Docker** | Isolated, reproducible benchmark containers |
| **GitHub Actions (self-hosted)** | Test orchestration and result publication |
| **Custom HAT** | GPIO ↔ GP2040-CE bridge for input-latency measurement |

---

## Repository Layout

```
.github/
  workflows/
    performance-test.yml   # CPU / memory / stress benchmarks (Docker)
    latency-test.yml       # GP2040-CE input-latency tests (HAT)
docker/
  docker-compose.yml       # Compose stack for local ad-hoc test runs
  performance/
    Dockerfile             # Multi-stage image (wrk / iperf3 / stress-ng / sysbench)
    entrypoints/           # Per-tool entrypoint scripts
hat/
  latency_test.py          # GPIO-based latency measurement script
  config/
    hat-config.json        # HAT GPIO pin assignments and test parameters
scripts/
  setup.sh                 # Main entry-point (runs all steps below)
  setup-system.sh          # OS hardening, packages, sysctl tuning
  setup-docker.sh          # Docker Engine installation
  setup-github-runner.sh   # Self-hosted Actions runner installation
  setup-hat.sh             # Custom HAT driver, udev rules, Python venv
```

---

## Hardware

### Raspberry Pi 5

- Raspberry Pi OS Lite (64-bit / bookworm)
- 4 GB or 8 GB RAM recommended
- USB-A port for GP2040-CE device

### Custom HAT – GP2040-CE Latency Tester

The HAT bridges the Pi's GPIO to the button inputs of a GP2040-CE device,
enabling automated, microsecond-precision latency measurements.

**GPIO pin assignments (BCM numbering):**

| BCM Pin | Direction | Function |
|---------|-----------|----------|
| 4 | IN | Button signal from GP2040-CE |
| 17 | OUT | Trigger output to GP2040-CE button input |
| 27 | OUT | Status LED |

**Measurement flow:**

1. Pi asserts GPIO 17 → GP2040-CE receives button press.
2. GP2040-CE processes the input and asserts a GPIO output back to the Pi (GPIO 4).
3. Pi measures the elapsed time between steps 1 and 2.

---

## Setup

### Prerequisites

- Fresh Raspberry Pi OS Lite (64-bit) image written to SD card / NVMe.
- SSH access to the Pi.
- A GitHub repository URL and a runner registration token
  ([Settings → Actions → Runners → New self-hosted runner](https://github.com/becauseimclever/PerformanceNode/settings/actions/runners/new)).

### Run the setup script

```bash
# Clone this repository onto the Pi.
git clone https://github.com/becauseimclever/PerformanceNode.git
cd PerformanceNode

# Run the full setup (requires root).
sudo bash scripts/setup.sh \
  --runner-url   https://github.com/becauseimclever/PerformanceNode \
  --runner-token <REGISTRATION_TOKEN>

# Reboot to apply all changes.
sudo reboot
```

#### Individual steps

```bash
sudo bash scripts/setup-system.sh        # OS tuning only
sudo bash scripts/setup-docker.sh        # Docker only
sudo bash scripts/setup-github-runner.sh # Runner only
sudo bash scripts/setup-hat.sh           # HAT / GPIO only
```

#### Skip individual steps

```bash
sudo bash scripts/setup.sh --skip-hat   # Skip HAT setup (no HAT attached)
sudo bash scripts/setup.sh --skip-runner # Skip runner setup
```

---

## Running Tests

### Via GitHub Actions (recommended)

All workflows run automatically on a daily schedule and can be triggered
manually from **Actions → workflow → Run workflow**.

| Workflow | Schedule | Manual trigger |
|----------|----------|---------------|
| Performance Tests | Daily 02:00 UTC | ✅ |
| GP2040-CE Latency Tests | Daily 03:00 UTC | ✅ |

Results are uploaded as workflow artifacts and summarised in the run's
**Summary** tab.

### Locally with Docker Compose

```bash
# CPU benchmark
docker compose --profile cpu -f docker/docker-compose.yml up sysbench

# Memory benchmark
SYSBENCH_TEST=memory docker compose --profile memory -f docker/docker-compose.yml up sysbench

# HTTP benchmark (requires a running server)
WRK_URL=http://myserver/ docker compose --profile http -f docker/docker-compose.yml up wrk

# Network throughput (requires an iperf3 server)
IPERF3_SERVER=192.168.1.100 docker compose --profile network -f docker/docker-compose.yml up iperf3
```

### Latency test (requires HAT)

```bash
# Using the installed virtual environment
/opt/performancenode/venv/bin/python3 hat/latency_test.py \
  --config hat/config/hat-config.json \
  --output /opt/performancenode/results/latency
```

---

## Configuration

### HAT config (`hat/config/hat-config.json`)

| Key | Default | Description |
|-----|---------|-------------|
| `gpio.button_signal_pin` | 4 | BCM pin for the GP2040-CE signal input |
| `gpio.trigger_output_pin` | 17 | BCM pin that drives the button press |
| `gpio.status_led_pin` | 27 | BCM pin for the status LED |
| `latency_test.sample_count` | 1000 | Number of measurements |
| `latency_test.warmup_samples` | 50 | Discarded warmup measurements |
| `latency_test.trigger_interval_ms` | 100 | Delay between triggers |
| `latency_test.timeout_ms` | 500 | Per-sample timeout |

---

## Results

All result files are JSON and are stored on the Pi under
`/opt/performancenode/results/`. They are also uploaded as GitHub Actions
artifacts, retained for:

- **Performance benchmarks** – 90 days
- **Latency results** – 365 days

---

## Runner Labels

The self-hosted runner registers with the following labels so that workflows
target it precisely:

```
self-hosted, Linux, ARM64, raspberry-pi-5, performancenode
```
