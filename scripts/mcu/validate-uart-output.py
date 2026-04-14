#!/usr/bin/env python3
"""
validate-uart-output.py — UART Result Protocol validator and summary printer.

Reads a UART capture file (or stdin) containing aggregated results from the harness RP2040
and validates it against the PerformanceNode UART Result Protocol v1.0 for single-stream
topology (docs/hardware/uart-result-protocol.md).

The harness RP2040 reports results from three DUT MCUs (RP2040-0, RP2350A, RP2350B) over a
single UART connection to the Pi. Each result message includes the `mcu` field to identify
which DUT it came from.

Usage:
    python3 validate-uart-output.py --input capture.txt
    python3 validate-uart-output.py --input -             # stdin
    python3 validate-uart-output.py --input capture.txt --strict

Exit codes:
    0  — input is valid (no protocol errors found)
    1  — one or more protocol errors or validation warnings detected
    2  — argument/IO error
"""

import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Constants matching the protocol spec
# ---------------------------------------------------------------------------

VALID_MCU_IDS = {"rp2040-0", "rp2040-1", "rp2350a", "rp2350b"}
MAX_LINE_LEN = 256          # bytes including LF
MAX_ID_LEN = 64
MAX_MSG_LEN = 200
MAX_REASON_LEN = 180
MAX_FAIL_MSG_LEN = 180
MAX_UNIT_LEN = 16

KNOWN_TYPES = {"TEST_START", "PASS", "FAIL", "SKIP", "METRIC", "LOG", "TEST_END"}

# <id> field pattern: alphanumeric + hyphens/underscores
ID_RE = re.compile(r'^[A-Za-z0-9_-]+$')

# Semver-like version (permissive: digits and dots)
VERSION_RE = re.compile(r'^\d+\.\d+(\.\d+)?$')

UNIT_RE = re.compile(r'^[A-Za-z0-9_%/]+$')


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class TestRecord:
    name: str
    status: str          # PASS / FAIL / SKIP
    duration_us: Optional[int] = None
    message: str = ""


@dataclass
class MetricRecord:
    name: str
    value: float
    unit: str


@dataclass
class MCURun:
    mcu_id: str
    fw_version: str = ""
    declared_tests: int = 0
    tests: list = field(default_factory=list)
    metrics: list = field(default_factory=list)
    logs: list = field(default_factory=list)
    end_received: bool = False
    end_passed: int = 0
    end_failed: int = 0
    end_skipped: int = 0
    end_duration_us: int = 0


# ---------------------------------------------------------------------------
# Error / warning collector
# ---------------------------------------------------------------------------

class Reporter:
    def __init__(self):
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, lineno: int, msg: str):
        self.errors.append(f"  line {lineno}: ERROR — {msg}")

    def warn(self, lineno: int, msg: str):
        self.warnings.append(f"  line {lineno}: WARNING — {msg}")

    @property
    def has_issues(self) -> bool:
        return bool(self.errors or self.warnings)


# ---------------------------------------------------------------------------
# Field parsers
# ---------------------------------------------------------------------------

def parse_kv_fields(parts: list[str], lineno: int, rep: Reporter) -> dict[str, str]:
    """Parse key=value tokens. Stops at first token that contains ':' (free-text prefix)."""
    result = {}
    for part in parts:
        if '=' not in part:
            rep.error(lineno, f"malformed field (no '='): {part!r}")
            continue
        k, _, v = part.partition('=')
        if not k:
            rep.error(lineno, f"empty key in field: {part!r}")
            continue
        result[k] = v
    return result


def parse_free_text(tokens: list[str], prefix: str, lineno: int, rep: Reporter) -> Optional[str]:
    """
    Find the token starting with `prefix:` (e.g. 'msg:') and return everything
    after the colon, reconstructing spaces from remaining tokens.
    Returns None if the prefix token is not found.
    """
    for i, tok in enumerate(tokens):
        if tok.startswith(prefix + ':'):
            # Everything after 'prefix:' in this token, plus remaining tokens
            after = tok[len(prefix) + 1:]
            rest = tokens[i + 1:]
            return (after + (' ' + ' '.join(rest) if rest else '')).strip() if (after or rest) else ''
    return None


# ---------------------------------------------------------------------------
# Per-type validators
# ---------------------------------------------------------------------------

def validate_test_start(tokens: list[str], lineno: int, rep: Reporter,
                        runs: dict[str, MCURun]) -> Optional[MCURun]:
    kv = parse_kv_fields(tokens, lineno, rep)

    mcu = kv.get('mcu', '')
    fw = kv.get('fw', '')
    tests_str = kv.get('tests', '')

    if not mcu:
        rep.error(lineno, "TEST_START missing 'mcu' field")
        return None
    if mcu not in VALID_MCU_IDS:
        rep.warn(lineno, f"unknown mcu id {mcu!r} (expected one of {sorted(VALID_MCU_IDS)})")
    if not fw:
        rep.error(lineno, "TEST_START missing 'fw' field")
    elif not VERSION_RE.match(fw):
        rep.warn(lineno, f"fw version {fw!r} does not match semver pattern X.Y.Z")
    if not tests_str:
        rep.error(lineno, "TEST_START missing 'tests' field")
    else:
        if not tests_str.isdigit():
            rep.error(lineno, f"TEST_START 'tests' must be unsigned integer, got {tests_str!r}")

    if mcu in runs and not runs[mcu].end_received:
        rep.warn(lineno, f"duplicate TEST_START for {mcu!r} without prior TEST_END — resetting context")

    run = MCURun(mcu_id=mcu, fw_version=fw,
                 declared_tests=int(tests_str) if tests_str.isdigit() else 0)
    runs[mcu] = run
    return run


def validate_pass(tokens: list[str], lineno: int, rep: Reporter,
                  active_run: Optional[MCURun]) -> Optional[TestRecord]:
    if len(tokens) < 3:
        rep.error(lineno, "PASS requires mcu, test_id and duration_us fields")
        return None

    mcu_id = None
    test_id = None
    kv_tokens = []
    
    # Parse mcu=<id> field
    if tokens[0].startswith('mcu='):
        mcu_id = tokens[0][4:]
        test_id = tokens[1]
        kv_tokens = tokens[2:]
    else:
        rep.error(lineno, "PASS must have mcu=<id> as first field")
        return None

    kv = parse_kv_fields(kv_tokens, lineno, rep)

    if not mcu_id or mcu_id not in VALID_MCU_IDS:
        rep.warn(lineno, f"PASS mcu={mcu_id!r} is not a valid MCU identifier")
    _check_id(test_id, lineno, rep, "test_id")
    dur = _check_duration(kv.get('duration_us', ''), lineno, rep)

    rec = TestRecord(name=test_id, status='PASS', duration_us=dur)
    if active_run:
        active_run.tests.append(rec)
    return rec


def validate_fail(tokens: list[str], lineno: int, rep: Reporter,
                  active_run: Optional[MCURun]) -> Optional[TestRecord]:
    if len(tokens) < 3:
        rep.error(lineno, "FAIL requires mcu, test_id and duration_us fields")
        return None

    mcu_id = None
    test_id = None
    kv_tokens = []
    
    # Parse mcu=<id> field
    if tokens[0].startswith('mcu='):
        mcu_id = tokens[0][4:]
        test_id = tokens[1]
        kv_tokens = tokens[2:]
    else:
        rep.error(lineno, "FAIL must have mcu=<id> as first field")
        return None

    # Split out free-text msg: from remaining tokens
    msg_text = None
    msg_found = False
    filtered_kv_tokens = []
    for tok in kv_tokens:
        if tok.startswith('msg:'):
            msg_text = tok[4:]
            msg_found = True
        elif msg_found:
            msg_text += ' ' + tok
        else:
            filtered_kv_tokens.append(tok)

    kv = parse_kv_fields(filtered_kv_tokens, lineno, rep)

    if not mcu_id or mcu_id not in VALID_MCU_IDS:
        rep.warn(lineno, f"FAIL mcu={mcu_id!r} is not a valid MCU identifier")
    _check_id(test_id, lineno, rep, "test_id")
    dur = _check_duration(kv.get('duration_us', ''), lineno, rep)

    if msg_text is None:
        rep.warn(lineno, "FAIL line has no 'msg:' field — failure reason undocumented")
        msg_text = ''
    elif len(msg_text) > MAX_FAIL_MSG_LEN:
        rep.warn(lineno, f"FAIL msg exceeds {MAX_FAIL_MSG_LEN} chars (got {len(msg_text)})")

    rec = TestRecord(name=test_id, status='FAIL', duration_us=dur, message=msg_text)
    if active_run:
        active_run.tests.append(rec)
    return rec


def validate_skip(tokens: list[str], lineno: int, rep: Reporter,
                  active_run: Optional[MCURun]) -> Optional[TestRecord]:
    if len(tokens) < 2:
        rep.error(lineno, "SKIP requires mcu and test_id fields")
        return None

    mcu_id = None
    test_id = None
    
    # Parse mcu=<id> field
    if tokens[0].startswith('mcu='):
        mcu_id = tokens[0][4:]
        test_id = tokens[1]
        reason_tokens = tokens[2:]
    else:
        rep.error(lineno, "SKIP must have mcu=<id> as first field")
        return None

    _check_id(test_id, lineno, rep, "test_id")

    reason = None
    for i, tok in enumerate(reason_tokens):
        if tok.startswith('reason:'):
            reason = tok[7:] + (' ' + ' '.join(reason_tokens[i+1:]) if reason_tokens[i+1:] else '')
            break

    if not mcu_id or mcu_id not in VALID_MCU_IDS:
        rep.warn(lineno, f"SKIP mcu={mcu_id!r} is not a valid MCU identifier")
    if reason is None:
        rep.warn(lineno, "SKIP line has no 'reason:' field")
        reason = ''
    elif len(reason) > MAX_REASON_LEN:
        rep.warn(lineno, f"SKIP reason exceeds {MAX_REASON_LEN} chars (got {len(reason)})")

    rec = TestRecord(name=test_id, status='SKIP', message=reason)
    if active_run:
        active_run.tests.append(rec)
    return rec


def validate_metric(tokens: list[str], lineno: int, rep: Reporter,
                    active_run: Optional[MCURun]) -> Optional[MetricRecord]:
    if len(tokens) < 2:
        rep.error(lineno, "METRIC requires mcu and name fields")
        return None

    mcu_id = None
    name = None
    kv_tokens = []
    
    # Parse mcu=<id> field
    if tokens[0].startswith('mcu='):
        mcu_id = tokens[0][4:]
        name = tokens[1]
        kv_tokens = tokens[2:]
    else:
        rep.error(lineno, "METRIC must have mcu=<id> as first field")
        return None

    kv = parse_kv_fields(kv_tokens, lineno, rep)

    _check_id(name, lineno, rep, "metric name")

    value_str = kv.get('value', '')
    unit = kv.get('unit', '')

    if not mcu_id or mcu_id not in VALID_MCU_IDS:
        rep.warn(lineno, f"METRIC mcu={mcu_id!r} is not a valid MCU identifier")
    if not value_str:
        rep.error(lineno, "METRIC missing 'value' field")
        value = 0.0
    else:
        try:
            value = float(value_str)
        except ValueError:
            rep.error(lineno, f"METRIC 'value' is not a valid float: {value_str!r}")
            value = 0.0

    if not unit:
        rep.error(lineno, "METRIC missing 'unit' field")
    else:
        if len(unit) > MAX_UNIT_LEN:
            rep.warn(lineno, f"METRIC unit exceeds {MAX_UNIT_LEN} chars: {unit!r}")
        if not UNIT_RE.match(unit):
            rep.warn(lineno, f"METRIC unit contains unusual characters: {unit!r}")

    rec = MetricRecord(name=name, value=value, unit=unit)
    if active_run:
        active_run.metrics.append(rec)
    return rec


def validate_log(tokens: list[str], lineno: int, rep: Reporter,
                 active_run: Optional[MCURun], strict: bool):
    if not tokens:
        rep.error(lineno, "LOG requires mcu field")
        return

    mcu_id = None
    
    # Parse mcu=<id> field
    if tokens[0].startswith('mcu='):
        mcu_id = tokens[0][4:]
        msg_tokens = tokens[1:]
    else:
        rep.error(lineno, "LOG must have mcu=<id> as first field")
        return

    if strict:
        rep.error(lineno, "LOG line rejected in strict mode")
        return

    msg = None
    for tok in msg_tokens:
        if tok.startswith('msg:'):
            msg = tok[4:] + (' ' + ' '.join(msg_tokens[msg_tokens.index(tok)+1:])
                              if msg_tokens[msg_tokens.index(tok)+1:] else '')
            break

    if not mcu_id or mcu_id not in VALID_MCU_IDS:
        rep.warn(lineno, f"LOG mcu={mcu_id!r} is not a valid MCU identifier")
    if msg is None:
        rep.warn(lineno, "LOG line has no 'msg:' field")
        msg = ''

    if len(msg) > MAX_MSG_LEN:
        rep.warn(lineno, f"LOG msg exceeds {MAX_MSG_LEN} chars (got {len(msg)})")

    if active_run:
        active_run.logs.append(msg)


def validate_test_end(tokens: list[str], lineno: int, rep: Reporter,
                      runs: dict[str, MCURun]) -> Optional[MCURun]:
    kv = parse_kv_fields(tokens, lineno, rep)

    mcu = kv.get('mcu', '')
    if not mcu:
        rep.error(lineno, "TEST_END missing 'mcu' field")
        return None

    run = runs.get(mcu)
    if run is None:
        rep.error(lineno, f"TEST_END for {mcu!r} but no prior TEST_START seen for this MCU")
        return None

    for field_name in ('passed', 'failed', 'skipped', 'duration_us'):
        if field_name not in kv:
            rep.error(lineno, f"TEST_END missing '{field_name}' field")

    def to_int(name: str) -> int:
        val = kv.get(name, '0')
        if not val.isdigit():
            rep.error(lineno, f"TEST_END '{name}' must be unsigned integer, got {val!r}")
            return 0
        return int(val)

    passed = to_int('passed')
    failed = to_int('failed')
    skipped = to_int('skipped')
    duration_us = to_int('duration_us')

    # Validate counts against what we actually saw
    actual_passed = sum(1 for t in run.tests if t.status == 'PASS')
    actual_failed = sum(1 for t in run.tests if t.status == 'FAIL')
    actual_skipped = sum(1 for t in run.tests if t.status == 'SKIP')

    if passed != actual_passed:
        rep.warn(lineno, f"TEST_END passed={passed} but parser counted {actual_passed} PASS lines")
    if failed != actual_failed:
        rep.warn(lineno, f"TEST_END failed={failed} but parser counted {actual_failed} FAIL lines")
    if skipped != actual_skipped:
        rep.warn(lineno, f"TEST_END skipped={skipped} but parser counted {actual_skipped} SKIP lines")

    run.end_received = True
    run.end_passed = passed
    run.end_failed = failed
    run.end_skipped = skipped
    run.end_duration_us = duration_us
    return run


# ---------------------------------------------------------------------------
# Helper validators
# ---------------------------------------------------------------------------

def _check_id(value: str, lineno: int, rep: Reporter, field_label: str):
    if not value:
        rep.error(lineno, f"{field_label} is empty")
    elif len(value) > MAX_ID_LEN:
        rep.warn(lineno, f"{field_label} exceeds {MAX_ID_LEN} chars: {value!r}")
    elif not ID_RE.match(value):
        rep.error(lineno, f"{field_label} contains invalid characters: {value!r} "
                          f"(allowed: A-Z a-z 0-9 _ -)")


def _check_duration(value: str, lineno: int, rep: Reporter) -> Optional[int]:
    if not value:
        rep.error(lineno, "missing 'duration_us' field")
        return None
    if not value.isdigit():
        rep.error(lineno, f"'duration_us' must be unsigned integer, got {value!r}")
        return None
    return int(value)


# ---------------------------------------------------------------------------
# Main parser loop
# ---------------------------------------------------------------------------

def parse_capture(lines: list[str], strict: bool, rep: Reporter) -> dict[str, MCURun]:
    runs: dict[str, MCURun] = {}
    active_run: Optional[MCURun] = None

    for lineno, raw_line in enumerate(lines, start=1):
        # Strip trailing LF/CRLF
        line = raw_line.rstrip('\r\n')

        # Check line length (include the LF byte)
        if len(raw_line) > MAX_LINE_LEN:
            rep.error(lineno, f"line exceeds {MAX_LINE_LEN} bytes ({len(raw_line)} bytes)")

        # Skip empty lines
        if not line:
            continue

        # Check for leading/trailing whitespace
        if line != line.strip():
            rep.error(lineno, "line has leading or trailing whitespace")
            line = line.strip()

        # Check for non-ASCII characters
        try:
            line.encode('ascii')
        except UnicodeEncodeError:
            rep.error(lineno, "line contains non-ASCII characters; use \\xHH escapes")

        tokens = line.split(' ')
        msg_type = tokens[0]
        rest = tokens[1:]

        if msg_type not in KNOWN_TYPES:
            if strict:
                rep.error(lineno, f"unknown message type {msg_type!r}")
            else:
                rep.warn(lineno, f"unknown message type {msg_type!r} (skipping)")
            continue

        # Enforce ordering rules
        if msg_type == 'TEST_START':
            active_run = validate_test_start(rest, lineno, rep, runs)
        elif msg_type in ('PASS', 'FAIL', 'SKIP', 'METRIC', 'LOG'):
            if active_run is None:
                rep.error(lineno, f"{msg_type} line before any TEST_START")
            if msg_type == 'PASS':
                validate_pass(rest, lineno, rep, active_run)
            elif msg_type == 'FAIL':
                validate_fail(rest, lineno, rep, active_run)
            elif msg_type == 'SKIP':
                validate_skip(rest, lineno, rep, active_run)
            elif msg_type == 'METRIC':
                validate_metric(rest, lineno, rep, active_run)
            elif msg_type == 'LOG':
                validate_log(rest, lineno, rep, active_run, strict)
        elif msg_type == 'TEST_END':
            if active_run is None:
                rep.error(lineno, "TEST_END without a prior TEST_START")
            else:
                validate_test_end(rest, lineno, rep, runs)
                active_run = None

    # Post-parse: check for unclosed runs
    for mcu_id, run in runs.items():
        if not run.end_received:
            rep.warn(0, f"MCU {mcu_id!r}: TEST_START seen but no TEST_END (truncated capture?)")

    return runs


# ---------------------------------------------------------------------------
# Summary printer
# ---------------------------------------------------------------------------

def print_summary(runs: dict[str, MCURun], rep: Reporter):
    print()
    print("=" * 60)
    print("PARSED SUMMARY")
    print("=" * 60)

    if not runs:
        print("  (no valid test runs found)")
    else:
        for mcu_id, run in runs.items():
            passed = sum(1 for t in run.tests if t.status == 'PASS')
            failed = sum(1 for t in run.tests if t.status == 'FAIL')
            skipped = sum(1 for t in run.tests if t.status == 'SKIP')
            status_icon = '✅' if (failed == 0 and run.end_received) else ('❌' if failed else '⚠️')
            end_status = "complete" if run.end_received else "NO TEST_END"

            print(f"\n  MCU: {mcu_id}  (fw={run.fw_version or '?'})  [{end_status}]")
            print(f"  {status_icon}  Passed={passed}  Failed={failed}  Skipped={skipped}")

            if run.end_received:
                dur_ms = run.end_duration_us / 1000.0
                print(f"  Total duration: {dur_ms:.1f} ms")

            if run.tests:
                print("  Tests:")
                for t in run.tests:
                    icon = {'PASS': '✅', 'FAIL': '❌', 'SKIP': '⏭️'}.get(t.status, '?')
                    dur = (f"  {t.duration_us / 1000:.1f} ms" if t.duration_us is not None else '')
                    msg = (f"  → {t.message}" if t.message else '')
                    print(f"    {icon} {t.name}{dur}{msg}")

            if run.metrics:
                print("  Metrics:")
                for m in run.metrics:
                    print(f"    📊 {m.name} = {m.value} {m.unit}")

            if run.logs:
                print(f"  Logs ({len(run.logs)} message(s)):")
                for log in run.logs:
                    print(f"    💬 {log}")

    print()
    print("=" * 60)
    print("VALIDATION RESULT")
    print("=" * 60)

    if rep.errors:
        print(f"\n  ❌ {len(rep.errors)} error(s):")
        for e in rep.errors:
            print(e)

    if rep.warnings:
        print(f"\n  ⚠️  {len(rep.warnings)} warning(s):")
        for w in rep.warnings:
            print(w)

    if not rep.has_issues:
        print("\n  ✅ All lines valid — protocol compliant.")

    print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Validate a UART capture file against the PerformanceNode UART Result Protocol."
    )
    parser.add_argument(
        '--input', '-i',
        required=True,
        metavar='FILE',
        help="Path to UART capture file, or '-' to read from stdin."
    )
    parser.add_argument(
        '--strict',
        action='store_true',
        help="Strict mode: reject LOG lines and unknown message types as errors."
    )
    args = parser.parse_args()

    # Read input
    try:
        if args.input == '-':
            lines = sys.stdin.readlines()
            source = '<stdin>'
        else:
            with open(args.input, 'r', encoding='ascii', errors='replace') as fh:
                lines = fh.readlines()
            source = args.input
    except OSError as exc:
        print(f"ERROR: cannot open input: {exc}", file=sys.stderr)
        sys.exit(2)

    mode = "strict" if args.strict else "normal"
    print(f"Validating {source!r}  ({len(lines)} lines, mode={mode})")

    rep = Reporter()
    runs = parse_capture(lines, strict=args.strict, rep=rep)
    print_summary(runs, rep)

    sys.exit(1 if rep.has_issues else 0)


if __name__ == '__main__':
    main()
