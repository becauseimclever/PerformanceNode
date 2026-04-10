# Decision: GPIO MCU Flash & Test Architecture

**Date:** 2026-04-11  
**By:** Treize (Lead)  
**Spec:** `docs/specs/0006-gpio-mcu-flash-test-action.md`  
**HAT Contract:** `docs/hardware/hat-design-contract.md`

---

## Context

Fortinbra is designing a custom HAT for the Pi 5 with 4 MCUs (2× RP2040, 1× RP2350B, 1× RP2350A). The PerformanceNode runner needs to flash firmware to these MCUs and collect test results over UART — all from within GitHub Actions workflows where every job runs in a disposable Docker container.

Three critical architectural decisions were required:

---

## Decision 1: Container Device Passthrough via Hook Wrapper

**Choice:** Extend the existing `cache-hook-wrapper.js` to inject `--device` flags for GPIO and UART devices into every job container.

**Rejected alternatives:**
- Host step bypass — not a standard feature of `@actions/runner-container-hooks`, requires forking
- Privileged sidecar — adds inter-container communication complexity
- systemd socket service — too many moving parts (daemon, RPC protocol, socket access)

**Rationale:** The hook wrapper already intercepts `prepare_job` to inject cache bind mounts. Adding `--device=/dev/gpiochip4 --device=/dev/ttyAMA0` (etc.) is a natural, minimal extension. No new services, no special workflow syntax, no privileged containers. The container gets device access transparently. Tools like OpenOCD and pyserial work identically to host execution.

**Implication:** Single-purpose runner security model — all jobs get device access. If shared runner support is needed later, add label-based gating in the hook wrapper.

---

## Decision 2: SWD Flashing via GPIO with OpenOCD

**Choice:** Flash all 4 MCUs via SWD (Serial Wire Debug) using OpenOCD with the `linuxgpiod` adapter. Each MCU gets 3 GPIO pins: SWDIO, SWCLK, RUN/RESET.

**Rejected alternatives:**
- BOOTSEL + USB — requires USB connections that can't route through the 40-pin header; needs external cables or on-HAT USB hub
- picotool over USB — same USB routing problem

**Rationale:** SWD via GPIO routes everything through the 40-pin header for a clean HAT design. The `linuxgpiod` adapter works on Pi 5's RP1-managed GPIO (unlike `bcm2835gpio` which uses direct memory-mapped I/O). Supports both RP2040 and RP2350 targets. Can flash ELF/BIN directly, verify via readback, and reset MCUs programmatically.

**Total GPIO for SWD + RESET:** 4 MCUs × 3 pins = 12 GPIO pins.

---

## Decision 3: 4 Dedicated Hardware UARTs

**Choice:** One Pi 5 hardware PL011 UART per MCU, enabled via device tree overlays.

| MCU | UART | Device | GPIO RX |
|---|---|---|---|
| RP2040-0 | UART0 | `/dev/ttyAMA0` | GPIO15 |
| RP2040-1 | UART2 | `/dev/ttyAMA2` | GPIO5 |
| RP2350B | UART3 | `/dev/ttyAMA3` | GPIO9 |
| RP2350A | UART4 | `/dev/ttyAMA4` | GPIO13 |

UART1 intentionally skipped (potential Bluetooth conflict on some configurations).

**Rationale:** Hardware UARTs give deterministic device paths (`/dev/ttyAMA*`), no external adapters, no USB stack overhead, and reliable 115200 baud operation. All UARTs are PL011 quality. The Pi 5's RP1 chip provides 6 UARTs — using 4 is comfortable.

**Baud rate:** 115200 8N1, per Wufei's UART Result Protocol specification.

---

## GPIO Budget

Total GPIO pins allocated: **24 of 28**
- 2 reserved (GPIO 0–1: HAT EEPROM I2C0)
- 2 reserved for expansion (GPIO 2–3: I2C1)
- 8 for UART (TX+RX × 4 MCUs)
- 12 for SWD + RESET (3 pins × 4 MCUs)
- 4 for status LEDs (optional, GPIO 6, 7, 10, 11)

---

## Delegation

| Agent | Task |
|---|---|
| **Heero** | Implement setup script, flash scripts, UART listener, hook wrapper extension, composite action |
| **Wufei** | UART protocol and GitHub summary format (already delivered — `docs/hardware/uart-result-protocol.md`, `docs/hardware/github-output-format.md`) |
| **Noin** | Validate on real hardware, test timeout/failure edge cases, verify acceptance criteria |
| **Fortinbra** | HAT PCB design per `docs/hardware/hat-design-contract.md` |

---

## Open Items

1. **Verify Pi 5 GPIO chip number:** Expected `/dev/gpiochip4` but must confirm on actual hardware with `gpiodetect`.
2. **OpenOCD RP2350 support:** Mainline OpenOCD may not yet support RP2350. Raspberry Pi's OpenOCD fork may be needed.
3. **SWD speed tuning:** Start at 1 MHz, optimize after hardware testing.
4. **Container image for MCU tools:** Need a Docker image with OpenOCD, libgpiod, and pyserial. Decide whether to bake into a `performancenode/mcu-test` image or install at action runtime.
