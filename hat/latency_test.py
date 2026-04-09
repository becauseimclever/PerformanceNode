#!/usr/bin/env python3
"""
latency_test.py – GP2040-CE input-latency measurement script.

This script uses the custom HAT to measure the end-to-end input latency of a
GP2040-CE gamepad:

  1. Assert TRIGGER_OUTPUT_PIN (GPIO 17) HIGH – this signal is wired to a
     button input on the GP2040-CE device via the HAT.
  2. Record t0 at the moment the trigger goes high.
  3. Wait for BUTTON_SIGNAL_PIN (GPIO 4) to go HIGH – the GP2040-CE firmware
     asserts this pin when it has processed and re-transmitted the button press
     over USB HID.
  4. Record t1 when the signal is detected.
  5. latency = t1 – t0
  6. Repeat for N samples, compute statistics, write JSON results.

Usage:
    python3 latency_test.py [--config /path/to/hat-config.json] [--output /path/to/results]
"""

import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path
from typing import List

try:
    import RPi.GPIO as GPIO  # type: ignore
except ImportError:
    # Allow the script to be imported / unit-tested on non-Pi hosts.
    GPIO = None  # type: ignore


CONFIG_DEFAULT = "/etc/performancenode/hat/hat-config.json"


def load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def setup_gpio(cfg: dict) -> None:
    if GPIO is None:
        raise RuntimeError("RPi.GPIO is not available on this platform.")
    GPIO.setmode(GPIO.BCM)
    gpio = cfg["gpio"]
    GPIO.setup(gpio["trigger_output_pin"], GPIO.OUT, initial=GPIO.LOW)
    GPIO.setup(gpio["button_signal_pin"],  GPIO.IN,  pull_up_down=GPIO.PUD_DOWN)
    GPIO.setup(gpio["status_led_pin"],     GPIO.OUT, initial=GPIO.LOW)


def measure_single(cfg: dict, timeout_sec: float) -> float | None:
    """
    Trigger one button press and return the measured latency in milliseconds,
    or None if the signal was not detected within the timeout.
    """
    gpio = cfg["gpio"]
    trigger_pin = gpio["trigger_output_pin"]
    signal_pin  = gpio["button_signal_pin"]
    active_high = gpio["active_high"]

    trigger_level = GPIO.HIGH if active_high else GPIO.LOW
    detect_level  = GPIO.HIGH if active_high else GPIO.LOW

    # Assert trigger.
    GPIO.output(trigger_pin, trigger_level)
    t0 = time.perf_counter()

    # Wait for signal pin.
    detected = False
    while (time.perf_counter() - t0) < timeout_sec:
        if GPIO.input(signal_pin) == detect_level:
            t1 = time.perf_counter()
            detected = True
            break

    # Release trigger.
    GPIO.output(trigger_pin, GPIO.LOW if active_high else GPIO.HIGH)

    if not detected:
        return None
    return (t1 - t0) * 1000.0  # ms


def run_latency_test(config_path: str, output_dir: str) -> dict:
    cfg = load_config(config_path)
    lt  = cfg["latency_test"]

    sample_count    = lt["sample_count"]
    warmup_samples  = lt["warmup_samples"]
    interval_ms     = lt["trigger_interval_ms"]
    timeout_ms      = lt["timeout_ms"]
    timeout_sec     = timeout_ms / 1000.0
    interval_sec    = interval_ms / 1000.0

    setup_gpio(cfg)

    if GPIO is not None:
        GPIO.output(cfg["gpio"]["status_led_pin"], GPIO.HIGH)

    samples: List[float] = []
    timeouts = 0

    print(f"Running latency test: {warmup_samples} warmup + {sample_count} samples …")

    try:
        total = warmup_samples + sample_count
        for i in range(total):
            latency = measure_single(cfg, timeout_sec)
            if latency is None:
                timeouts += 1
                if i >= warmup_samples:
                    print(f"  Sample {i - warmup_samples + 1}: TIMEOUT", flush=True)
            else:
                if i >= warmup_samples:
                    samples.append(latency)
                    print(f"  Sample {i - warmup_samples + 1}: {latency:.3f} ms", flush=True)
            time.sleep(interval_sec)
    finally:
        if GPIO is not None:
            GPIO.output(cfg["gpio"]["status_led_pin"], GPIO.LOW)
            GPIO.cleanup()

    if not samples:
        raise RuntimeError("No valid latency samples collected.")

    result = {
        "timestamp":      time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
        "tool":           "latency_test",
        "sample_count":   len(samples),
        "timeout_count":  timeouts,
        "latency_ms": {
            "min":    round(min(samples), 4),
            "max":    round(max(samples), 4),
            "mean":   round(statistics.mean(samples), 4),
            "median": round(statistics.median(samples), 4),
            "stdev":  round(statistics.stdev(samples), 4) if len(samples) > 1 else 0.0,
            "p95":    round(sorted(samples)[int(len(samples) * 0.95)], 4),
            "p99":    round(sorted(samples)[int(len(samples) * 0.99)], 4),
        },
        "raw_samples_ms": [round(s, 4) for s in samples],
    }

    Path(output_dir).mkdir(parents=True, exist_ok=True)
    out_file = os.path.join(output_dir, f"latency-{result['timestamp']}.json")
    with open(out_file, "w") as f:
        json.dump(result, f, indent=2)

    print(f"\nResults written to {out_file}")
    print(f"  Mean latency:   {result['latency_ms']['mean']} ms")
    print(f"  Median latency: {result['latency_ms']['median']} ms")
    print(f"  p95 latency:    {result['latency_ms']['p95']} ms")
    print(f"  p99 latency:    {result['latency_ms']['p99']} ms")
    print(f"  Timeouts:       {timeouts}")

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="GP2040-CE latency measurement")
    parser.add_argument("--config", default=CONFIG_DEFAULT,
                        help="Path to hat-config.json")
    parser.add_argument("--output", default="/opt/performancenode/results/latency",
                        help="Output directory for result JSON files")
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Config file not found: {args.config}", file=sys.stderr)
        sys.exit(1)

    run_latency_test(args.config, args.output)


if __name__ == "__main__":
    main()
