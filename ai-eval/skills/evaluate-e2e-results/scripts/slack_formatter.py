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
  PIPELINE_NAME       — pipeline identifier shown in header (e.g., "pd-e2e-podman macOS applehv")
  SLACK_WORKFLOW_VAR  — variable name for the payload (default: text)
"""
import json
import sys
import argparse

CLASSIFICATION_EMOJI = {
    "regression": "⛔",   # ⛔
    "test_bug": "\U0001f41b", # 🐛
    "flaky": "\U0001f504",    # 🔄
    "infra": "\U0001f6a7",    # 🚧
    "unknown": "❓",      # ❓
}

CONFIDENCE_LABEL = {
    "confirmed": "confirmed",
    "likely": "likely",
    "uncertain": "uncertain",
}


def extract_json(raw: str) -> dict:
    start = raw.find("{")
    if start < 0:
        raise ValueError("No JSON object found in input")
    return json.loads(raw[start:])


def format_workflow_text(data: dict, artifacts_url: str | None = None, pipeline_name: str | None = None) -> str:
    """Collapse the report into a single plain-text block for a Workflow trigger.

    Block Kit is not available through Workflow Builder triggers, so this renders
    a readable, newline-delimited digest that the workflow's message step can
    drop into a variable.
    """
    s = data.get("summary", {})
    p = data.get("platform", {})

    failed = s.get("failed", 0)
    total = s.get("total", 0)
    passed = s.get("passed", 0)
    skipped = s.get("skipped", 0)

    os_name = (p.get("os", "unknown")).replace("win32", "Windows").replace("darwin", "macOS").replace("linux", "Linux")
    arch = p.get("arch", "")

    status_emoji = "✅" if failed == 0 else "❌"
    status_text = "All tests passed" if failed == 0 else f"{failed} failure{'s' if failed != 1 else ''}"

    head = f"{status_emoji} {pipeline_name}: {status_text}" if pipeline_name else f"{status_emoji} E2E Results: {status_text}"

    lines = [head]

    counts = f"{total} total | {passed} passed | {failed} failed | {skipped} skipped | {os_name}/{arch}"
    duration = s.get("duration_s", 0)
    if duration:
        counts += f" | duration: {int(duration // 60)}m{int(duration % 60)}s"
    lines.append(counts)

    for f in data.get("failures", []) or []:
        emoji = CLASSIFICATION_EMOJI.get(f.get("classification", "unknown"), "❓")
        conf = CONFIDENCE_LABEL.get(f.get("confidence", ""), f.get("confidence", ""))
        classification = f.get("classification", "unknown")
        test_name = f.get("test", "Unknown test")
        spec = f.get("spec_file", "")
        line = f.get("line", "")
        loc = f"{spec}:{line}" if spec and line else spec

        root_cause = f.get("root_cause", "No root cause determined")
        if len(root_cause) > 400:
            root_cause = root_cause[:397] + "..."
        action = f.get("recommended_action", "")
        if len(action) > 300:
            action = action[:297] + "..."

        lines.append("")
        lines.append(f"{emoji} {test_name} [{classification}/{conf}]")
        lines.append(f"   {root_cause}")
        if loc:
            lines.append(f"   {loc}")
        if action:
            lines.append(f"   🔧 {action}")

    sa = data.get("skipped_analysis") or {}
    st = sa.get("total_skipped", 0)
    if st:
        cascade = sa.get("cascade", 0)
        by_design = sa.get("by_design", 0)
        if cascade == 0:
            lines.append(f"\n💭 Skipped: {st} (all by design)")
        else:
            lines.append(f"\n⚠️ Skipped: {st} total — {by_design} by design, {cascade} cascade from failures")

    if artifacts_url:
        lines.append(f"\nArtifacts: {artifacts_url}")
    elif p.get("ci_url"):
        lines.append(f"\nCI run: {p['ci_url']}")

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
