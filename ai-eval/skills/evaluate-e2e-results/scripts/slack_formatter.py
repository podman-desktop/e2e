#!/usr/bin/env python3
"""Transform evaluate-e2e-results JSON into a Slack Workflow Builder message.

Reads evaluation JSON from stdin, writes a flat {"<var>": "<text>"} payload to stdout
suitable for a Slack Workflow Builder webhook trigger (not Block Kit).

Usage:
  claude --print ... | python3 slack_formatter.py | curl -X POST -H 'Content-type: application/json' -d @- "$WEBHOOK_URL"
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
from itertools import islice

CLASSIFICATION_EMOJI = {
    "regression": "⛔",
    "test_bug": "🐛",
    "flaky": "🔄",
    "infra": "🚧",
    "unknown": "❓",
}

CLASSIFICATION_LABEL = {
    "regression": "Regression",
    "test_bug": "Bug",
    "flaky": "Flaky",
    "infra": "Infra",
    "unknown": "Unknown",
}

NUMBER_EMOJI = ["1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣", "🔟"]

BACKEND_TOKENS = {
    "applehv": "Apple HV",
    "libkrun": "libkrun",
    "hyperv": "Hyper-V",
    "wsl": "WSL",
    "qemu": "QEMU",
}


def extract_json(raw: str) -> dict:
    start = raw.find("{")
    if start < 0:
        raise ValueError("No JSON object found in input")
    return json.loads(raw[start:])


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


def _group_failures(failures: list) -> dict:
    """Group failures by title (preferred) or classification|confidence (fallback).
    Returns an OrderedDict-like list of (group_key, [failure, ...]) preserving insertion order."""
    groups: dict[str, list] = {}
    for f in failures:
        key = f.get("title") or f"{f.get('classification', 'unknown')}|{f.get('confidence', 'uncertain')}"
        groups.setdefault(key, []).append(f)
    return groups


def _truncate(text: str, max_len: int) -> str:
    return text if len(text) <= max_len else text[:max_len - 3] + "..."


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
    failures = data.get("failures", [])
    skipped_analysis = data.get("skipped_analysis")

    failed = s.get("failed", 0)
    total = s.get("total", 0)
    passed = s.get("passed", 0)
    skipped = s.get("skipped", 0)
    duration_s = s.get("duration_s", 0)

    os_label, backend = _parse_pipeline(pipeline_name)
    suite_label = f"{os_label} E2E Tests"
    if backend:
        suite_label += f" ({backend})"

    lines = []

    # --- Header ---
    if failed == 0:
        lines.append(f"✅ *{suite_label}: All {total} tests passed*")
    else:
        lines.append(f"🚨 *{suite_label}: {failed} failure{'s' if failed != 1 else ''}*")
    if pipeline_name:
        lines.append(f"`{pipeline_name}`")

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
        f"✅ {passed} Passed",
        f"❌ {failed} Failed",
        f"⚠️ {skipped} Skipped{skip_detail}",
    ]
    if duration_s:
        stat_parts.append(f"⏱ {_format_duration(duration_s)}")

    lines.append(" | ".join(stat_parts))

    # --- Platform context ---
    ctx_parts = []
    if p.get("branch"):
        ctx_parts.append(f"branch: `{p['branch']}`")
    if p.get("commit"):
        ctx_parts.append(f"commit: `{p['commit'][:8]}`")
    if ctx_parts:
        lines.append(" | ".join(ctx_parts))

    # --- Failures grouped by title ---
    if failures:
        lines.append("")
        groups = _group_failures(failures)

        for idx, (group_key, group_failures) in enumerate(groups.items()):
            num = NUMBER_EMOJI[idx] if idx < len(NUMBER_EMOJI) else f"({idx + 1})"
            rep = group_failures[0]
            classification = rep.get("classification", "unknown")
            confidence = rep.get("confidence", "uncertain")

            cls_label = CLASSIFICATION_LABEL.get(classification, classification.title())
            if rep.get("title"):
                group_label = f"{cls_label}: {group_key} [{classification}/{confidence}]"
            else:
                group_label = f"{cls_label}: {classification}/{confidence}"
            lines.append(f"{num} *{group_label}*")

            root_cause = _truncate(rep.get("root_cause", "No root cause determined"), 500)
            lines.append(f"> {root_cause}")

            for f in group_failures:
                test_name = f.get("test", "Unknown test")
                spec = f.get("spec_file", "")
                line_no = f.get("line", "")
                loc = f"{spec}:{line_no}" if spec and line_no else spec
                action = _truncate(f.get("recommended_action", ""), 300)

                bullet = f"• {test_name}"
                if loc:
                    bullet += f" `{loc}`"
                lines.append(bullet)
                if action:
                    lines.append(f"  └ _Fix:_ {action}")

            lines.append("")

    # --- Footer ---
    if artifacts_url:
        lines.append(f"🔗 <{artifacts_url}|View Pipeline Logs & Artifacts>")
    if p.get("ci_url") and p.get("ci_url") != artifacts_url:
        lines.append(f"🔗 <{p['ci_url']}|View CI Run>")

    return "\n".join(lines).strip()


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
