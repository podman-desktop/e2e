#!/usr/bin/env python3
"""Transform evaluate-e2e-results JSON output into Slack Block Kit message.

Usage:
  # Pipe from skill output (strips preamble automatically):
  claude --print ... | python3 slack_formatter.py | curl -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL"

  # From a saved file:
  python3 slack_formatter.py < evaluation.json

  # With optional args link:
  python3 slack_formatter.py --artifacts-url "https://s3.example.com/results/run-123" < evaluation.json

Environment variables (optional):
  ARTIFACTS_URL  — link to full artifacts (S3, GHA run, etc.)
  PIPELINE_NAME  — pipeline identifier shown in header (e.g., "pd-e2e-podman macOS applehv")
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


def build_header(data: dict, pipeline_name: str | None) -> dict:
    s = data.get("summary", {})
    p = data.get("platform", {})

    failed = s.get("failed", 0)
    total = s.get("total", 0)
    passed = s.get("passed", 0)
    skipped = s.get("skipped", 0)

    os_name = (p.get("os", "unknown")).replace("win32", "Windows").replace("darwin", "macOS").replace("linux", "Linux")
    arch = p.get("arch", "")

    if failed == 0:
        status_emoji = "✅"  # ✅
        status_text = "All tests passed"
    else:
        status_emoji = "❌"  # ❌
        status_text = f"{failed} failure{'s' if failed != 1 else ''}"

    title = f"{status_emoji} E2E Results: {status_text}"
    if pipeline_name:
        title = f"{status_emoji} {pipeline_name}: {status_text}"

    header = {
        "type": "header",
        "text": {"type": "plain_text", "text": title[:150], "emoji": True},
    }

    context_parts = [f"*{total}* total | *{passed}* passed | *{failed}* failed | *{skipped}* skipped"]
    context_parts.append(f"{os_name}/{arch}")

    if p.get("branch"):
        context_parts.append(f"branch: `{p['branch']}`")
    if p.get("commit"):
        context_parts.append(f"commit: `{p['commit'][:8]}`")

    duration = s.get("duration_s", 0)
    if duration:
        mins = int(duration // 60)
        secs = int(duration % 60)
        context_parts.append(f"duration: {mins}m{secs}s")

    context = {
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": " | ".join(context_parts)}],
    }

    return [header, context]


def build_failure_blocks(failures: list) -> list:
    if not failures:
        return []

    blocks = [{"type": "divider"}]

    for f in failures:
        emoji = CLASSIFICATION_EMOJI.get(f.get("classification", "unknown"), "❓")
        conf = CONFIDENCE_LABEL.get(f.get("confidence", ""), f.get("confidence", ""))
        classification = f.get("classification", "unknown")

        test_name = f.get("test", "Unknown test")
        spec = f.get("spec_file", "")
        line = f.get("line", "")
        loc = f"{spec}:{line}" if spec and line else spec

        title = f"{emoji} *{test_name}*  [{classification}/{conf}]"

        root_cause = f.get("root_cause", "No root cause determined")
        if len(root_cause) > 300:
            root_cause = root_cause[:297] + "..."

        action = f.get("recommended_action", "")
        if len(action) > 200:
            action = action[:197] + "..."

        text_parts = [f"> {root_cause}"]
        if loc:
            text_parts.append(f"_`{loc}`_")
        if action:
            text_parts.append(f"\U0001f527 {action}")  # 🔧

        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"{title}\n" + "\n".join(text_parts)},
        })

    return blocks


def build_skipped_blocks(skipped_analysis: dict | None) -> list:
    if not skipped_analysis:
        return []

    total = skipped_analysis.get("total_skipped", 0)
    cascade = skipped_analysis.get("cascade", 0)
    by_design = skipped_analysis.get("by_design", 0)

    if total == 0:
        return []

    if cascade == 0:
        text = f"\U0001f4ad *Skipped tests:* {total} (all by design)"
        return [{"type": "context", "elements": [{"type": "mrkdwn", "text": text}]}]

    blocks = [{"type": "divider"}]

    text = f"⚠️ *Skipped tests:* {total} total — *{by_design}* by design, *{cascade}* cascade from failures"

    cascade_details = skipped_analysis.get("cascade_details", [])
    if cascade_details:
        grouped = {}
        for d in cascade_details:
            cause = d.get("caused_by_failure", "unknown")
            grouped.setdefault(cause, []).append(d.get("skipped_test", "?"))

        lines = [text]
        for cause, skipped_tests in grouped.items():
            names = ", ".join(skipped_tests[:3])
            if len(skipped_tests) > 3:
                names += f" +{len(skipped_tests) - 3} more"
            lines.append(f"  └ _{cause}_ → skipped: {names}")

        text = "\n".join(lines)

    blocks.append({
        "type": "section",
        "text": {"type": "mrkdwn", "text": text},
    })

    return blocks


def build_footer(data: dict, artifacts_url: str | None) -> list:
    blocks = []
    p = data.get("platform", {})

    elements = []
    if artifacts_url:
        elements.append({"type": "mrkdwn", "text": f"<{artifacts_url}|View full artifacts>"})
    if p.get("ci_url"):
        elements.append({"type": "mrkdwn", "text": f"<{p['ci_url']}|View CI run>"})

    if elements:
        blocks.append({"type": "context", "elements": elements})

    return blocks


def format_slack_message(data: dict, artifacts_url: str | None = None, pipeline_name: str | None = None) -> dict:
    blocks = []
    blocks.extend(build_header(data, pipeline_name))
    blocks.extend(build_failure_blocks(data.get("failures", [])))
    blocks.extend(build_skipped_blocks(data.get("skipped_analysis")))
    blocks.extend(build_footer(data, artifacts_url))

    return {"blocks": blocks}


def main():
    parser = argparse.ArgumentParser(description="Transform evaluation JSON to Slack Block Kit")
    parser.add_argument("--artifacts-url", default=None, help="URL to full test artifacts")
    parser.add_argument("--pipeline-name", default=None, help="Pipeline name for header")
    args = parser.parse_args()

    import os
    artifacts_url = args.artifacts_url or os.environ.get("ARTIFACTS_URL")
    pipeline_name = args.pipeline_name or os.environ.get("PIPELINE_NAME")

    raw = sys.stdin.read()
    data = extract_json(raw)

    message = format_slack_message(data, artifacts_url, pipeline_name)
    print(json.dumps(message, indent=2))


if __name__ == "__main__":
    main()
