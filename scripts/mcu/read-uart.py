#!/usr/bin/env python3
"""read-uart.py — Read test results from a single MCU over UART.

Waits for a TEST_START marker, reads lines until TEST_END or timeout,
and writes the raw output to a file for later parsing.

Usage:
    python3 read-uart.py --target <name> --device <path> --baud <rate>
                         --timeout <seconds> --output-file <path>

Expected UART protocol (placeholder — Wufei is finalising):
    TEST_START:{target}:{firmware_version}
    PASS:{test_name}:{duration_ms}
    FAIL:{test_name}:{duration_ms}:{error_message}
    SKIP:{test_name}:{reason}
    TEST_END:{target}:{passed}/{total}:{total_ms}

Exit codes:
    0  Data received (TEST_START seen, output written)
    1  Timeout (no TEST_START or incomplete output)
    2  Configuration/device error
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

# Sentinel lines that delimit a test run
TEST_START_PREFIX = "TEST_START:"
TEST_END_PREFIX = "TEST_END:"

# Time to wait between read attempts when no data is available
POLL_SLEEP_S: float = 0.05


def _import_serial():
    """Import pyserial; print install instructions and exit(2) if missing."""
    try:
        import serial  # type: ignore
        return serial
    except ImportError:
        print(
            "ERROR: pyserial is not installed.\n"
            "Install it with:\n"
            "    sudo apt-get install python3-serial\n"
            "or:\n"
            "    pip3 install pyserial",
            file=sys.stderr,
        )
        sys.exit(2)


def read_uart(
    target: str,
    device: str,
    baud: int,
    timeout_s: float,
    output_file: Path,
) -> bool:
    """
    Read UART output from *device* and write it to *output_file*.

    Returns True if TEST_START was received (even if TEST_END was not).
    Returns False on timeout before TEST_START.
    """
    serial = _import_serial()

    try:
        port = serial.Serial(
            port=device,
            baudrate=baud,
            timeout=0,       # non-blocking reads; we manage our own deadline
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
        )
    except serial.SerialException as exc:
        print(f"ERROR: Cannot open {device}: {exc}", file=sys.stderr)
        sys.exit(2)

    lines: list[str] = []
    started = False
    ended = False
    deadline = time.monotonic() + timeout_s
    line_buf = ""

    try:
        while time.monotonic() < deadline:
            raw = port.read(256)
            if raw:
                text = raw.decode("utf-8", errors="replace")
                line_buf += text
                # Split on newlines, keep partial last segment in buffer
                parts = line_buf.split("\n")
                line_buf = parts[-1]
                complete_lines = parts[:-1]

                for line in complete_lines:
                    line = line.rstrip("\r")
                    if not started:
                        if line.startswith(TEST_START_PREFIX):
                            started = True
                            lines.append(line)
                    else:
                        lines.append(line)
                        if line.startswith(TEST_END_PREFIX):
                            ended = True
                            break

                if ended:
                    break
            else:
                time.sleep(POLL_SLEEP_S)

        # Flush any partial line still in the buffer
        if line_buf.strip():
            lines.append(line_buf.rstrip("\r"))

    finally:
        port.close()

    # Write collected output regardless of whether we got TEST_END
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")

    line_count = len(lines)

    if not started:
        print(f"UART TIMEOUT: {target} (no TEST_START received within {timeout_s}s)")
        return False

    if not ended:
        print(
            f"UART PARTIAL: {target} ({line_count} lines — TEST_END not received within {timeout_s}s)"
        )
        # Still return True — partial data is better than nothing
        return True

    print(f"UART OK: {target} ({line_count} lines)")
    return True


# ── CLI ────────────────────────────────────────────────────────────────────────

def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read test results from a single MCU UART connection."
    )
    parser.add_argument("--target", required=True, help="MCU target name (e.g. rp2040-0)")
    parser.add_argument("--device", required=True, help="Serial device path (e.g. /dev/ttyAMA0)")
    parser.add_argument("--baud", required=True, type=int, help="UART baud rate")
    parser.add_argument("--timeout", required=True, type=float, help="Seconds to wait for results")
    parser.add_argument("--output-file", required=True, type=Path, help="File path to write raw output")
    return parser.parse_args()


def main() -> None:
    args = _parse_args()

    received = read_uart(
        target=args.target,
        device=args.device,
        baud=args.baud,
        timeout_s=args.timeout,
        output_file=args.output_file,
    )

    sys.exit(0 if received else 1)


if __name__ == "__main__":
    main()
