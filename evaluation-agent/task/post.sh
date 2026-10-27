#!/usr/bin/env bash
# Post-check for the evaluation bundle, run by agent-runner after the model:
#   post.sh <report.json> <results-dir>
# 1. The report must agree with json-results.json, so a hallucinated or
#    truncated triage never reaches Slack.
# 2. Writes the Slack digest text to $AGENT_SUMMARY_FILE.
set -euo pipefail

report="$1"
results="$2/json-results.json"
formatter=/etc/codex/skills/evaluate-e2e-results/scripts/slack_formatter.py

[[ -r "$results" ]] || { echo "ERROR: no readable $results" >&2; exit 1; }

# Playwright stats: expected=passed, unexpected=failed; duration is in ms.
if ! problems="$(jq -nr --slurpfile r "$report" --slurpfile s "$results" '
  ($r[0]) as $r | ($s[0].stats // {}) as $st
  | {passed: ($st.expected // 0), failed: ($st.unexpected // 0),
     skipped: ($st.skipped // 0), flaky: ($st.flaky // 0)} as $want
  | ($want + {total: ($want | add)}) as $want
  | [ ($want | to_entries[]
        | select($r.summary[.key] != .value)
        | "summary.\(.key) is \($r.summary[.key]), json-results.json says \(.value)"),
      (if ((($r.summary.duration_s // -1) - (($st.duration // 0) / 1000)) | fabs) > 0.02
       then "summary.duration_s does not match json-results.json" else empty end),
      (if $r.summary.failed > 0 and ($r.failures | length) == 0
       then "summary reports failures but failures is empty" else empty end),
      (if $r.summary.skipped > 0 and ($r.skipped_analysis | type) != "object"
       then "summary reports skipped tests but skipped_analysis is null" else empty end)
    ] | .[]')"; then
  echo "ERROR: could not compare the report with $results" >&2
  exit 1
fi
if [[ -n "$problems" ]]; then
  printf 'ERROR: report does not match the test results:\n%s\n' "$problems" >&2
  exit 1
fi

# The schema needs every key; the skill's convention is to omit unknown ones.
# Keep the digest well under the Tekton result limit.
jq '
  if .skipped_analysis == null then del(.skipped_analysis) else . end
  | .platform |= with_entries(select(.value != null))
  | if .platform == {} then del(.platform) else . end
  | if .truncated == false then del(.truncated, .truncated_count) else . end
' "$report" \
  | SLACK_MAX_CHARS=1500 python3 "$formatter" \
  | jq -r '.text' >"$AGENT_SUMMARY_FILE"
