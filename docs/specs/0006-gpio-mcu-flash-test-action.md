# Spec: GPIO MCU Flash & Test Action

| Field            | Value                                      |
|------------------|--------------------------------------------|
| **Issue**        | TBD (create GitHub issue before implementation) |
| **Author**       | Treize                                     |
| **Status**       | 📝 Draft                                   |
| **Created**      | 2026-04-11                                 |
| **Last Updated** | 2026-04-11                                 |

---

## Overview

A custom GitHub Action that flashes test firmware to up to 4 microcontrollers (2× RP2040, 1× RP2350B, 1× RP2350A) on a custom Pi HAT via SWD over GPIO, then collects UART test results and surfaces them in the GitHub Actions step summary. This enables automated hardware-in-the-loop performance testing on the PerformanceNode self-hosted runner.

## Problem Statement

The PerformanceNode Pi 5 runner currently supports software-only CI/CD workflows (e.g., .NET builds, Pico SDK compilation). Fortinbra is designing a custom HAT that connects 4 MCUs to the Pi for hardware-in-the-loop testing. There is no mechanism to:

1. **Flash firmware to MCUs** from a GitHub Actions workflow — the MCUs are bare metal devices connected via the Pi's GPIO header, invisible to standard CI tooling.
2. **Collect test results from MCUs** — results arrive over UART, not stdout. GitHub Actions has no native UART integration.
3. **Access hardware devices from containers** — the runner uses `ACTIONS_RUNNER_CONTAINER_HOOKS` to isolate every job in a disposable Docker container. GPIO chips (`/dev/gpiochip4`) and UART devices (`/dev/ttyAMA*`) are not accessible from inside containers by default.

Without this action, hardware testing requires manual SSH sessions, ad-hoc scripts, and no integration with GitHub's reporting infrastructure.

## Proposed Solution

### Architecture Decision 1: Container Device Passthrough

**Decision: Extend the existing container hook wrapper to inject `--device` flags.**

Every job on this runner executes in a disposable Docker container via the hook wrapper (`cache-hook-wrapper.js`, installed by `scripts/cache/inject-cache-mounts.sh`). The wrapper already intercepts `prepare_job` to inject cache bind mounts. We extend it to also inject device passthrough for GPIO and UART hardware.

**Why this approach (Option B) over alternatives:**

| Approach | Verdict | Rationale |
|---|---|---|
| **(B) `--device` flags in hook wrapper** | ✅ **Chosen** | Natural extension of existing `cache-hook-wrapper.js`. No new services, no privileged containers, no special workflow syntax. Devices appear inside the container at their normal paths. Tools like OpenOCD and pyserial work identically to host execution. |
| (A) Host step bypass | ❌ Rejected | Not a standard feature of `@actions/runner-container-hooks`. Would require forking the hooks package or maintaining fragile step-label detection. Breaks the container isolation guarantee. |
| (C) Privileged sidecar | ❌ Rejected | Adds inter-container communication complexity (shared volumes, Unix sockets). Two containers per job. Debugging is harder. Over-engineered for a single-purpose runner. |
| (D) systemd socket service | ❌ Rejected | Cleanest separation of concerns, but adds a persistent service (daemon management, logging, failure recovery), a custom RPC protocol, and the container must still reach the socket. Too many moving parts. |

**Implementation:** The hook wrapper checks for the existence of GPIO/UART devices on the host. If present, it adds them to the container spec via the `createOptions` field (which passes raw flags to `docker create`):

```
--device=/dev/gpiochip4
--device=/dev/ttyAMA0
--device=/dev/ttyAMA2
--device=/dev/ttyAMA3
--device=/dev/ttyAMA4
```

Additionally, the container needs the `--group-add` flag for the `gpio` and `dialout` groups (by GID) so the non-root container user can access the devices.

**Security note:** This is a single-purpose runner owned by Fortinbra. All workflows that target this runner are controlled by the repository owner. Device passthrough to all jobs is acceptable. If shared runner support is needed in the future, add label-based gating (check for a `gpio-access` job label in the hook wrapper).

### Architecture Decision 2: SWD Flashing via GPIO

**Decision: Flash all MCUs via SWD (Serial Wire Debug) using OpenOCD with the `linuxgpiod` interface.**

Each MCU gets 3 dedicated GPIO pins: SWDIO (data), SWCLK (clock), and RUN/RESET (active-low reset). Total: 12 GPIO pins for 4 MCUs.

**Why SWD over alternatives:**

| Approach | Verdict | Rationale |
|---|---|---|
| **(B) SWD via GPIO + OpenOCD** | ✅ **Chosen** | Everything routes through the 40-pin GPIO header — clean HAT design, no USB cables. OpenOCD's `linuxgpiod` adapter works on Pi 5's RP1-managed GPIO (`/dev/gpiochip4`). Supports RP2040 and RP2350 targets natively. Can flash ELF and BIN files directly to specific memory addresses. Programmatic reset after flashing. No BOOTSEL mode coordination. |
| (A) BOOTSEL + USB (UF2) | ❌ Rejected | Requires USB connections from each MCU to the Pi. Pi 5's 40-pin header has no USB data lines, so the HAT cannot route USB through the header — would need external cables or an on-HAT USB hub with a cable to a Pi USB-A port. Mechanically fragile. UF2 mount/copy is slower and harder to automate reliably (udev race conditions). |
| (C) picotool over USB | ❌ Rejected | Same USB routing problem as (A). picotool also requires the MCU to be in BOOTSEL mode for initial flash. |

**Flash sequence per MCU:**
1. Assert RESET (drive RUN pin low via GPIO)
2. Run OpenOCD with MCU-specific config (target, SWD pins, firmware path)
3. OpenOCD connects via SWD, halts core, flashes firmware, verifies
4. Release RESET (drive RUN pin high)
5. MCU boots into flashed firmware

**OpenOCD config pattern** (generated per MCU at runtime):
```tcl
adapter driver linuxgpiod
adapter gpio swdio {gpio_swdio}
adapter gpio swclk {gpio_swclk}
adapter speed 1000
transport select swd
source [find target/rp2040.cfg]   # or rp2350.cfg
program {firmware_path} verify reset exit
```

**Required packages in container image:** `openocd` (2:0.12+), `libgpiod2`, `gpiod` tools.

### Architecture Decision 3: UART Topology — 4 Hardware UARTs

**Decision: Dedicate one Pi 5 hardware UART per MCU, enabled via device tree overlays.**

The Pi 5's RP1 southbridge provides 6 PL011 UARTs (UART0–UART5). We use 4 of them:

| UART | Device Path | GPIO TX | GPIO RX | MCU | DT Overlay |
|---|---|---|---|---|---|
| UART0 | `/dev/ttyAMA0` | GPIO14 | GPIO15 | RP2040-0 | `uart0-pi5` (default) |
| UART2 | `/dev/ttyAMA2` | GPIO4 | GPIO5 | RP2040-1 | `uart2-pi5` |
| UART3 | `/dev/ttyAMA3` | GPIO8 | GPIO9 | RP2350B | `uart3-pi5` |
| UART4 | `/dev/ttyAMA4` | GPIO12 | GPIO13 | RP2350A | `uart4-pi5` |

**Why hardware UARTs over USB-UART adapters:**
- Deterministic device paths (`/dev/ttyAMA*` vs. non-deterministic `/dev/ttyUSB*`)
- No external hardware (adapters) needed — everything on the HAT PCB
- Lower latency, no USB stack overhead
- All PL011 UARTs — high quality, reliable at 115200 baud

**Baud rate: 115200 8N1** (per Wufei's UART Result Protocol spec in `docs/hardware/uart-result-protocol.md`). The action's `baud-rate` input allows override for specific test scenarios.

**Device tree configuration** (added to `/boot/firmware/config.txt` by setup script):
```
dtoverlay=uart2-pi5
dtoverlay=uart3-pi5
dtoverlay=uart4-pi5
```

UART0 is available by default when `enable_uart=1` is set.

**Result collection:** The action opens all target UART devices in parallel (one thread/process per MCU), parses the UART Result Protocol, and aggregates results. The protocol and output format are defined in `docs/hardware/uart-result-protocol.md` and `docs/hardware/github-output-format.md` (Wufei's specs).

### GPIO Pin Assignment

The complete GPIO interface contract between the Pi software and the HAT hardware:

| GPIO | Function | MCU | Signal | Direction | Notes |
|------|----------|-----|--------|-----------|-------|
| 0 | I2C0 SDA | — | HAT EEPROM | bidir | **RESERVED** — HAT+ ID EEPROM |
| 1 | I2C0 SCL | — | HAT EEPROM | bidir | **RESERVED** — HAT+ ID EEPROM |
| 2 | I2C1 SDA | — | — | — | Reserved for future expansion |
| 3 | I2C1 SCL | — | — | — | Reserved for future expansion |
| 4 | UART2 TX | RP2040-1 | Pi → MCU | output | Optional command channel |
| 5 | UART2 RX | RP2040-1 | MCU → Pi | input | Test result data |
| 6 | Output | RP2040-0 | Status LED | output | Optional debug indicator |
| 7 | Output | RP2040-1 | Status LED | output | Optional debug indicator |
| 8 | UART3 TX | RP2350B | Pi → MCU | output | Optional command channel |
| 9 | UART3 RX | RP2350B | MCU → Pi | input | Test result data |
| 10 | Output | RP2350B | Status LED | output | Optional debug indicator |
| 11 | Output | RP2350A | Status LED | output | Optional debug indicator |
| 12 | UART4 TX | RP2350A | Pi → MCU | output | Optional command channel |
| 13 | UART4 RX | RP2350A | MCU → Pi | input | Test result data |
| 14 | UART0 TX | RP2040-0 | Pi → MCU | output | Primary UART, optional cmd |
| 15 | UART0 RX | RP2040-0 | MCU → Pi | input | Test result data |
| 16 | SWD | RP2040-0 | SWDIO | bidir | OpenOCD data line |
| 17 | SWD | RP2040-0 | SWCLK | output | OpenOCD clock |
| 18 | Reset | RP2040-0 | RUN/RESET | output | Active-low, 10kΩ pull-up on HAT |
| 19 | SWD | RP2040-1 | SWDIO | bidir | OpenOCD data line |
| 20 | SWD | RP2040-1 | SWCLK | output | OpenOCD clock |
| 21 | Reset | RP2040-1 | RUN/RESET | output | Active-low, 10kΩ pull-up on HAT |
| 22 | SWD | RP2350B | SWDIO | bidir | OpenOCD data line |
| 23 | SWD | RP2350B | SWCLK | output | OpenOCD clock |
| 24 | Reset | RP2350B | RUN/RESET | output | Active-low, 10kΩ pull-up on HAT |
| 25 | SWD | RP2350A | SWDIO | bidir | OpenOCD data line |
| 26 | SWD | RP2350A | SWCLK | output | OpenOCD clock |
| 27 | Reset | RP2350A | RUN/RESET | output | Active-low, 10kΩ pull-up on HAT |

**Usage: 24 of 28 GPIO pins allocated. GPIO 2–3 reserved for future I2C1 expansion.**

### Action Interface (`action.yml`)

**Type:** Composite action (shell steps running inside the container with device access).

**Inputs:**

| Input | Required | Default | Description |
|---|---|---|---|
| `mcu-targets` | no | `all` | Comma-separated MCU list: `rp2040-0,rp2040-1,rp2350b,rp2350a` or `all` |
| `firmware-dir` | yes | — | Path to directory containing firmware files. Expected naming: `{mcu-id}.elf` (e.g., `rp2040-0.elf`) |
| `uart-timeout` | no | `30` | Seconds to wait for UART results per MCU (maps to `UART_INTER_LINE_TIMEOUT`) |
| `baud-rate` | no | `115200` | UART baud rate for all MCU connections |
| `flash-verify` | no | `true` | Verify firmware after flashing via SWD readback |
| `parallel-listen` | no | `true` | Listen on all UART ports simultaneously (false = sequential) |
| `rp2040-0-swdio` | no | `16` | GPIO pin for RP2040-0 SWDIO |
| `rp2040-0-swclk` | no | `17` | GPIO pin for RP2040-0 SWCLK |
| `rp2040-0-reset` | no | `18` | GPIO pin for RP2040-0 RUN/RESET |
| `rp2040-0-uart` | no | `/dev/ttyAMA0` | UART device for RP2040-0 |
| `rp2040-1-swdio` | no | `19` | GPIO pin for RP2040-1 SWDIO |
| `rp2040-1-swclk` | no | `20` | GPIO pin for RP2040-1 SWCLK |
| `rp2040-1-reset` | no | `21` | GPIO pin for RP2040-1 RUN/RESET |
| `rp2040-1-uart` | no | `/dev/ttyAMA2` | UART device for RP2040-1 |
| `rp2350b-swdio` | no | `22` | GPIO pin for RP2350B SWDIO |
| `rp2350b-swclk` | no | `23` | GPIO pin for RP2350B SWCLK |
| `rp2350b-reset` | no | `24` | GPIO pin for RP2350B RUN/RESET |
| `rp2350b-uart` | no | `/dev/ttyAMA3` | UART device for RP2350B |
| `rp2350a-swdio` | no | `25` | GPIO pin for RP2350A SWDIO |
| `rp2350a-swclk` | no | `26` | GPIO pin for RP2350A SWCLK |
| `rp2350a-reset` | no | `27` | GPIO pin for RP2350A RUN/RESET |
| `rp2350a-uart` | no | `/dev/ttyAMA4` | UART device for RP2350A |

**Outputs:**

| Output | Description |
|---|---|
| `results-json` | Full JSON string of all MCU test results (structured per Wufei's output format) |
| `passed` | Total number of MCUs where all tests passed |
| `failed` | Total number of MCUs with at least one failure or timeout |
| `total-tests` | Total individual test cases across all MCUs |
| `summary` | Human-readable one-liner, e.g., `3/4 MCUs passed (32 tests, 2 failures, 1 timeout)` |

**Workflow example:**
```yaml
jobs:
  hardware-test:
    runs-on: [self-hosted, performancenode]
    steps:
      - uses: actions/checkout@v4

      - name: Build test firmware
        run: |
          cd firmware && mkdir build && cd build
          cmake .. && make -j4

      - name: Flash and test MCUs
        id: mcu-test
        uses: ./.github/actions/mcu-flash-test
        with:
          mcu-targets: all
          firmware-dir: firmware/build/
          uart-timeout: 60

      - name: Check results
        if: steps.mcu-test.outputs.failed != '0'
        run: exit 1
```

### Implementation Components

| Component | Owner | Description |
|---|---|---|
| `scripts/setup/setup-gpio-uart.sh` | Heero | Idempotent host setup: enable DT overlays, configure GPIO permissions, install OpenOCD |
| `scripts/gpio/flash-mcu.sh` | Heero | Flash one MCU via SWD (called by the action per target) |
| `scripts/gpio/listen-uart.py` | Heero | UART listener implementing Wufei's protocol parser |
| `scripts/gpio/generate-openocd-cfg.sh` | Heero | Generate OpenOCD config files from pin assignments |
| Hook wrapper extension | Heero | Extend `cache-hook-wrapper.js` to inject device passthrough |
| `.github/actions/mcu-flash-test/action.yml` | Heero | Composite action orchestrating flash + listen + report |
| UART result protocol | Wufei | Already defined: `docs/hardware/uart-result-protocol.md` |
| GitHub summary format | Wufei | Already defined: `docs/hardware/github-output-format.md` |

## Acceptance Criteria

- [ ] RP2040-0 flashes successfully via SWD from a GitHub Actions workflow step
- [ ] RP2040-1 flashes successfully via SWD from the same workflow
- [ ] RP2350B flashes successfully via SWD from the same workflow
- [ ] RP2350A flashes successfully via SWD from the same workflow
- [ ] UART test results from all 4 MCUs are captured and parsed correctly
- [ ] Results appear in the GitHub Actions step summary matching Wufei's output format
- [ ] UART timeout produces a `⚠️ Timed out` result for that MCU — not a crash or hung step
- [ ] A single MCU failure does not prevent other MCUs from being flashed and tested
- [ ] The `results-json` output contains valid JSON parseable by downstream steps
- [ ] The `summary` output contains a human-readable one-liner with pass/fail counts
- [ ] GPIO and UART devices (`/dev/gpiochip4`, `/dev/ttyAMA*`) are accessible inside the job container
- [ ] The action works with `mcu-targets: rp2040-0` (single MCU) and `mcu-targets: all` (all MCUs)
- [ ] Pin assignments are configurable via action inputs (not hardcoded)
- [ ] The setup script (`setup-gpio-uart.sh`) is idempotent — running it twice produces no errors
- [ ] Device tree overlays for UART2–4 are enabled in `/boot/firmware/config.txt` after setup
- [ ] OpenOCD `linuxgpiod` adapter can connect to each MCU's SWD port from inside the container
- [ ] Flash verification (SWD readback) detects corrupted firmware and reports failure
- [ ] Status LEDs (GPIO 6, 7, 10, 11) toggle during flash/test if physically present

## Out of Scope

- **HAT PCB design** — this spec defines the software interface contract; hardware design is Fortinbra's domain
- **MCU test firmware development** — firmware content is not part of this spec; we define the flashing and result collection mechanism
- **Specific test content** — which tests run on which MCU is determined by the firmware, not this action
- **USB-based flashing** — explicitly rejected in favor of SWD via GPIO
- **Multi-HAT support** — this spec targets a single HAT with 4 MCUs; scaling to multiple HATs is future work
- **UART protocol definition** — already defined by Wufei in `docs/hardware/uart-result-protocol.md`
- **GitHub summary format** — already defined by Wufei in `docs/hardware/github-output-format.md`
- **Firmware build system** — building firmware is a separate workflow concern; this action consumes pre-built ELF/BIN files
- **Analog/power monitoring** — no ADC or power measurement from the Pi side

## Dependencies

- **Spec 0001** (`0001-pi5-base-setup.md`) — Pi must be set up as a runner with Docker and container hooks
- **Spec 0002** (`0002-dependency-caching.md`) — Hook wrapper infrastructure (`cache-hook-wrapper.js`) that we extend
- **Wufei's UART Result Protocol** (`docs/hardware/uart-result-protocol.md`) — wire format for MCU→Pi results
- **Wufei's GitHub Output Format** (`docs/hardware/github-output-format.md`) — step summary rendering
- **HAT Hardware** — physical HAT must be fabricated per `docs/hardware/hat-design-contract.md`

## Agent Assignment

| Agent  | Role in this spec |
|--------|-------------------|
| Heero  | Primary implementer — setup script, flash scripts, UART listener, hook wrapper extension, composite action |
| Wufei  | Result format owner — UART protocol and GitHub summary format (already delivered, available for refinement) |
| Noin   | Validation — test on real hardware, verify acceptance criteria, test timeout/failure edge cases |
| Treize | Architecture review, HAT design contract, integration oversight |

## Notes

- **Pi 5 GPIO chip:** On Pi 5, the main 28-pin GPIO header is managed by the RP1 southbridge chip and exposed as `/dev/gpiochip4` (not `/dev/gpiochip0` as on Pi 4). All scripts and container device passthrough must use the correct chip number. Verify with `gpiodetect` on the actual hardware.
- **OpenOCD Pi 5 support:** The `linuxgpiod` adapter in OpenOCD ≥ 0.12 works with any Linux GPIO character device, including Pi 5's RP1-managed GPIO. Do NOT use the `bcm2835gpio` adapter — it uses direct memory-mapped I/O that doesn't work on Pi 5.
- **SWD speed:** Start at `adapter speed 1000` (1 MHz). Bit-banged SWD through RP1 may have timing constraints. If flash failures occur, reduce to 500 kHz. If reliable, increase to 2000 kHz for faster flashing.
- **RP2350 OpenOCD target:** As of 2026, RP2350 support in OpenOCD may require the Raspberry Pi fork (`openocd-rp2350`). Heero should verify mainline support and fall back to the fork if needed.
- **GPIO pin table:** The full pin assignment is the authoritative HAT design contract. See also `docs/hardware/hat-design-contract.md`.
- **Container image:** The action's container image must include: `openocd`, `libgpiod2`, `gpiod`, `python3`, `python3-serial` (pyserial). This can be a custom Docker image (`performancenode/mcu-test:<version>`) or installed at action runtime.
- **Parallel vs. sequential:** The default `parallel-listen: true` opens all UART ports simultaneously. This is important because MCUs boot and run tests independently after flashing. Sequential listening would add unnecessary delay.
- **UART1 intentionally skipped:** UART1 on Pi 5 may conflict with Bluetooth on some configurations. Using UART0, 2, 3, 4 avoids any potential conflict.
