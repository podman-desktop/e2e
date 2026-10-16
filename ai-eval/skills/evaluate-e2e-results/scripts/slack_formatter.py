#!/usr/bin/env python3
"""Transform evaluate-e2e-results JSON output into a Slack message.

The output is a flat ``{"<var>": "<text>"}`` payload for a Slack Workflow
Builder *webhook trigger* (``https://hooks.slack.com/triggers/...``). Triggers
ignore Block Kit and only read the variables defined on the trigger step, so the
report is collapsed into a single text variable (default name ``text``; the
workflow's own message step controls the final layout).

Usage:
  # Pipe from skill output (strips preamble automatically):
  claude --print ... | python3 slack_formatter.py | curl -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL"

  # From a saved file:
  python3 slack_formatter.py < evaluation.json

  # With optional args link and a custom variable name:
  python3 slack_formatter.py --artifacts-url "https://.../run-123" --workflow-var text < evaluation.json

Environment variables (optional):
  ARTIFACTS_URL       — link to full artifacts (S3, GHA run, etc.)
  PIPELINE_NAME       — pipeline identifier shown in header (e.g., "pde2e-prerelease-v1.30.1-libkrun-6.1.2-darwin-arm64-26.0.1")
  SLACK_WORKFLOW_VAR  — variable name for the payload (default: text)
"""
import json
import sys
import argparse
from collections import OrderedDict

KNOWN_BACKENDS = {"applehv", "libkrun", "hyperv", "wsl", "qemu"}

OS_LABEL = {"win32": "Windows", "darwin": "macOS", "linux": "Linux"}

CLASSIFICATION_LABEL = {
    "regression": "Regression",
    "test_bug": "Bug",
    "flaky": "Flaky",
    "infra": "Infra",
    "unknown": "Unknown",
}

NUMBER_EMOJI = ["1️⃣", "2️⃣", "3️⃣", "4️⃣",
                "5️⃣", "6️⃣", "7️⃣", "8️⃣",
                "9️⃣", "\U0001f51f"]


def extract_json(raw: str) -> dict:
    start = raw.find("{")
    if start < 0:
        raise ValueError("No JSON object found in input")
    return json.loads(raw[start:])


def _parse_backend(pipeline_name: str) -> str:
    if not pipeline_name:
        return ""
    for part in pipeline_name.lower().split("-"):
        if part in KNOWN_BACKENDS:
            return part
    return ""


def _short_spec(spec_file: str) -> str:
    if not spec_file:
        return ""
    return spec_file.rsplit("/", 1)[-1]


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut + "..." if cut else text[:limit] + "..."


def _group_failures(failures: list) -> list[list[dict]]:
    """Group failures that share the same title (preferred) or (classification, confidence)."""
    groups: OrderedDict[str, list[dict]] = OrderedDict()
    for f in failures:
        title = f.get("title", "")
        if title:
            key = title
        else:
            key = f"{f.get('classification', 'unknown')}|{f.get('confidence', 'uncertain')}"
        groups.setdefault(key, []).append(f)
    return list(groups.values())


def format_workflow_text(data: dict, artifacts_url: str | None = None, pipeline_name: str | None = None) -> str:
    s = data.get("summary", {})
    p = data.get("platform", {})
    sa = data.get("skipped_analysis") or {}

    failed = s.get("failed", 0)
    passed = s.get("passed", 0)
    skipped = s.get("skipped", 0)

    os_name = OS_LABEL.get(p.get("os", ""), p.get("os", "unknown"))
    backend = _parse_backend(pipeline_name)
    backend_suffix = f" ({backend})" if backend else ""

    if failed == 0:
        head = f"✅ {os_name} E2E Tests Passed{backend_suffix}"
    else:
        head = f"\U0001f6a8 {os_name} E2E Tests Failed{backend_suffix}"

    lines = [head]

    if pipeline_name:
        lines.append(f"\n{pipeline_name}")

    cascade = sa.get("cascade", 0)
    by_design = sa.get("by_design", 0)
    skip_detail = ""
    if skipped:
        if cascade:
            skip_detail = f" ({by_design} by design, {cascade} cascaded)"
        elif by_design:
            skip_detail = " (all by design)"

    counts = f"✅ {passed} Passed | ❌ {failed} Failed | ⚠️ {skipped} Skipped{skip_detail}"
    duration = s.get("duration_s", 0)
    if duration:
        counts += f" | ⏱ {int(duration // 60)}m {int(duration % 60)}s"
    lines.append(counts)

    failures = data.get("failures", []) or []
    groups = _group_failures(failures)

    for i, group in enumerate(groups):
        num = NUMBER_EMOJI[i] if i < len(NUMBER_EMOJI) else f"({i + 1})"
        first = group[0]
        classification = first.get("classification", "unknown")
        conf = first.get("confidence", "uncertain")
        label = CLASSIFICATION_LABEL.get(classification, classification.title())

        title = first.get("title", "")
        if not title:
            title = _truncate(first.get("root_cause", "Unknown"), 60)

        lines.append(f"\n{num} {label}: {title} [{classification}/{conf}]")

        root_cause = first.get("root_cause", "")
        if root_cause:
            lines.append(f"\n{_truncate(root_cause, 500)}")

        for f in group:
            test_name = f.get("test", "Unknown test")
            spec = _short_spec(f.get("spec_file", ""))
            line_num = f.get("line", "")
            loc = f"{spec}:{line_num}" if spec and line_num else spec
            action = f.get("recommended_action", "")

            bullet = f"\n• {test_name}"
            if loc:
                bullet += f" ({loc})"
            if action:
                bullet += f" └ _Fix:_ {_truncate(action, 200)}"
            lines.append(bullet)

    url = artifacts_url or p.get("ci_url", "")
    if url:
        lines.append(f"\n\U0001f517 <{url}|View Pipeline Logs & Artifacts>")

    return "\n".join(lines)


def main():
    import os
    parser = argparse.ArgumentParser(description="Transform evaluation JSON to a Slack workflow-trigger payload")
    parser.add_argument("--artifacts-url", default=None, help="URL to full test artifacts")
    parser.add_argument("--pipeline-name", default=None, help="Pipeline name for header")
    parser.add_argument(
        "--workflow-var", default=None,
        help="Variable name for the payload (default: env SLACK_WORKFLOW_VAR or 'text')",
    )
    args = parser.parse_args()

    artifacts_url = args.artifacts_url or os.environ.get("ARTIFACTS_URL")
    pipeline_name = args.pipeline_name or os.environ.get("PIPELINE_NAME")

    raw = sys.stdin.read()
    data = extract_json(raw)

    var = args.workflow_var or os.environ.get("SLACK_WORKFLOW_VAR") or "text"
    message = {var: format_workflow_text(data, artifacts_url, pipeline_name)}

    print(json.dumps(message, indent=2))


if __name__ == "__main__":
    main()
