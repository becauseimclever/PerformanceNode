# HAT Design Contract

**Version:** 1.0  
**Status:** Draft  
**Owner:** Treize (software interface) / Fortinbra (hardware design)  
**Last Updated:** 2026-04-11

---

## Purpose

This document is the **interface specification** between the PerformanceNode software (this repo) and the custom MCU test HAT that Fortinbra is designing. It defines what the HAT hardware MUST provide so that the software can flash firmware and collect test results.

The software side will not change its GPIO assignments, UART configuration, or device expectations without updating this document first. Likewise, the HAT design should treat this document as the definitive pin contract.

---

## HAT Overview

| Property | Value |
|---|---|
| Form factor | Raspberry Pi HAT+ (follows Pi 5 mechanical spec) |
| Host | Raspberry Pi 5 (BCM2712, RP1 southbridge) |
| MCU count | 4 |
| MCU types | 1× RP2040 (harness, UART), 1× RP2040 (DUT, SWD+RESET), 1× RP2350B (DUT, SWD+RESET), 1× RP2350A (DUT, SWD+RESET) |
| Connection | 40-pin GPIO header (all signals route through header) |
| USB | None required — all flashing via SWD, results via single UART from harness MCU |
| UART topology | **One UART only** — harness RP2040 (RP2040-H) has dedicated UART TX/RX back to Pi. DUT MCUs communicate test results through the harness MCU. |

---

## Required Connections Per MCU

Each MCU on the HAT MUST expose the following signals to the Pi via the 40-pin GPIO header:

### SWD (Serial Wire Debug) — for firmware flashing

| Signal | Description | Electrical | Required |
|---|---|---|---|
| SWDIO | SWD data (bidirectional) | 3.3V logic, series 100Ω resistor recommended | **YES** |
| SWCLK | SWD clock (Pi → MCU) | 3.3V logic, series 100Ω resistor recommended | **YES** |

**Notes:**
- Each MCU has its own dedicated SWDIO and SWCLK lines (no sharing/multiplexing).
- The Pi drives SWD at up to 2 MHz via bit-banged GPIO (OpenOCD `linuxgpiod` adapter). PCB traces should be kept short (< 5 cm) and impedance-controlled is not required at this speed.
- Series resistors (100Ω) on SWDIO and SWCLK between Pi GPIO and MCU SWD pads protect against drive conflicts during reset.

### RUN/RESET — for MCU reset control

| Signal | Description | Electrical | Required |
|---|---|---|---|
| RUN/RESET | Active-low reset | Open-drain from Pi, 10kΩ pull-up to 3.3V on HAT | **YES** |

**Notes:**
- The Pi drives this pin LOW to hold the MCU in reset, then releases (high-Z) to let the pull-up bring it HIGH for normal operation.
- The 10kΩ pull-up resistor MUST be on the HAT, not on the Pi side.
- RP2040: Connect to the `RUN` pin (active-low reset).
- RP2350A/B: Connect to the `RUN` pin (same behavior as RP2040).

### UART — for test result reporting (Harness MCU only)

| Signal | Description | Electrical | Required | Notes |
|---|---|---|---|---|
| UART TX → Pi RX | Harness MCU transmits test results from all 4 MCUs to Pi | 3.3V logic | **YES** | Only one UART total, from harness RP2040 |
| UART RX ← Pi TX | Pi transmits to harness MCU (optional command channel) | 3.3V logic | Recommended | For future command/control |

**UART Design Notes:**
- **Only the harness MCU (RP2040-H) has direct UART connection to the Pi.** The 3 DUT MCUs (RP2040-D, RP2350B, RP2350A) do NOT connect to the Pi directly.
- Test results from DUT MCUs route through the harness MCU via an inter-MCU communication channel (SPI or UART) defined in the MCU test firmware.
- The harness MCU aggregates results and transmits them as a single unified report over its UART TX line.
- Flow control (RTS/CTS) is NOT required.
- The UART result protocol is defined in `docs/hardware/uart-result-protocol.md` and describes the wire format for the aggregated report.
- Baud rate: **115200 8N1**

---

## GPIO Pin Assignments — Final

The following table is the definitive pin assignment. The HAT PCB must route these signals accordingly.

### MCU Roles

| MCU Label | Device Type | Role | UART | SWD | RESET |
|---|---|---|---|---|---|
| RP2040-H (Harness) | RP2040 | Test harness — coordinates flashing, aggregates results, sends to Pi | ✅ | ✅ | ✅ |
| RP2040-D (DUT) | RP2040 | Device under test — runs firmware, communicates via inter-MCU link | ❌ | ✅ | ✅ |
| RP2350B (DUT) | RP2350B | Device under test — runs firmware, communicates via inter-MCU link | ❌ | ✅ | ✅ |
| RP2350A (DUT) | RP2350A | Device under test — runs firmware, communicates via inter-MCU link | ❌ | ✅ | ✅ |

### Pin Map (BCM GPIO numbering)

| GPIO | Pin# (header) | Function | MCU | Signal | Direction (Pi perspective) | Notes |
|------|---------------|----------|-----|--------|---------------------------|-------|
| 0 | 27 | I2C0 SDA | — | HAT EEPROM | bidirectional | **RESERVED** — HAT+ ID EEPROM |
| 1 | 28 | I2C0 SCL | — | HAT EEPROM | bidirectional | **RESERVED** — HAT+ ID EEPROM |
| 2 | 3 | Reserved | — | (I2C1 SDA) | — | Future expansion |
| 3 | 5 | Reserved | — | (I2C1 SCL) | — | Future expansion |
| 4 | 7 | UART TX | RP2040-H | Pi → MCU | output | Harness UART (optional command) |
| 5 | 29 | UART RX | RP2040-H | MCU → Pi | input | Harness UART (aggregated results) |
| 6 | 31 | Status LED | RP2040-H | LED anode | output | Optional — harness status |
| 7 | 26 | Status LED | RP2040-D | LED anode | output | Optional — DUT status |
| 8 | 24 | Status LED | RP2350B | LED anode | output | Optional — DUT status |
| 9 | 21 | Status LED | RP2350A | LED anode | output | Optional — DUT status |
| 10–15 | — | (unused) | — | — | — | Available for future use |
| 16 | 36 | SWD | RP2040-H | SWDIO | bidirectional | Harness SWD data |
| 17 | 11 | SWD | RP2040-H | SWCLK | output | Harness SWD clock |
| 18 | 12 | Reset | RP2040-H | RUN/RESET | output (open-drain) | Active-low, 10kΩ pull-up on HAT |
| 19 | 35 | SWD | RP2040-D | SWDIO | bidirectional | DUT SWD data |
| 20 | 38 | SWD | RP2040-D | SWCLK | output | DUT SWD clock |
| 21 | 40 | Reset | RP2040-D | RUN/RESET | output (open-drain) | Active-low, 10kΩ pull-up on HAT |
| 22 | 15 | SWD | RP2350B | SWDIO | bidirectional | DUT SWD data |
| 23 | 16 | SWD | RP2350B | SWCLK | output | DUT SWD clock |
| 24 | 18 | Reset | RP2350B | RUN/RESET | output (open-drain) | Active-low, 10kΩ pull-up on HAT |
| 25 | 22 | SWD | RP2350A | SWDIO | bidirectional | DUT SWD data |
| 26 | 37 | SWD | RP2350A | SWCLK | output | DUT SWD clock |
| 27 | 13 | Reset | RP2350A | RUN/RESET | output (open-drain) | Active-low, 10kΩ pull-up on HAT |

### Power Pins Used

| Pin# (header) | Signal | Usage | Voltage |
|---|---|---|---|
| 1 | 3.3V | MCU power supply (all 4 MCUs) | 3.3V |
| 2, 4 | 5V | HAT optional secondary supply | 5V |
| 6, 9, 14, 20, 25, 30, 34, 39 | GND | Ground reference — use multiple ground pins for signal integrity | 0V (reference) |

---

## Power Requirements

### Voltage Levels

| Signal Type | Voltage | Notes |
|---|---|---|
| GPIO logic (all signals) | **3.3V** | Pi 5 GPIO is 3.3V. RP2040 and RP2350 are 3.3V native. **No level shifting required.** |
| MCU power (IOVDD, DVDD) | **3.3V** | RP2040/RP2350 core voltage is 1.1V (internal regulator from 3.3V input) |
| HAT power input | **5V or 3.3V** | From Pi header. See current budget below. |

### Current Budget

| Component | Estimated Current (3.3V) | Notes |
|---|---|---|
| RP2040 (Harness) × 1 | 25 mA typical | Dual-core at 125 MHz, no WiFi, coordinates flashing & results |
| RP2040 (DUT) × 1 | 25 mA typical | Dual-core at 125 MHz, runs test firmware |
| RP2350B (DUT) × 1 | 35 mA typical | Quad-core capable, higher than RP2040, runs test firmware |
| RP2350A (DUT) × 1 | 30 mA typical | Dual-core ARM variant, runs test firmware |
| Status LEDs × 4 | 4 × 5 mA = 20 mA | With current-limiting resistors |
| Miscellaneous (EEPROM, passives) | 5 mA | |
| **Total** | **~140 mA** | Well within Pi 5's 3.3V rail capacity (~800 mA) |

**Recommendation:** Power all MCUs from the Pi's 3.3V rail via the GPIO header. The total current draw (~140 mA) is well within the Pi 5's 3.3V regulator capacity. No separate power supply or 5V-to-3.3V regulation needed on the HAT.

---

## HAT ID EEPROM

Per the [Raspberry Pi HAT+ specification](https://github.com/raspberrypi/hats), the HAT MUST include an ID EEPROM:

| Requirement | Value |
|---|---|
| EEPROM IC | CAT24C32 or equivalent (32 Kbit I2C EEPROM) |
| I2C bus | I2C0 (GPIO0 = SDA, GPIO1 = SCL) |
| I2C address | `0x50` (standard HAT EEPROM address) |
| Write protect | WP pin tied HIGH after programming (read-only in operation) |
| Contents | HAT+ identification data (vendor, product, GPIO map) |

**Programming:** The EEPROM should be programmed during HAT manufacturing using the Raspberry Pi `eepmake` tool with the GPIO map from this document.

**Note:** GPIO0 and GPIO1 are RESERVED for the EEPROM and must not be used for any MCU signals.

---

## Mechanical Constraints

| Constraint | Specification |
|---|---|
| Board dimensions | Pi HAT+ standard: 65mm × 56.5mm (matching Pi 5 board outline) |
| Mounting holes | 4× M2.5, matching Pi 5 mounting hole positions |
| Connector | 2×20 pin header socket (mate with Pi 5's 40-pin GPIO header) |
| Standoff height | 10mm minimum between Pi PCB and HAT PCB (standard HAT standoff) |
| Component height | Max 12mm above HAT PCB top surface (to allow stacking or case fit) |
| MCU placement | All 4 MCUs on the HAT PCB — no daughter boards or breakouts |
| Silkscreen | Label each MCU position (RP2040-0, RP2040-1, RP2350B, RP2350A) |

**Thermal note:** The Pi 5 uses an active cooler (fan + heatsink) on top of the SoC. The HAT sits above the GPIO header on the opposite side from the SoC. Ensure HAT components do not interfere with the Pi 5's official active cooler or case.

---

## PCB Design Recommendations

### Signal Routing

1. **SWD traces:** Keep SWDIO and SWCLK traces short (< 5 cm from GPIO header to MCU SWD pads). Route as paired traces where possible. No impedance control needed at 1–2 MHz.

2. **UART traces:** Route MCU UART TX directly to the corresponding Pi UART RX GPIO pad. Keep traces short. No termination needed at 115200 baud.

3. **Reset lines:** Route from GPIO header to MCU RUN pin. Place 10kΩ pull-up resistor close to the MCU RUN pin.

4. **Ground plane:** Use a solid ground plane on one PCB layer. Connect to multiple header GND pins (at least pins 6, 9, 14, 20).

5. **Decoupling:** Place 100nF ceramic capacitor at each MCU's power pins. Place 10µF bulk capacitor near the 3.3V power input from the header.

### Status LEDs

4 optional status LEDs (one per MCU) are driven from GPIO 6–9:

| GPIO | LED | MCU | Current-limit Resistor |
|---|---|---|---|
| 6 | Harness status | RP2040-H | 330Ω (for ~5 mA at 3.3V with typical LED Vf=1.65V) |
| 7 | DUT status | RP2040-D | 330Ω |
| 8 | DUT status | RP2350B | 330Ω |
| 9 | DUT status | RP2350A | 330Ω |

LEDs are active-high: Pi GPIO HIGH = LED on, LOW = LED off.

**Recommended LED color:** Green for all (uniform appearance). Use 0603 or 0805 SMD LEDs.

### Crystal Oscillators

Each RP2040 requires a 12 MHz crystal (±30 ppm). Each RP2350 requires a 12 MHz crystal (±30 ppm). Place crystals close to their respective MCU XOSC pins with appropriate load capacitors per the RP2040/RP2350 hardware design guides.

### USB (NOT REQUIRED)

The software architecture uses SWD for flashing — USB connections from MCUs to the Pi are NOT required. If the HAT includes USB connections for debug convenience, they are optional and not part of this contract.

---

## Test Points

The HAT SHOULD include test points for debugging:

| Test Point | Signal | Purpose |
|---|---|---|
| TP1–TP4 | SWDIO per MCU | Probe SWD data during debug |
| TP5–TP8 | UART TX per MCU | Probe UART output |
| TP9 | 3.3V power | Verify power rail |
| TP10 | GND | Ground reference for probes |

---

## Revision History

| Version | Date | Author | Changes |
|---|---|---|---|
| 2.0 | 2026-04-11 | Treize | **Finalized MCU topology:** Single UART from harness RP2040 only. DUT MCUs communicate results through harness. Simplified GPIO allocation (12 GPIO for SWD/RESET + 2 for UART + 4 for LEDs = 18 pins total; 10 pins available). Clarified harness vs. DUT roles. |
| 1.0 | 2026-04-11 | Treize | Initial HAT design contract |
