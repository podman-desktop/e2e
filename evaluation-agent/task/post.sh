#!/usr/bin/env bash
# Post-check for the evaluation bundle, run by agent-runner after the model:
#   post.sh <report.json> <results-dir>
# 1. The report must agree with json-results.json, so a hallucinated or
#    truncated triage never reaches Slack.
# 2. Writes the digest overview to $AGENT_SUMMARY_FILE and, when OUTPUT_DIR is
#    set, every failure as Slack messages to $OUTPUT_DIR/digest.json.
set -euo pipefail

report="$1"
results="$2/json-results.json"
formatter=/etc/codex/skills/evaluate-e2e-results/scripts/slack_formatter.py

[[ -r "$results" ]] || { echo "ERROR: no readable $results" >&2; exit 1; }

# Playwright stats: expected=passed, unexpected=failed; duration is in ms.
# A failed test is matched by title and spec file name: the report has
# repo-relative paths, json-results.json paths relative to the test dir, with
# `\` on Windows. The skill lists every failed test, up to its 20-failure
# budget; past it, truncated_count must account for each one it left out.
# A globalSetup error fails the run before any test exists to count, so it is
# only in the top-level errors, and the skill reports it as a failure.
if ! problems="$(jq -nr --slurpfile r "$report" --slurpfile s "$results" '
  def key: [.[0], ((.[1] // "") | gsub("\\\\"; "/") | split("/") | last)];
  ($r[0]) as $r | ($s[0].stats // {}) as $st
  | {passed: ($st.expected // 0), failed: ($st.unexpected // 0),
     skipped: ($st.skipped // 0), flaky: ($st.flaky // 0)} as $want
  | ($want + {total: ($want | add)}) as $want
  | [$s[0] | .. | objects | select(has("specs")) | .specs[]? | . as $spec
     | .tests[]? | select(.status == "unexpected")
     | [$spec.title, $spec.file] | key] as $failed
  | ($failed | unique) as $failed_keys
  | [$r.failures[]? | [.test, .spec_file] | key] as $listed
  | ($failed_keys - $listed) as $missing
  | [$listed[] | select(IN($failed_keys[]))] as $matched
  | (($s[0].errors // []) | length) as $errors
  | [ ($want | to_entries[]
        | select($r.summary[.key] != .value)
        | "summary.\(.key) is \($r.summary[.key]), json-results.json says \(.value)"),
      (if ((($r.summary.duration_s // -1) - (($st.duration // 0) / 1000)) | fabs) > 0.02
       then "summary.duration_s does not match json-results.json" else empty end),
      (if $r.summary.failed > 0 and ($r.failures | length) == 0
       then "summary reports failures but failures is empty" else empty end),
      (if $errors > 0 and ($r.failures | length) == 0
       then "json-results.json has \($errors) top-level error(s) but failures is empty"
       else empty end),
      (if $r.truncated == true then
         (if ($matched | length) + ($r.truncated_count // 0) != ($failed | length)
          then "failures lists \($matched | length) failed test(s) and truncated_count says \($r.truncated_count // 0) more, json-results.json has \($failed | length)"
          else empty end)
       elif ($missing | length) > 0
       then "failures omits \($missing | length) failed test(s): "
            + ($missing[:5] | map("\(.[1]): \(.[0])") | join("; "))
       else empty end),
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
# Also from the results, which are ground truth: when the run started, and,
# when the skill hit its failure budget, the failed tests it never reached,
# so the digest can still name them (title, file and line; no verdict).
evaluation="$(jq --slurpfile s "$results" '
  if .skipped_analysis == null then del(.skipped_analysis) else . end
  | .platform |= with_entries(select(.value != null))
  | if .platform == {} then del(.platform) else . end
  | if .truncated == false then del(.truncated, .truncated_count) else . end
  | ($s[0].stats.startTime // null) as $started
  | if $started then .run_started = $started else . end
  | if .truncated then
      .unanalysed = ([$s[0] | .. | objects | select(has("specs")) | .specs[]?
                      | select(any(.tests[]?; .status == "unexpected"))
                      | {test: .title, spec_file: ((.file // "") | gsub("\\\\"; "/")),
                         line: .line}] | .[:500])
    else . end
' "$report")"

# The bounded digest is the summary result: the overview alone, fitted to the
# result limit as Tekton measures it (JSON-encoded), like the entrypoint does.
python3 "$formatter" --max-bytes "${AGENT_SUMMARY_MAX_BYTES:-3072}" <<<"$evaluation" \
  | jq -j '.text' >"$AGENT_SUMMARY_FILE"

# The full digest goes to OUTPUT_DIR when the run publishes outputs: every
# failure, in Slack-sized messages, for post-evaluation-to-slack to send.
if [[ -n "${OUTPUT_DIR:-}" ]]; then
  python3 "$formatter" --split-chars "${SLACK_SPLIT_CHARS:-3500}" <<<"$evaluation" \
    >"$OUTPUT_DIR/digest.json"
fi
