#!/usr/bin/env python3
"""parse-results.py — Parse MCU UART output files and write GitHub Actions outputs.

Reads one output file per MCU target (written by read-uart.py), parses the
test protocol, writes step outputs to $GITHUB_OUTPUT, and writes a Markdown
step summary to $GITHUB_STEP_SUMMARY.

Usage:
    python3 parse-results.py --targets rp2040-0,rp2040-1,rp2350b,rp2350a
                             --uart-output-dir <dir>
                             --github-output <path>
                             --github-step-summary <path>

UART protocol (placeholder — Wufei is finalising):
    TEST_START:{target}:{firmware_version}
    PASS:{test_name}:{duration_ms}
    FAIL:{test_name}:{duration_ms}:{error_message}
    SKIP:{test_name}:{reason}
    TEST_END:{target}:{passed}/{total}:{total_ms}

Exit codes:
    0  Parsing complete (individual MCU failures do NOT change exit code here)
    2  Configuration error
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# ── Types ──────────────────────────────────────────────────────────────────────

TestEntry = dict[str, Any]  # { name, result, duration_ms, detail }
MCUResult = dict[str, Any]  # see _empty_result()


def _empty_result(target: str) -> MCUResult:
    return {
        "target": target,
        "status": "error",       # pass | fail | timeout | partial | error
        "firmware_version": "",
        "passed": 0,
        "failed": 0,
        "skipped": 0,
        "total": 0,
        "duration_ms": 0,
        "tests": [],
    }


# ── Parser ────────────────────────────────────────────────────────────────────

def _parse_file(target: str, path: Path) -> MCUResult:
    result = _empty_result(target)

    if not path.exists():
        result["status"] = "error"
        result["_detail"] = f"Output file not found: {path}"
        return result

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines:
        result["status"] = "timeout"
        return result

    started = False
    ended = False

    for line in lines:
        line = line.strip()
        if not line:
            continue

        if line.startswith("TEST_START:"):
            started = True
            parts = line.split(":", 2)
            if len(parts) >= 3:
                result["firmware_version"] = parts[2]
            continue

        if not started:
            continue

        if line.startswith("PASS:"):
            parts = line.split(":", 2)
            test_name = parts[1] if len(parts) > 1 else "unknown"
            duration = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
            result["tests"].append({"name": test_name, "result": "pass", "duration_ms": duration, "detail": ""})
            result["passed"] += 1

        elif line.startswith("FAIL:"):
            parts = line.split(":", 3)
            test_name = parts[1] if len(parts) > 1 else "unknown"
            duration = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
            detail = parts[3] if len(parts) > 3 else ""
            result["tests"].append({"name": test_name, "result": "fail", "duration_ms": duration, "detail": detail})
            result["failed"] += 1

        elif line.startswith("SKIP:"):
            parts = line.split(":", 2)
            test_name = parts[1] if len(parts) > 1 else "unknown"
            reason = parts[2] if len(parts) > 2 else ""
            result["tests"].append({"name": test_name, "result": "skip", "duration_ms": 0, "detail": reason})
            result["skipped"] += 1

        elif line.startswith("TEST_END:"):
            ended = True
            parts = line.split(":")
            # TEST_END:{target}:{passed}/{total}:{total_ms}
            if len(parts) >= 4:
                try:
                    result["duration_ms"] = int(parts[3])
                except ValueError:
                    pass

    result["total"] = result["passed"] + result["failed"] + result["skipped"]

    if not started:
        result["status"] = "timeout"
    elif not ended:
        result["status"] = "partial"
    elif result["failed"] > 0:
        result["status"] = "fail"
    else:
        result["status"] = "pass"

    return result


# ── Output writers ────────────────────────────────────────────────────────────

def _write_github_output(
    results: dict[str, MCUResult],
    github_output_path: Path,
) -> None:
    """Append key=value pairs to $GITHUB_OUTPUT."""
    passed_count = sum(1 for r in results.values() if r["status"] == "pass")
    failed_count = len(results) - passed_count

    # Build summary string
    if failed_count == 0:
        summary = f"All {len(results)} MCUs passed"
    else:
        failed_names = [
            f"{r['target']} ({r['failed']} test failure{'s' if r['failed'] != 1 else ''})"
            if r["status"] == "fail"
            else f"{r['target']} ({r['status']})"
            for r in results.values()
            if r["status"] != "pass"
        ]
        summary = f"{passed_count}/{len(results)} MCUs passed ({', '.join(failed_names)} failed)"

    results_json = json.dumps(results, separators=(",", ":"))

    # GitHub output values must not contain literal newlines; use %0A encoding for multiline
    with github_output_path.open("a", encoding="utf-8") as fh:
        fh.write(f"results-json={results_json}\n")
        fh.write(f"passed={passed_count}\n")
        fh.write(f"failed={failed_count}\n")
        fh.write(f"summary={summary}\n")


def _status_badge(results: dict[str, MCUResult]) -> str:
    failed = sum(1 for r in results.values() if r["status"] != "pass")
    total = len(results)
    if failed == 0:
        return "✅ All passed"
    if failed == total:
        return f"❌ All {total} failed"
    return f"⚠️ {total - failed}/{total} passed"


def _result_icon(status: str) -> str:
    return {"pass": "✅", "fail": "❌", "timeout": "⏱️", "partial": "⚠️", "error": "💥"}.get(status, "❓")


def _write_step_summary(
    results: dict[str, MCUResult],
    summary_path: Path,
) -> None:
    """Write a Markdown step summary to $GITHUB_STEP_SUMMARY."""
    lines: list[str] = []
    lines.append("## MCU Performance Test Results\n")
    lines.append(f"**Overall:** {_status_badge(results)}\n")
    lines.append("")

    # Per-MCU summary table
    lines.append("| MCU | Status | Pass | Fail | Skip | Duration |")
    lines.append("|-----|--------|------|------|------|----------|")
    for r in results.values():
        icon = _result_icon(r["status"])
        dur = f"{r['duration_ms']} ms" if r["duration_ms"] else "—"
        lines.append(
            f"| `{r['target']}` | {icon} {r['status']} | {r['passed']} | {r['failed']} | {r['skipped']} | {dur} |"
        )
    lines.append("")

    # Per-MCU expandable test details
    for r in results.values():
        tests: list[TestEntry] = r.get("tests", [])
        icon = _result_icon(r["status"])
        fw = r.get("firmware_version", "")
        fw_tag = f" — firmware `{fw}`" if fw else ""
        lines.append(f"<details>")
        lines.append(f"<summary>{icon} <strong>{r['target']}</strong>{fw_tag} — {r['passed']}✅ {r['failed']}❌ {r['skipped']}⏭️</summary>")
        lines.append("")
        if not tests:
            lines.append(f"_No test data ({r['status']})._")
        else:
            lines.append("| Test | Result | Duration | Detail |")
            lines.append("|------|--------|----------|--------|")
            for t in tests:
                t_icon = {"pass": "✅", "fail": "❌", "skip": "⏭️"}.get(t["result"], "❓")
                dur = f"{t['duration_ms']} ms" if t["duration_ms"] else "—"
                detail = t.get("detail", "") or "—"
                lines.append(f"| `{t['name']}` | {t_icon} | {dur} | {detail} |")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    summary_path.write_text("\n".join(lines), encoding="utf-8")


# ── CLI ────────────────────────────────────────────────────────────────────────

def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Parse MCU UART output files and write GitHub Actions outputs."
    )
    parser.add_argument(
        "--targets",
        required=True,
        help="Comma-separated list of MCU target names",
    )
    parser.add_argument(
        "--uart-output-dir",
        required=True,
        type=Path,
        help="Directory containing per-target UART output files ({target}.txt)",
    )
    parser.add_argument(
        "--github-output",
        required=True,
        type=Path,
        help="Path to $GITHUB_OUTPUT file",
    )
    parser.add_argument(
        "--github-step-summary",
        required=True,
        type=Path,
        help="Path to $GITHUB_STEP_SUMMARY file",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()

    targets = [t.strip() for t in args.targets.split(",") if t.strip()]
    if not targets:
        print("ERROR: No targets specified.", file=sys.stderr)
        sys.exit(2)

    results: dict[str, MCUResult] = {}
    for target in targets:
        output_file = args.uart_output_dir / f"{target}.txt"
        result = _parse_file(target, output_file)
        results[target] = result
        icon = _result_icon(result["status"])
        print(f"  {icon} {target}: {result['status']} ({result['passed']}✅ {result['failed']}❌ {result['skipped']}⏭️)")

    try:
        _write_github_output(results, args.github_output)
    except OSError as exc:
        print(f"WARNING: Could not write to GITHUB_OUTPUT ({args.github_output}): {exc}", file=sys.stderr)

    try:
        _write_step_summary(results, args.github_step_summary)
    except OSError as exc:
        print(f"WARNING: Could not write to GITHUB_STEP_SUMMARY ({args.github_step_summary}): {exc}", file=sys.stderr)

    failed_count = sum(1 for r in results.values() if r["status"] != "pass")
    if failed_count > 0:
        print(f"\n{failed_count}/{len(results)} MCU(s) did not pass.")
    else:
        print(f"\nAll {len(results)} MCU(s) passed.")

    sys.exit(0)  # parsing itself always exits 0; callers check 'failed' output


if __name__ == "__main__":
    main()
