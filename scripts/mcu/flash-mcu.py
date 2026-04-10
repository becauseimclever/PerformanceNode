#!/usr/bin/env python3
"""flash-mcu.py — Flash a single RP2040/RP2350 MCU via OpenOCD and SWD.

Usage:
    python3 flash-mcu.py --mcu {rp2040-h,rp2040-d,rp2350b-d,rp2350a-d} \
                         --firmware <path.elf or .uf2>

MCU GPIO Pin Assignments (BCM numbering on Raspberry Pi 5):
    MCU       | SWDIO | SWDCLK | RESET
    ----------|-------|--------|-------
    rp2040-h  | 17    | 27     | 22
    rp2040-d  | 23    | 24     | 25
    rp2350b-d | 5     | 6      | 13
    rp2350a-d | 19    | 26     | 16

SWD Method: OpenOCD with linuxgpiod driver (GPIO bit-banging).
RESET: Active-low; asserted (LOW) before flashing, released (HIGH) after.

Exit codes:
    0  Flash succeeded
    1  Flash failed (OpenOCD error, firmware not found, etc.)
    2  Configuration error (missing args, invalid MCU name)
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# ── MCU Configuration ──────────────────────────────────────────────────────────

MCU_CONFIG = {
    "rp2040-h": {
        "description": "RP2040 Harness MCU",
        "swdio": 17,
        "swdclk": 27,
        "reset": 22,
        "target_cfg": "target/rp2040.cfg",
    },
    "rp2040-d": {
        "description": "RP2040 Device Under Test",
        "swdio": 23,
        "swdclk": 24,
        "reset": 25,
        "target_cfg": "target/rp2040.cfg",
    },
    "rp2350b-d": {
        "description": "RP2350B Device Under Test",
        "swdio": 5,
        "swdclk": 6,
        "reset": 13,
        "target_cfg": "target/rp2350.cfg",
    },
    "rp2350a-d": {
        "description": "RP2350A Device Under Test",
        "swdio": 19,
        "swdclk": 26,
        "reset": 16,
        "target_cfg": "target/rp2350.cfg",
    },
}

# Timing constants (seconds)
RESET_ASSERT_S = 0.1
RESET_RELEASE_S = 0.5
OPENOCD_TIMEOUT_S = 30

# OpenOCD settings
ADAPTER_SPEED_KHZ = 1000  # 1 MHz SWD clock
GPIOCHIP = "/dev/gpiochip0"


# ── Helper functions ──────────────────────────────────────────────────────────


def _assert_reset(reset_pin: int) -> None:
    """Assert (drive LOW) the RESET pin using sysfs GPIO."""
    gpio_path = Path(f"/sys/class/gpio/gpio{reset_pin}")

    if not gpio_path.exists():
        # Export the GPIO
        Path("/sys/class/gpio/export").write_text(str(reset_pin), encoding="utf-8")
        time.sleep(0.05)

    # Set as output
    (gpio_path / "direction").write_text("out", encoding="utf-8")
    # Drive LOW (assert reset)
    (gpio_path / "value").write_text("0", encoding="utf-8")
    time.sleep(RESET_ASSERT_S)


def _release_reset(reset_pin: int) -> None:
    """Release (drive HIGH) the RESET pin using sysfs GPIO."""
    gpio_path = Path(f"/sys/class/gpio/gpio{reset_pin}")

    if not gpio_path.exists():
        # Export the GPIO
        Path("/sys/class/gpio/export").write_text(str(reset_pin), encoding="utf-8")
        time.sleep(0.05)

    # Set as output
    (gpio_path / "direction").write_text("out", encoding="utf-8")
    # Drive HIGH (release reset)
    (gpio_path / "value").write_text("1", encoding="utf-8")
    time.sleep(RESET_RELEASE_S)


def _generate_openocd_interface_cfg(
    swdio: int, swdclk: int, reset: int
) -> str:
    """Generate OpenOCD interface config for linuxgpiod SWD."""
    return f"""interface linuxgpiod
linuxgpiod_device {GPIOCHIP}
linuxgpiod_jtag_nums {swdclk} 0 0 {swdio}
linuxgpiod_srst_num {reset}
transport select swd
adapter speed {ADAPTER_SPEED_KHZ}
"""


def _generate_openocd_program_cfg(
    target_cfg: str, firmware: Path, interface_cfg_path: Path
) -> str:
    """Generate OpenOCD config that loads interface, target, and programs firmware."""
    # Ensure firmware path is absolute
    firmware_abs = firmware.resolve()

    return f"""source [{interface_cfg_path}]
source [find {target_cfg}]

program {firmware_abs} verify reset

exit 0
"""


def flash(mcu: str, firmware: Path) -> None:
    """Flash firmware to MCU via OpenOCD SWD. Raises RuntimeError on failure."""

    if mcu not in MCU_CONFIG:
        raise ValueError(f"Unknown MCU: {mcu}. Valid options: {list(MCU_CONFIG.keys())}")

    config = MCU_CONFIG[mcu]

    if not firmware.is_file():
        raise FileNotFoundError(f"Firmware file not found: {firmware}")

    desc = config["description"]
    swdio = config["swdio"]
    swdclk = config["swdclk"]
    reset = config["reset"]
    target_cfg = config["target_cfg"]

    print(f"Flashing {mcu} ({desc})")
    print(f"  Firmware: {firmware}")
    print(f"  SWD pins: SWDIO={swdio}, SWDCLK={swdclk}, RESET={reset}")

    # Create temporary files for OpenOCD config
    with tempfile.TemporaryDirectory(prefix="openocd-") as tmpdir:
        tmpdir_path = Path(tmpdir)

        # Generate interface config
        interface_cfg = tmpdir_path / "interface.cfg"
        interface_cfg.write_text(
            _generate_openocd_interface_cfg(swdio, swdclk, reset),
            encoding="utf-8",
        )

        # Generate program config
        program_cfg = tmpdir_path / "program.cfg"
        program_cfg.write_text(
            _generate_openocd_program_cfg(target_cfg, firmware, interface_cfg),
            encoding="utf-8",
        )

        # Assert RESET before flashing
        print(f"  Asserting RESET (GPIO {reset})...")
        try:
            _assert_reset(reset)
        except Exception as exc:
            raise RuntimeError(f"Failed to assert RESET: {exc}") from exc

        # Run OpenOCD
        print(f"  Running OpenOCD...")
        cmd = [
            "openocd",
            "-f",
            str(program_cfg),
        ]

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=OPENOCD_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError(
                f"OpenOCD timed out after {OPENOCD_TIMEOUT_S}s"
            ) from None
        except FileNotFoundError:
            raise RuntimeError(
                "openocd not found. Install with: sudo apt-get install openocd"
            ) from None

        # Check OpenOCD exit code
        if result.returncode != 0:
            error_msg = result.stderr if result.stderr else result.stdout
            raise RuntimeError(
                f"OpenOCD failed (exit code {result.returncode}):\n{error_msg}"
            )

        # Release RESET after flashing
        print(f"  Releasing RESET (GPIO {reset})...")
        try:
            _release_reset(reset)
        except Exception as exc:
            raise RuntimeError(f"Failed to release RESET: {exc}") from exc

        print(f"  ✓ Flash successful")


# ── CLI ────────────────────────────────────────────────────────────────────────


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Flash a single MCU via OpenOCD and SWD over GPIO."
    )
    parser.add_argument(
        "--mcu",
        required=True,
        choices=list(MCU_CONFIG.keys()),
        help="MCU target (rp2040-h, rp2040-d, rp2350b-d, rp2350a-d)",
    )
    parser.add_argument(
        "--firmware",
        required=True,
        type=Path,
        help="Path to firmware file (.elf or .uf2)",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()

    try:
        flash(mcu=args.mcu, firmware=args.firmware)
        print(f"\n✓ FLASH OK: {args.mcu}")
        sys.exit(0)
    except FileNotFoundError as exc:
        print(f"\n✗ FLASH FAILED: {args.mcu}: {exc}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, RuntimeError) as exc:
        print(f"\n✗ FLASH FAILED: {args.mcu}: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # pylint: disable=broad-except
        print(
            f"\n✗ FLASH FAILED: {args.mcu}: unexpected error: {exc}",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
