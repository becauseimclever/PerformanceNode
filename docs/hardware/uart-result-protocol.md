# UART Result Protocol Specification

**Version:** 1.0 (Single-Stream Topology)  
**Status:** Active  
**Owner:** Wufei (Performance Engineer)  
**Consumers:** MCU firmware developers (RP2040, RP2350A, RP2350B), harness aggregator, Pi parser (`parse-results.py`)

---

## Overview

The UART Result Protocol is the wire contract between the harness RP2040 MCU and the Raspberry Pi 5
host parser. The **harness RP2040** (a supervisor MCU on the custom HAT) aggregates test results from
all three DUT MCUs (2× RP2040, 1× RP2350A, 1× RP2350B) via on-HAT wiring and reports them to the Pi
over **a single UART connection**.

The Pi sees **one serial stream** from **one device** (e.g. `/dev/ttyAMA2`). The three DUT MCUs do
**not** have direct UART connections to the Pi; they communicate only with the harness MCU.

The protocol is **line-based ASCII text**. Every result is a single terminated line. It is
intentionally simple so that a firmware developer can verify output with any serial monitor
(e.g. `minicom`, `screen`, `picocom`) without tooling.

---

## Physical Layer

### Baud Rate

**Recommended: 115200 baud, 8N1 (8 data bits, no parity, 1 stop bit).**

Rationale:
- 115200 baud gives ~11.5 KB/s throughput. A single test run with 200 test lines of 80 chars
  each transmits in under 140 ms — negligible compared to test execution time.
- 115200 is universally supported by RP2040/RP2350 UART hardware without fractional divider
  edge cases that can cause bit errors at higher rates (e.g. 460800 on a 125 MHz system clock).
- Higher baud rates (e.g. 921600) save only milliseconds while meaningfully increasing
  susceptibility to noise on the HAT PCB traces.
- The Pi 5's PL011 UART handles 115200 reliably with the default overlay configuration.

**Do not use 9600 baud.** A 200-line run at 9600 baud takes ~1.7 seconds just for transmission —
unacceptably long for a fast unit-test harness.

### Wiring

The harness RP2040 UART TX line connects to a single Pi 5 UART RX line (device path: `/dev/ttyAMA*`,
exact pin assignment TBD by Treize in `docs/hardware/hat-design-contract.md`).

The three DUT MCUs (RP2040-0, RP2350A, RP2350B) communicate test results to the harness MCU via
on-HAT connections (SPI, I2C, or dedicated inter-MCU UART). The harness MCU multiplexes these
results into a single stream before sending to the Pi.

Flow control (RTS/CTS) is **not required** and should be left disabled; the line-based protocol
self-paces via test execution time.

---

## Encoding and Framing

| Property | Value |
|---|---|
| Character encoding | **ASCII only** (bytes 0x20–0x7E, plus CR `0x0D` and LF `0x0A`) |
| Line ending | **LF (`\n`, 0x0A)** — do not send bare CR |
| Maximum line length | **256 bytes** including the terminating LF |
| Minimum line length | 3 bytes (message type code + space + at least one field) |

**Rationale for LF-only:** CRLF is safe but wastes one byte per line and requires parsers to
strip `\r`. LF-only is standard in Unix environments and is what `readline()` in Python returns
without stripping needed. If MCU USB CDC stacks force CRLF, the parser MUST strip trailing `\r`
before parsing.

**ASCII-only rationale:** Avoids encoding bugs on MCU toolchains and ensures terminal readability
everywhere. Test names and messages containing non-ASCII characters MUST use `\xHH` escape
sequences (see §Escape Rules).

---

## Message Format

Every line follows this grammar:

```
<TYPE> <field1> [<field2> ...] LF
```

- `<TYPE>` is a fixed keyword (see §Message Types).
- Fields are separated by a **single space** (0x20).
- Fields that can contain spaces (strings) are **colon-prefixed and last** — they consume the
  remainder of the line after the colon (see §Field Conventions).
- Leading/trailing whitespace on a line is invalid; the parser MUST reject it in strict mode.

### Field Conventions

| Notation | Meaning |
|---|---|
| `<name>` | Required field |
| `[name]` | Optional field |
| `<string:…>` | Free-text field — always the last field, preceded by a colon |
| `<int>` | Unsigned decimal integer, no leading zeros (except `0` itself) |
| `<float>` | Decimal number, period as separator, 1–6 decimal places |
| `<id>` | Alphanumeric + hyphens/underscores, no spaces, max 64 chars |

---

## Message Types

### `TEST_START`

Signals the beginning of a test run on one DUT MCU (reported by the harness).

```
TEST_START mcu=<id> fw=<version> tests=<int>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | One of: `rp2040-0`, `rp2040-1`, `rp2350a`, `rp2350b` | **DUT MCU identifier** — identifies which of the three DUT MCUs is reporting |
| `fw` | `<id>` | Semver string, e.g. `1.2.3` | Firmware version of the DUT MCU |
| `tests` | `<int>` | 0–65535 | Number of tests that will run on this DUT (0 = unknown) |

**Parser action:** Open a new test-run context for this DUT MCU. Reset pass/fail/skip counters. If
a context already exists (duplicate `TEST_START` without `TEST_END`), emit a protocol warning and
start a fresh context.

**Harness responsibility:** The harness MCU MUST identify the source DUT MCU via the `mcu` field
so the Pi parser can correctly attribute all subsequent test results (PASS, FAIL, SKIP, METRIC,
LOG) until the corresponding `TEST_END` arrives.

**Example:**
```
TEST_START mcu=rp2350b fw=0.4.1 tests=12
```

---

### `PASS`

A single test case passed (reported by the harness on behalf of a DUT MCU).

```
PASS mcu=<id> <test_id> duration_us=<int>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | One of: `rp2040-0`, `rp2040-1`, `rp2350a`, `rp2350b` | **DUT MCU identifier** — which MCU this result came from |
| `<test_id>` | `<id>` | Max 64 chars | Unique name/identifier for the test on that DUT |
| `duration_us` | `<int>` | ≥ 0 | Wall-clock time for the test, in **microseconds** |

**Parser action:** Increment pass counter for this DUT MCU. Record test name and duration.

**Note:** The `mcu` field is **required** so the parser can correctly route the result to the
right DUT's context, even though a `TEST_START mcu=...` was received earlier. This allows the
harness to interleave results from multiple DUTs if needed (though sequential per-DUT streams
are recommended for firmware simplicity).

**Example:**
```
PASS mcu=rp2350b gpio_toggle_1mhz duration_us=14823
```

---

### `FAIL`

A single test case failed (reported by the harness on behalf of a DUT MCU).

```
FAIL mcu=<id> <test_id> duration_us=<int> msg:<message>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | One of: `rp2040-0`, `rp2040-1`, `rp2350a`, `rp2350b` | **DUT MCU identifier** — which MCU this result came from |
| `<test_id>` | `<id>` | Max 64 chars | Unique name/identifier for the test on that DUT |
| `duration_us` | `<int>` | ≥ 0 | Wall-clock time for the test, in microseconds |
| `msg:` | free text | Max 180 chars after colon | Human-readable failure description |

**Parser action:** Increment fail counter for this DUT MCU. Record test name, duration, and
message. The message field begins after the literal `msg:` token (no space between colon and
message body). If `msg:` is absent, treat message as empty string.

**Note:** Like PASS, the `mcu` field is **required** to disambiguate results from different DUTs.

**Example:**
```
FAIL mcu=rp2350a spi_loopback_stress duration_us=501234 msg:expected 0xFF got 0xA3 after 4096 bytes
```

---

### `SKIP`

A test case was intentionally skipped (reported by the harness on behalf of a DUT MCU).

```
SKIP mcu=<id> <test_id> reason:<reason>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | One of: `rp2040-0`, `rp2040-1`, `rp2350a`, `rp2350b` | **DUT MCU identifier** — which MCU this result came from |
| `<test_id>` | `<id>` | Max 64 chars | Unique name/identifier for the test on that DUT |
| `reason:` | free text | Max 180 chars after colon | Why the test was skipped |

**Parser action:** Increment skip counter for this DUT MCU. Record test name and reason.

**Note:** Like PASS and FAIL, the `mcu` field is **required** to route the result to the correct DUT context.

**Example:**
```
SKIP mcu=rp2040-1 dma_burst_4k reason:requires external PSRAM not present on this board
```

---

### `METRIC`

A performance measurement from a DUT MCU (reported by the harness).
May appear at any point after the corresponding `TEST_START` and before `TEST_END`.
Multiple `METRIC` lines with the same name are permitted (e.g. repeated sampling).

```
METRIC mcu=<id> <name> value=<float> unit=<id>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | One of: `rp2040-0`, `rp2040-1`, `rp2350a`, `rp2350b` | **DUT MCU identifier** — which MCU generated this measurement |
| `<name>` | `<id>` | Max 64 chars | Metric identifier, e.g. `isr_latency_min_us` |
| `value` | `<float>` | Any finite decimal | Measured value |
| `unit` | `<id>` | Max 16 chars | SI unit or custom label — see table below |

**Recommended unit identifiers:**

| Unit string | Meaning |
|---|---|
| `us` | Microseconds |
| `ms` | Milliseconds |
| `s` | Seconds |
| `Hz` | Hertz |
| `kHz` | Kilohertz |
| `MHz` | Megahertz |
| `bytes` | Byte count |
| `KB` | Kibibytes |
| `pct` | Percentage |
| `cycles` | CPU cycles |
| `count` | Dimensionless count |

**Parser action:** Collect metric into a list associated with this DUT MCU. Metrics are not
pass/fail — they are reported separately in the GitHub Summary as a performance table.

**Note:** The `mcu` field is **required** to route the metric to the correct DUT context.

**Example:**
```
METRIC mcu=rp2040-0 isr_latency_min_us value=0.83 unit=us
METRIC mcu=rp2040-0 isr_latency_max_us value=2.41 unit=us
METRIC mcu=rp2040-0 uart_throughput value=115.1 unit=kHz
```

---

### `LOG`

An optional diagnostic message from a DUT MCU (reported by the harness).
Not a test result. Useful for debug traces that should appear in raw captures but be ignored
(or filtered) by the parser.

```
LOG mcu=<id> msg:<message>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | One of: `rp2040-0`, `rp2040-1`, `rp2350a`, `rp2350b` | **DUT MCU identifier** — which MCU generated this log |
| `msg:` | free text | Max 200 chars after colon | Diagnostic message |

**Parser action (normal mode):** Record the log line; include in a diagnostics section of the
output but do not affect pass/fail/skip counts.

**Parser action (strict mode):** Reject the line as a protocol violation and emit a warning with
the line number. `LOG` lines indicate firmware is sending diagnostic noise on the result channel;
strict mode enforces clean separation.

**Note:** The `mcu` field is **required** to track which DUT generated the log message.

**Example:**
```
LOG mcu=rp2350a msg:calibrating ADC reference voltage, please wait
```

---

### `TEST_END`

Signals the end of the test run on a DUT MCU (reported by the harness).
Must be the final message for that DUT's run.

```
TEST_END mcu=<id> passed=<int> failed=<int> skipped=<int> duration_us=<int>
```

| Field | Type | Constraints | Description |
|---|---|---|---|
| `mcu` | `<id>` | Must match the `TEST_START` `mcu` value for this run | DUT MCU identifier |
| `passed` | `<int>` | ≥ 0 | Total passed tests (must match parser's running count for this DUT) |
| `failed` | `<int>` | ≥ 0 | Total failed tests |
| `skipped` | `<int>` | ≥ 0 | Total skipped tests |
| `duration_us` | `<int>` | ≥ 0 | Total elapsed time for the entire test run on this DUT |

**Parser action:** Finalize the DUT MCU's test context. If the parser's running counts do not
match the reported counts, emit a protocol warning (counts mismatch). Mark the run complete for
this DUT. Stop the timeout watchdog for this DUT.

**Example:**
```
TEST_END mcu=rp2350b passed=11 failed=1 skipped=0 duration_us=2847392
```

---

## Timeout, Crash, and Hung Detection

The Pi parser starts a **per-DUT timeout watchdog** when `TEST_START` is received for that DUT.
The watchdog is reset on every received line **from that DUT**. It is cancelled when `TEST_END`
is received for that DUT.

| Condition | How detected | Parser classification |
|---|---|---|
| **Normal completion** | `TEST_END` received within timeout | ✅ Run complete |
| **Timeout** | No line received for ≥ `INTER_LINE_TIMEOUT` (default: 30 s) for a DUT | ⚠️ Timeout |
| **Crash** | No `TEST_START` received within `STARTUP_TIMEOUT` (default: 10 s) of UART open | ⚠️ Timeout (no start) |
| **Hung** | `TEST_START` received for a DUT but no further output for ≥ `INTER_LINE_TIMEOUT` | ⚠️ Timeout (hung mid-run) |
| **Hard crash** | UART line goes idle mid-run (no bytes, not even garbage) | ⚠️ Timeout |
| **Garbled output** | Line does not match any known TYPE and is not recoverable | ❌ Protocol error |

**Timeout values are configurable** via environment variables in `parse-results.py`:

| Variable | Default | Description |
|---|---|---|
| `UART_STARTUP_TIMEOUT` | `10` | Seconds to wait for first `TEST_START` after UART open |
| `UART_INTER_LINE_TIMEOUT` | `30` | Seconds of silence per-DUT before declaring timeout for that DUT |
| `UART_MAX_RUN_TIMEOUT` | `300` | Hard ceiling — all DUTs must complete within this time |

A **timed-out DUT** is reported in the GitHub Summary with ⚠️ status. It does not fail other
DUTs. The tests that were successfully reported before the timeout are preserved.

---

## Escape Rules

Free-text fields (`msg:`, `reason:`) may contain any printable ASCII character **except**:
- `\n` (LF) — would break line framing
- `\r` (CR) — reserved

Use these escape sequences for problematic characters:

| Escape | Meaning |
|---|---|
| `\\` | Literal backslash |
| `\n` | Newline (display only — embeds a newline in the displayed message) |
| `\r` | Carriage return |
| `\xHH` | Arbitrary byte with hex value HH (uppercase A-F) |

The parser MUST unescape these sequences when processing messages for display.

**Test IDs (`<id>` fields)** must be safe identifiers: `[A-Za-z0-9_-]`, max 64 characters.
Spaces are not allowed in test IDs. Use underscores.

---

## Complete Example Capture

The following is a valid, complete capture showing the harness aggregating results from two DUTs.
Note that the harness may report DUTs sequentially (one `TEST_START`...`TEST_END` block per DUT)
or interleaved, as long as every result message includes the `mcu` field.

**Sequential per-DUT (recommended for firmware simplicity):**

```
TEST_START mcu=rp2040-0 fw=1.0.0 tests=5
PASS mcu=rp2040-0 gpio_output_high duration_us=423
PASS mcu=rp2040-0 gpio_output_low duration_us=389
METRIC mcu=rp2040-0 gpio_toggle_rate value=1183.2 unit=kHz
FAIL mcu=rp2040-0 spi_cs_timing duration_us=12045 msg:CS deassertion 40ns early, expected >=50ns
LOG mcu=rp2040-0 msg:SPI timing failure is a known issue on rev B silicon
SKIP mcu=rp2040-0 i2c_400khz_stress reason:requires external pullup not populated on rev B
PASS mcu=rp2040-0 pwm_50pct_1khz duration_us=2317
PASS mcu=rp2040-0 adc_vref_calibrate duration_us=87231
TEST_END mcu=rp2040-0 passed=4 failed=1 skipped=1 duration_us=102847

TEST_START mcu=rp2350a fw=0.4.1 tests=3
PASS mcu=rp2350a led_blink duration_us=500
FAIL mcu=rp2350a spi_loopback duration_us=5000 msg:data mismatch at byte 42
PASS mcu=rp2350a uart_echo duration_us=250
TEST_END mcu=rp2350a passed=2 failed=1 skipped=0 duration_us=5750
```

---

## Parser Behaviour Summary

The parser (`parse-results.py`) MUST:

1. Open the **single harness UART device** (e.g. `/dev/ttyAMA2`, path specified in environment or
   config) and read lines until all expected DUTs complete or timeout.
2. Parse each line by splitting on the first space to extract `TYPE`, then parsing remaining
   key=value fields (and the trailing `key:free text` field if present).
3. Maintain **per-DUT state** (keyed by the `mcu` field): `{ mcu_id, fw_version, tests[], metrics[], log[], status }`.
4. On `TEST_END` for a DUT, validate that DUT's summary counts and mark that DUT run complete.
5. On timeout (any variant), set that DUT's status to `TIMEOUT` with the last test seen (if any).
6. After all DUTs complete (or timeout), emit GitHub Step Summary markdown and exit.
7. Exit with code **0** if all DUTs passed, **1** if any DUT had failures or timeouts.

**Key requirement:** Every PASS, FAIL, SKIP, METRIC, and LOG line **must include the `mcu` field**
so the parser can correctly route the result to the right DUT's context. This is essential for
the single-stream topology where all DUTs' results flow through one UART connection.

Unknown `TYPE` values MUST be silently skipped in normal mode and warned in strict mode. This
ensures forward compatibility when new message types are added.

---

## Versioning and Extensibility

- New message types (beyond the 7 defined here) may be added in future protocol versions.
- New key=value fields may be added to existing message types; parsers MUST ignore unknown fields.
- The protocol version is conveyed implicitly via firmware version in `TEST_START`.
- Breaking changes (field reordering, type renaming) require a major protocol version bump and
  an updated spec revision.

---

## Quick Reference Card

```
TEST_START mcu=<id> fw=<version> tests=<int>
PASS       mcu=<id> <test_id> duration_us=<int>
FAIL       mcu=<id> <test_id> duration_us=<int> msg:<message>
SKIP       mcu=<id> <test_id> reason:<reason>
METRIC     mcu=<id> <name> value=<float> unit=<id>
LOG        mcu=<id> msg:<message>
TEST_END   mcu=<id> passed=<int> failed=<int> skipped=<int> duration_us=<int>
```

- **Physical:** Single UART from harness RP2040 to Pi host
- **Baud rate:** 115200 8N1
- **Line ending:** LF (`\n`)
- **Max line length:** 256 bytes
- **Encoding:** ASCII only
- **Timeout (inter-line per-DUT):** 30 s default
- **Critical requirement:** Every PASS/FAIL/SKIP/METRIC/LOG line **must include the `mcu` field**
  for correct per-DUT routing in the single-stream topology
