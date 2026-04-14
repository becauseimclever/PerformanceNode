# GitHub Step Summary Output Format

**Version:** 1.0 (Single-Stream Topology)  
**Status:** Active  
**Owner:** Wufei (Performance Engineer)  
**Written to:** `$GITHUB_STEP_SUMMARY`  
**Produced by:** `parse-results.py` (Pi-side parser)  
**Input:** Single UART stream from harness RP2040, containing aggregated results from three DUT MCUs

---

## Overview

After all DUT MCUs have completed (or timed out), `parse-results.py` writes a Markdown document to
`$GITHUB_STEP_SUMMARY`. GitHub Actions renders this as a rich HTML page on the workflow run
summary tab — no extra UI configuration needed.

The parser receives **one UART stream** from the **harness RP2040** containing results from all
three DUT MCUs (RP2040-0, RP2350A, RP2350B). Each result message includes the `mcu` field to
identify which DUT it came from. The parser reconstructs **per-DUT tables** for the GitHub
summary, so the output **displays results as if each DUT reported separately**.

---

## Status Emoji Key

| Emoji | Meaning | Condition |
|---|---|---|
| ✅ | All passed | `failed == 0` and `status == complete` |
| ❌ | Had failures | `failed > 0` |
| ⚠️ | Timed out | `status == timeout` |
| 🔄 | Not run | `status == not_run` (MCU not seen on UART) |

---

## Template

The full template below is shown with **example data** representing:
- `rp2040-0`: all passing (with metrics)
- `rp2040-1`: all passing
- `rp2350a`: 2 failures
- `rp2350b`: timed out

---

```markdown
## MCU Test Results

> Run triggered by `push` on branch `main` · 2026-04-10T14:32:07Z · Firmware suite `v0.4.1`

### Overview

| MCU | Status | Passed | Failed | Skipped | Duration |
|---|---|---|---|---|---|
| rp2040-0 | ✅ All passed | 8 | 0 | 1 | 102.8 ms |
| rp2040-1 | ✅ All passed | 12 | 0 | 0 | 248.1 ms |
| rp2350a | ❌ Had failures | 9 | 2 | 0 | 1 834.5 ms |
| rp2350b | ⚠️ Timed out | 3 | 0 | 0 | — |

---

<details>
<summary>📋 rp2040-0 — ✅ 8 passed, 0 failed, 1 skipped (fw 1.0.0)</summary>

#### Test Results

| Test | Status | Duration |
|---|---|---|
| `gpio_output_high` | ✅ Pass | 0.4 ms |
| `gpio_output_low` | ✅ Pass | 0.4 ms |
| `spi_cs_timing` | ✅ Pass | 12.0 ms |
| `i2c_100khz_basic` | ✅ Pass | 5.2 ms |
| `pwm_50pct_1khz` | ✅ Pass | 2.3 ms |
| `adc_vref_calibrate` | ✅ Pass | 87.2 ms |
| `uart_loopback_64b` | ✅ Pass | 1.1 ms |
| `flash_write_verify` | ✅ Pass | 94.2 ms |
| `i2c_400khz_stress` | ⏭️ Skip | — |

> **Skipped:** `i2c_400khz_stress` — requires external pullup not populated on rev B

#### Performance Measurements

| Metric | Value | Unit |
|---|---|---|
| `gpio_toggle_rate` | 1183.2 | kHz |
| `spi_throughput` | 8.0 | MHz |
| `adc_sample_rate` | 489.3 | kHz |

</details>

---

<details>
<summary>📋 rp2040-1 — ✅ 12 passed, 0 failed, 0 skipped (fw 1.0.0)</summary>

#### Test Results

| Test | Status | Duration |
|---|---|---|
| `pio_squarewave_1mhz` | ✅ Pass | 14.8 ms |
| `pio_uart_tx_9600` | ✅ Pass | 18.2 ms |
| `pio_uart_rx_9600` | ✅ Pass | 18.4 ms |
| `dma_mem_to_mem_1kb` | ✅ Pass | 0.6 ms |
| `dma_mem_to_mem_64kb` | ✅ Pass | 4.1 ms |
| `dma_chain_4_transfers` | ✅ Pass | 3.8 ms |
| `irq_latency_gpio` | ✅ Pass | 7.2 ms |
| `irq_latency_timer` | ✅ Pass | 7.0 ms |
| `watchdog_reset` | ✅ Pass | 52.3 ms |
| `multicore_fifo_basic` | ✅ Pass | 11.4 ms |
| `multicore_fifo_stress` | ✅ Pass | 88.7 ms |
| `sleep_us_accuracy` | ✅ Pass | 22.6 ms |

#### Performance Measurements

| Metric | Value | Unit |
|---|---|---|
| `irq_latency_min_us` | 0.83 | us |
| `irq_latency_max_us` | 2.41 | us |
| `dma_bandwidth_mbps` | 250.4 | MHz |

</details>

---

<details>
<summary>📋 rp2350a — ❌ 9 passed, 2 failed, 0 skipped (fw 0.4.1)</summary>

#### Test Results

| Test | Status | Duration | Error |
|---|---|---|---|
| `gpio_output_high` | ✅ Pass | 0.4 ms | |
| `gpio_output_low` | ✅ Pass | 0.4 ms | |
| `spi_loopback_basic` | ✅ Pass | 8.3 ms | |
| `spi_loopback_stress` | ❌ Fail | 501.2 ms | expected 0xFF got 0xA3 after 4096 bytes |
| `i2c_100khz_basic` | ✅ Pass | 5.1 ms | |
| `i2c_400khz_basic` | ✅ Pass | 5.3 ms | |
| `pwm_50pct_1khz` | ✅ Pass | 2.3 ms | |
| `pwm_duty_sweep` | ✅ Pass | 18.9 ms | |
| `adc_single_ended` | ✅ Pass | 12.4 ms | |
| `adc_differential` | ❌ Fail | 15.7 ms | differential mode offset error: 23mV > 10mV threshold |
| `flash_write_verify` | ✅ Pass | 94.1 ms | |

#### Performance Measurements

| Metric | Value | Unit |
|---|---|---|
| `spi_throughput` | 12.0 | MHz |
| `adc_sample_rate` | 500.0 | kHz |

</details>

---

<details>
<summary>📋 rp2350b — ⚠️ Timed out after 30 s (3 tests received before timeout)</summary>

#### Tests received before timeout

| Test | Status | Duration |
|---|---|---|
| `gpio_output_high` | ✅ Pass | 0.4 ms |
| `gpio_output_low` | ✅ Pass | 0.4 ms |
| `spi_loopback_basic` | ✅ Pass | 8.3 ms |

> ⚠️ **Timeout:** No output received for 30 seconds. Firmware may have crashed or hung.
> Last line received at offset 3 of 14 declared tests.

</details>

---

### Summary

| | Count |
|---|---|
| Total tests run | 36 |
| ✅ Passed | 32 |
| ❌ Failed | 2 |
| ⏭️ Skipped | 1 |
| ⚠️ Timed out MCUs | 1 |
| Total duration | 2 185.4 ms |

> Generated by `parse-results.py` · 2026-04-10T14:32:09Z
```

---

## Rendering Notes

### `<details>` Collapsible Sections

GitHub's Step Summary renderer supports raw HTML inline with Markdown. The `<details>` block
**must** have a blank line before the Markdown content inside it:

```markdown
<details>
<summary>Click to expand</summary>

Markdown content here — blank line after <summary> is required.

</details>
```

Without the blank line, GitHub will render the inner content as literal text.

### Table Columns

The FAIL table includes an **Error** column not present in the PASS-only table. The parser
should always emit the four-column version (Test, Status, Duration, Error) for any MCU that
has at least one failure. Use an empty cell for passing rows.

### Duration Formatting

Convert microseconds (from `duration_us` protocol fields) to human-readable form:

| Range | Format | Example |
|---|---|---|
| < 1 000 µs | `XXX µs` | `423 µs` |
| 1 000 – 999 999 µs | `X.X ms` | `12.0 ms` |
| ≥ 1 000 000 µs | `X.XX s` | `1.83 s` |

Total run duration uses the same rules applied to the sum of all `TEST_END duration_us` values.
Timed-out MCUs contribute `—` (em dash) to the duration column.

### Metric Table

Only emit the "Performance Measurements" sub-table if the MCU sent at least one `METRIC` line.
If multiple `METRIC` lines share the same name (repeated sampling), emit each as a separate row
(do not aggregate).

### Footer Timestamp

Use ISO 8601 UTC format: `2026-04-10T14:32:09Z`. Source this from the parser's wall clock at
the time it writes the summary, not from the MCU.

---

## Parser Output Flow

```
parse-results.py collects all MCU results
         │
         ▼
Write overview table (all 4 MCUs)
         │
         ▼
For each MCU (in order: rp2040-0, rp2040-1, rp2350a, rp2350b):
  Write <details> section
  Write test results table
  If metrics exist: write Performance Measurements table
  If timed out: write timeout notice
         │
         ▼
Write summary counts footer
Write timestamp
```

Exit code: **0** if all MCUs passed, **1** if any MCU had failures or timeouts.
