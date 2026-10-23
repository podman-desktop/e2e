#!/usr/bin/env python3
"""Transform evaluate-e2e-results JSON into a Slack Workflow Builder message.

Reads evaluation JSON from stdin, writes a flat {"<var>": "<text>"} payload to stdout
suitable for a Slack Workflow Builder webhook trigger (not Block Kit).

Usage:
  <agent CLI, headless> ... | python3 slack_formatter.py | curl -X POST -H 'Content-type: application/json' -d @- "$WEBHOOK_URL"
  python3 slack_formatter.py --pipeline-name "pde2e-nightly-libkrun" --artifacts-url "https://..." < eval.json

Environment variables (substitute for CLI args):
  ARTIFACTS_URL       — link to full artifacts
  PIPELINE_NAME       — pipeline identifier (used to parse OS + backend)
  SLACK_WORKFLOW_VAR  — payload key (default: "text")
"""
import json
import os
import sys
import argparse
from collections import Counter

# Workflow Builder renders the variable as plain text — mrkdwn (*bold*, `code`,
# <url|label>) is NOT parsed, so this formatter emits plain text only. Unicode
# emoji and spacing do render, and are what carries the structure.

# classification -> (icon, verdict label, what it means for a release reader)
VERDICT = {
    "regression": ("⛔", "PRODUCT BUG", "a real bug in Podman Desktop"),
    "test_bug": ("🐛", "TEST BUG", "the test code is wrong, not the app"),
    "flaky": ("🔄", "FLAKY TEST", "timing-sensitive, not a product problem"),
    "infra": ("🚧", "INFRASTRUCTURE", "CI environment, not a product problem"),
    "unknown": ("❓", "NEEDS INVESTIGATION", "not enough evidence to classify"),
}

# confidence -> hedge applied to the verdict label
CONFIDENCE_PREFIX = {"confirmed": "", "likely": "LIKELY ", "uncertain": "POSSIBLY "}

# analysis layer -> what the verdict was actually based on
LAYER_BASIS = {1: "error context", 2: "app logs", 3: "trace analysis"}

RULE = "─" * 30

# Slack folds a long message behind "show more" and some workflow steps reject
# an oversized variable outright. Stay comfortably under 4000 characters.
MAX_TEXT_CHARS = int(os.environ.get("SLACK_MAX_CHARS") or 3500)

BACKEND_TOKENS = {
    "applehv": "Apple HV",
    "libkrun": "libkrun",
    "hyperv": "Hyper-V",
    "wsl": "WSL",
    "qemu": "QEMU",
}


def extract_json(raw: str) -> dict:
    """Decode the evaluation object, tolerating a ```json fence or stray prose.

    raw_decode stops at the end of the first JSON value, so trailing fences and
    commentary after the object are ignored.
    """
    start = raw.find("{")
    if start < 0:
        raise ValueError("No JSON object found in input")
    obj, _ = json.JSONDecoder().raw_decode(raw[start:])
    return obj


def _parse_pipeline(pipeline_name: str | None) -> tuple[str, str | None]:
    """Return (os_label, backend_label | None) from a pipeline name like
    'pde2e-prerelease-v1.30.1-libkrun-6.1.2-darwin-arm64-26.0.1'."""
    if not pipeline_name:
        return "E2E", None

    name_lower = pipeline_name.lower()
    if "darwin" in name_lower or "macos" in name_lower:
        os_label = "macOS"
    elif "win" in name_lower or "windows" in name_lower:
        os_label = "Windows"
    elif "linux" in name_lower:
        os_label = "Linux"
    else:
        os_label = "E2E"

    backend = None
    for token, label in BACKEND_TOKENS.items():
        if token in name_lower:
            backend = label
            break

    return os_label, backend


def _dedupe_failures(failures: list) -> list:
    """Collapse repeated entries for the same test into one, keeping the count.

    Playwright records one result per retry attempt. The skill is told to emit a
    single entry per test, but if it reports each attempt instead, the same test
    would be listed two or three times in the digest. Fold them here and keep
    the highest attempt count seen, so the reader learns the test failed on
    every retry — which is evidence against a flake.
    """
    occurrences = Counter()
    first: dict[tuple, dict] = {}
    ordered: list[dict] = []

    for f in failures:
        # Keyed on the test's identity — title, describe path, file — and
        # deliberately not on line: a retry can report a different failing line
        # (a later assertion got further), and keying on it would let the same
        # test through twice. The describe path is in the key because `test`
        # holds the bare title, which two suites in one file can share.
        key = (f.get("test"), f.get("suite"), f.get("spec_file"))
        occurrences[key] += 1
        if key not in first:
            entry = dict(f)
            first[key] = entry
            ordered.append(entry)

    for key, entry in first.items():
        try:
            declared = int(entry.get("attempts") or 1)
        except (TypeError, ValueError):
            declared = 1
        entry["attempts"] = max(declared, occurrences[key])

    return ordered


def _group_failures(failures: list) -> dict:
    """Group failures by title (preferred) or classification|confidence (fallback).
    Returns an OrderedDict-like list of (group_key, [failure, ...]) preserving insertion order."""
    groups: dict[str, list] = {}
    for f in failures:
        key = f.get("title") or f"{f.get('classification', 'unknown')}|{f.get('confidence', 'uncertain')}"
        groups.setdefault(key, []).append(f)
    return groups


def _truncate(text: str, max_len: int) -> str:
    """Trim to max_len, preferring a sentence end and never cutting mid-word."""
    if len(text) <= max_len:
        return text
    window = text[:max_len - 1]
    # Prefer ending on a sentence boundary if one sits in the last third.
    sentence_end = max(window.rfind(". "), window.rfind("; "))
    if sentence_end > max_len * 0.6:
        return window[:sentence_end].rstrip(",;:—- ") + "."
    space = window.rfind(" ")
    return (window[:space] if space > 0 else window).rstrip(",;:—- ") + "…"


def _triage(failures: list) -> tuple[str, list[str]]:
    """Return (headline verdict, per-bucket breakdown lines)."""
    counts: dict[str, int] = {}
    for f in failures:
        counts[f.get("classification", "unknown")] = counts.get(f.get("classification", "unknown"), 0) + 1

    def n(key: str) -> int:
        return counts.get(key, 0)

    product = n("regression")
    # "likely" is a hedge, and hedging a confirmed regression reads as a guess.
    # Only apply it when nothing in the product-bug bucket is confirmed.
    product_confirmed = sum(
        1 for f in failures
        if f.get("classification") == "regression" and f.get("confidence") == "confirmed"
    )

    if product:
        hedge = "" if product_confirmed else "likely "
        headline = (
            f"{product} {hedge}product bug{'s' if product != 1 else ''}"
            " — review before release"
        )
    elif n("unknown"):
        headline = f"{n('unknown')} failure(s) could not be classified — needs a look"
    elif n("test_bug"):
        headline = "test-code failures only — no product impact identified"
    elif n("infra") or n("flaky"):
        headline = "infrastructure/flake only — no product impact identified"
    else:
        headline = "no failures"

    breakdown = []
    for key in ("regression", "test_bug", "flaky", "infra", "unknown"):
        if n(key):
            icon, label, meaning = VERDICT[key]
            breakdown.append(f"{icon} {n(key)} {label.lower()} — {meaning}")

    # Only worth listing buckets when the failures are of mixed kinds — with a
    # single kind the headline already said it.
    return headline, breakdown if len(breakdown) > 1 else []


def _format_duration(duration_s: float) -> str:
    mins = int(duration_s // 60)
    secs = int(duration_s % 60)
    return f"{mins}m{secs}s" if mins else f"{secs}s"


def format_workflow_text(
    data: dict,
    artifacts_url: str | None = None,
    pipeline_name: str | None = None,
) -> str:
    s = data.get("summary", {})
    p = data.get("platform", {})
    failures = _dedupe_failures(data.get("failures", []))
    skipped_analysis = data.get("skipped_analysis")

    # A header that says "all tests passed" above a list of failures destroys
    # trust in the whole digest, so let the failures themselves win when the
    # summary disagrees with them.
    failed = s.get("failed", 0) or len(failures)
    total = s.get("total", 0)
    passed = s.get("passed", 0)
    skipped = s.get("skipped", 0)
    flaky = s.get("flaky", 0)
    duration_s = s.get("duration_s", 0)

    os_label, backend = _parse_pipeline(pipeline_name)
    # os_label is already "E2E" when the pipeline name says nothing about the OS.
    suite_label = "E2E Tests" if os_label == "E2E" else f"{os_label} E2E Tests"
    if backend:
        suite_label += f" ({backend})"

    lines = []

    # --- Header ---
    # "all 319 tests passed" above a stats line reading "63 skipped" is a false
    # claim, and these suites skip 60+ tests on a normal night. Only call it a
    # clean sweep when nothing was held back.
    if failed:
        lines.append(f"🚨 {suite_label} — {failed} failure{'s' if failed != 1 else ''}")
    elif skipped and (passed + flaky):
        lines.append(f"✅ {suite_label} — {passed + flaky} passed, {skipped} skipped")
    elif passed + flaky:
        lines.append(f"✅ {suite_label} — all {total} tests passed")
    else:
        # Nothing failed and nothing ran: a setup collapse, not a success.
        lines.append(f"⚠️ {suite_label} — no tests ran to completion")
    if pipeline_name:
        lines.append(pipeline_name)

    # --- Stats line ---
    cascade = skipped_analysis.get("cascade", 0) if skipped_analysis else 0
    by_design = skipped_analysis.get("by_design", 0) if skipped_analysis else 0

    skip_detail = ""
    if skipped:
        if cascade and by_design:
            skip_detail = f" ({by_design} by design, {cascade} cascaded)"
        elif cascade:
            skip_detail = f" ({cascade} cascaded)"
        else:
            skip_detail = " (all by design)"

    stat_parts = [
        f"✅ {passed} passed",
        f"❌ {failed} failed",
        f"⚠️ {skipped} skipped{skip_detail}",
    ]
    if duration_s:
        stat_parts.append(f"⏱ {_format_duration(duration_s)}")

    lines.append("   ".join(stat_parts))

    # --- Platform context ---
    ctx_parts = []
    if p.get("branch"):
        ctx_parts.append(f"branch {p['branch']}")
    if p.get("commit"):
        ctx_parts.append(f"commit {p['commit'][:8]}")
    if ctx_parts:
        lines.append("   ".join(ctx_parts))

    # --- Verdict: what kind of problem is this? ---
    if failures:
        headline, breakdown = _triage(failures)
        lines.append("")
        lines.append(f"VERDICT: {headline}")
        lines.extend(f"  {b}" for b in breakdown)
        if cascade:
            lines.append(
                f"  ⚠️ {cascade} further test{'s' if cascade != 1 else ''} never ran"
                " after an earlier failure — that coverage is unverified"
            )

    # --- Failures grouped by title ---
    # Each group is built as its own block so the length guard below can drop
    # whole failures off the end instead of cutting one in half.
    blocks: list[tuple[list[str], int]] = []
    if failures:
        groups = _group_failures(failures)

        for idx, (group_key, group_failures) in enumerate(groups.items()):
            block: list[str] = [""]
            blocks.append((block, len(group_failures)))
            rep = group_failures[0]
            classification = rep.get("classification", "unknown")
            confidence = rep.get("confidence", "uncertain")
            icon, label, _meaning = VERDICT.get(classification, VERDICT["unknown"])
            hedge = CONFIDENCE_PREFIX.get(confidence, "POSSIBLY ")

            block.append(RULE)
            title = group_key if rep.get("title") else "Unlabelled failure"
            block.append(f"{idx + 1}. {icon} {hedge}{label} — {title}")

            # Which tests this hit. Test name and location go on one line:
            # Slack renders this in a proportional font, so a wrapped line
            # restarts at column 0 and any column alignment is lost anyway —
            # fewer, shorter lines read better than aligned ones.
            for f in group_failures:
                spec = os.path.basename(f.get("spec_file", ""))
                line_no = f.get("line", "")
                loc = f"{spec}:{line_no}" if spec and line_no else spec
                parts = [f.get("test", "Unknown test")]
                if loc:
                    parts.append(loc)
                attempts = f.get("attempts", 1)
                if attempts > 1:
                    parts.append(f"failed {attempts}/{attempts} attempts")
                block.append("• " + "  ·  ".join(parts))

            root_cause = _truncate(rep.get("root_cause", "No root cause determined"), 320)
            block.append(f"Why: {root_cause}")

            action = _truncate(rep.get("recommended_action", ""), 200)
            if action:
                block.append(f"Next: {action}")

            layer = rep.get("layer")
            if layer:
                block.append(f"Basis: {LAYER_BASIS.get(layer, 'error context')} (layer {layer})")

    # --- Footer ---
    foot: list[str] = []
    # The evaluator caps how many failures it analyses. Saying so keeps the
    # reader from treating the list above as the whole picture.
    dropped = data.get("truncated_count", 0) if data.get("truncated") else 0
    if artifacts_url:
        foot.append(f"🔗 Logs & artifacts: {artifacts_url}")
    if p.get("ci_url") and p.get("ci_url") != artifacts_url:
        foot.append(f"🔗 CI run: {p['ci_url']}")

    # --- Fit within the message limit ---
    # Slack truncates a long message behind a "show more" fold, and the links in
    # the footer are the one thing that must survive. Drop whole failure blocks
    # from the end until the text fits, and say how many went missing — a digest
    # that silently loses its last three failures is worse than one that admits
    # it. Failures are already ordered by the evaluator, worst first.
    head_text = "\n".join(lines)
    omitted = dropped
    while True:
        notes = (
            [f"⚠️ {omitted} further failure(s) not shown — see the full artifacts"]
            if omitted else []
        )
        body = ["\n".join(b) for b, _ in blocks]
        text = "\n".join([head_text] + body + [""] + notes + foot).strip()
        if len(text) <= MAX_TEXT_CHARS or not blocks:
            return text
        omitted += blocks.pop()[1]


def main():
    parser = argparse.ArgumentParser(description="Transform evaluation JSON to Slack Workflow Builder payload")
    parser.add_argument("--artifacts-url", default=None, help="URL to full test artifacts")
    parser.add_argument("--pipeline-name", default=None, help="Pipeline name (used to parse OS + backend)")
    parser.add_argument("--workflow-var", default=None, help="Payload key name (default: 'text')")
    args = parser.parse_args()

    artifacts_url = args.artifacts_url or os.environ.get("ARTIFACTS_URL")
    pipeline_name = args.pipeline_name or os.environ.get("PIPELINE_NAME")
    workflow_var = args.workflow_var or os.environ.get("SLACK_WORKFLOW_VAR") or "text"

    raw = sys.stdin.read()
    data = extract_json(raw)

    text = format_workflow_text(data, artifacts_url, pipeline_name)
    print(json.dumps({workflow_var: text}, ensure_ascii=False))


if __name__ == "__main__":
    main()
