#!/usr/bin/env bash
# Evaluation-specific adapter around the generic Codex runner.
set -euo pipefail

SKILL_DIR=/etc/codex/skills/evaluate-e2e-results
log() { printf '%s\n' "$*" >&2; }

if [[ -n "${AGENT_MAX_BUDGET:-}${COST_OUT:-}" ]]; then
  log "ERROR: AGENT_MAX_BUDGET and COST_OUT are unsupported with Codex; use AGENT_TIMEOUT and USAGE_OUT"
  exit 2
fi
export RESULTS_DIR="${1:-${RESULTS_DIR:-/artifacts}}"
if [[ ! -d "$RESULTS_DIR" || ! -r "$RESULTS_DIR/json-results.json" ]]; then
  log "ERROR: results directory must contain a readable json-results.json: $RESULTS_DIR"
  exit 2
fi
RESULTS_DIR="$(cd -- "$RESULTS_DIR" && pwd -P)"

evaluation_dir="$(mktemp -d "${TMPDIR:-/tmp}/evaluation-agent.XXXXXXXX")"
agent_pid=''
trap 'rm -rf -- "$evaluation_dir"' EXIT
forward_signal() {
  local signal="$1" status="$2"
  trap '' TERM INT HUP
  if [[ -n "$agent_pid" ]]; then
    kill -s "$signal" "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap 'forward_signal TERM 143' TERM
trap 'forward_signal INT 130' INT
trap 'forward_signal HUP 129' HUP

# The prompt explicitly selects the baked skill. Paths are supplied as data;
# never interpolate artifact contents into shell commands.
prompt="Use the evaluate-e2e-results skill at $SKILL_DIR/SKILL.md to analyze the read-only results directory named by RESULTS_DIR ($RESULTS_DIR). Return only the evaluation JSON. Reporting is handled by the caller; do not send notifications."
log "Evaluating $RESULTS_DIR (model=${AGENT_MODEL:-gpt-6-luna}, timeout=${AGENT_TIMEOUT:-3m})"

# Keep Slack credentials out of the agent environment. --json is the event
# stream, while --output-last-message captures the final report separately.
env -u SLACK_WEBHOOK_URL /usr/local/bin/codex-runner \
  --json --output-last-message "$evaluation_dir/final.txt" "$prompt" \
  >"$evaluation_dir/events.jsonl" < /dev/null &
agent_pid=$!
set +e
wait "$agent_pid"
rc=$?
set -e
agent_pid=''

session_id=''
usage='{}'
events_valid=false
if [[ -s "$evaluation_dir/events.jsonl" ]] && jq -se 'length > 0 and all(.[]; type == "object")' "$evaluation_dir/events.jsonl" >/dev/null 2>&1; then
  events_valid=true
  session_id="$(jq -sr '[.[] | select(.type == "thread.started") | .thread_id][0] // empty' "$evaluation_dir/events.jsonl")"
  usage="$(jq -sc '
    [.[] | select(.type == "turn.completed") | .usage | select(type == "object")]
    | if length == 0 then {} else {
        input_tokens: (map(.input_tokens // 0) | add),
        cached_input_tokens: (map(.cached_input_tokens // 0) | add),
        output_tokens: (map(.output_tokens // 0) | add)
      } end' "$evaluation_dir/events.jsonl")"
fi
[[ -z "${SESSION_OUT:-}" ]] || printf '%s' "$session_id" >"$SESSION_OUT"
[[ -z "${USAGE_OUT:-}" ]] || printf '%s' "$usage" >"$USAGE_OUT"
log "session_id=$session_id token_usage=$usage"

if [[ $rc -ne 0 ]]; then
  log "ERROR: evaluation agent failed (rc=$rc)"
  exit "$rc"
fi
if [[ "$events_valid" != true ]] || ! jq -se '
  any(.[]; .type == "turn.completed") and all(.[]; .type != "turn.failed")
  ' "$evaluation_dir/events.jsonl" >/dev/null; then
  log "ERROR: Codex did not report a successfully completed turn"
  exit 1
fi
if [[ ! -s "$evaluation_dir/final.txt" ]]; then
  log "ERROR: Codex produced no final evaluation"
  exit 1
fi

# Preserve tolerance of fenced JSON, but validate the report before delivery.
python3 - "$evaluation_dir/final.txt" "$evaluation_dir/report.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as stream:
        raw = stream.read()
    start = raw.find("{")
    if start < 0:
        raise ValueError("no JSON object")
    report, _ = json.JSONDecoder().raw_decode(raw[start:])
    if not isinstance(report.get("summary"), dict) or not isinstance(report.get("failures"), list):
        raise ValueError("expected a summary object and failures array")
    with open(sys.argv[2], "w") as stream:
        json.dump(report, stream)
        stream.write("\n")
except (OSError, ValueError, AttributeError) as error:
    print(f"ERROR: invalid evaluation JSON: {error}", file=sys.stderr)
    sys.exit(1)
PY

# Emit/persist the report even if subsequent Slack delivery fails. The webhook
# response must never contaminate the single JSON object written to stdout.
[[ -z "${EVALUATION_OUT:-}" ]] || cat "$evaluation_dir/report.json" >"$EVALUATION_OUT"
cat "$evaluation_dir/report.json"
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  log "Posting evaluation to Slack..."
  python3 "$SKILL_DIR/scripts/slack_formatter.py" \
    --pipeline-name "${PIPELINE_NAME:-}" \
    --artifacts-url "${ARTIFACTS_URL:-}" \
    --workflow-var "${SLACK_WORKFLOW_VAR:-text}" \
    <"$evaluation_dir/report.json" \
    | curl -sS --fail --connect-timeout 10 --max-time 30 --output /dev/null \
      -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL"
  log "Slack post complete."
fi
