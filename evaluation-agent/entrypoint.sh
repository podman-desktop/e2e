#!/usr/bin/env bash
# Evaluation-specific adapter around the generic Codex runner.
set -euo pipefail

SKILL_DIR=/etc/codex/skills/evaluate-e2e-results
REPORT_SCHEMA=/etc/codex/evaluation-report.schema.json
log() { printf '%s\n' "$*" >&2; }

if [[ -n "${AGENT_MAX_BUDGET:-}${COST_OUT:-}" ]]; then
  log "ERROR: AGENT_MAX_BUDGET and COST_OUT are unsupported with Codex; use AGENT_TIMEOUT and USAGE_OUT"
  exit 2
fi
export RESULTS_DIR="${1:-${RESULTS_DIR:-/artifacts}}"
# The e2e runner stores Playwright output beneath qe-results/podman-desktop,
# while standalone runs may mount the Playwright directory directly.
if [[ ! -r "$RESULTS_DIR/json-results.json" && -r "$RESULTS_DIR/podman-desktop/json-results.json" ]]; then
  RESULTS_DIR="$RESULTS_DIR/podman-desktop"
  export RESULTS_DIR
  log "Using nested Playwright results: $RESULTS_DIR"
fi
if [[ ! -d "$RESULTS_DIR" || ! -r "$RESULTS_DIR/json-results.json" ]]; then
  log "ERROR: results directory must contain a readable json-results.json (directly or under podman-desktop/): $RESULTS_DIR"
  exit 2
fi
RESULTS_DIR="$(cd -- "$RESULTS_DIR" && pwd -P)"

evaluation_dir="$(mktemp -d "${TMPDIR:-/tmp}/evaluation-agent.XXXXXXXX")"
agent_pid=''
probe_dir=''
cleanup() {
  rm -rf -- "$evaluation_dir"
  if [[ -n "$probe_dir" ]]; then
    rm -rf -- "$probe_dir"
  fi
}
trap cleanup EXIT
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

# The skill requires shell commands to read Playwright artifacts. In hardened
# containers Codex can complete a turn even when its inner sandbox never starts
# a command, so check that boundary before calling the model or posting Slack.
state_root="${AGENT_STATE_DIR:-/var/lib/codex-runner}"
if [[ ! -d "$state_root" || ! -w "$state_root" ]]; then
  log "ERROR: Codex state directory is not writable: $state_root"
  exit 2
fi
probe_dir="$(mktemp -d "$state_root/probe.XXXXXXXX")"
mkdir -p "$probe_dir/config" "$probe_dir/cache" "$probe_dir/work"
if ! env CODEX_HOME="$probe_dir/config" XDG_CACHE_HOME="$probe_dir/cache" \
  codex sandbox -P :workspace -C "$probe_dir/work" -- /bin/true \
  >"$evaluation_dir/sandbox-probe.log" 2>&1; then
  log "ERROR: Codex workspace-write sandbox cannot start commands in this container"
  sed -n '1,12p' "$evaluation_dir/sandbox-probe.log" >&2
  exit 1
fi
rm -rf -- "$probe_dir"
probe_dir=''

# The prompt explicitly selects the baked skill. Paths are supplied as data;
# never interpolate artifact contents into shell commands.
prompt="Use the evaluate-e2e-results skill at $SKILL_DIR/SKILL.md to analyze the read-only results directory named by RESULTS_DIR ($RESULTS_DIR). Return the complete evaluation JSON matching the supplied output schema. Use null for unavailable optional platform fields and for skipped_analysis when no tests were skipped; use false and 0 for truncated and truncated_count when the report is not truncated. Reporting is handled by the caller; do not send notifications."
log "Evaluating $RESULTS_DIR (model=${AGENT_MODEL:-gpt-6-luna}, timeout=${AGENT_TIMEOUT:-3m})"

# Keep Slack credentials out of the agent environment. --json is the event
# stream, while --output-last-message captures the final report separately.
env -u SLACK_WEBHOOK_URL /usr/local/bin/codex-runner \
  --json --output-schema "$REPORT_SCHEMA" \
  --output-last-message "$evaluation_dir/final.txt" "$prompt" \
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
if ! jq -se '
  any(.[]; .type == "item.completed" and .item.type == "command_execution"
       and .item.exit_code == 0)
  ' "$evaluation_dir/events.jsonl" >/dev/null; then
  log "ERROR: Codex completed without a successful command execution; evaluation inputs were not inspected"
  exit 1
fi
if [[ ! -s "$evaluation_dir/final.txt" ]]; then
  log "ERROR: Codex produced no final evaluation"
  exit 1
fi

# Validate the structured response before delivery. Keep the old Claude
# adapter's tolerance for a JSON object inside fences or explanatory text.
# The schema requires optional keys; restore the skill's omission convention.
python3 - "$evaluation_dir/final.txt" "$evaluation_dir/report.json" "$RESULTS_DIR/json-results.json" <<'PY'
import json
import sys

raw = ""
try:
    with open(sys.argv[1]) as stream:
        raw = stream.read().strip()
    decoder = json.JSONDecoder()
    try:
        report = json.loads(raw)
    except json.JSONDecodeError:
        report = None
        start = raw.find("{")
        attempts = 0
        while start >= 0 and attempts < 128:
            attempts += 1
            try:
                candidate, _ = decoder.raw_decode(raw[start:])
            except json.JSONDecodeError:
                candidate = None
            if isinstance(candidate, dict) and isinstance(candidate.get("summary"), dict) and isinstance(candidate.get("failures"), list):
                report = candidate
                break
            if report is None and isinstance(candidate, dict):
                report = candidate
            start = raw.find("{", start + 1)
        if report is None:
            raise ValueError("no JSON object in final response")
    if not isinstance(report, dict):
        raise ValueError(f"expected an object, got {type(report).__name__}")
    if not isinstance(report.get("summary"), dict) or not isinstance(report.get("failures"), list):
        keys = ", ".join(sorted(report)[:12])
        raise ValueError(f"expected a summary object and failures array (keys: {keys})")
    failed = report["summary"].get("failed")
    skipped = report["summary"].get("skipped")
    if not isinstance(failed, int) or isinstance(failed, bool) or failed < 0:
        raise ValueError("summary.failed must be a non-negative integer")
    if not isinstance(skipped, int) or isinstance(skipped, bool) or skipped < 0:
        raise ValueError("summary.skipped must be a non-negative integer")
    if failed > 0 and not report["failures"]:
        raise ValueError("summary reports failures but the failures array is empty")
    if skipped > 0 and not isinstance(report.get("skipped_analysis"), dict):
        raise ValueError("summary reports skipped tests but skipped_analysis is missing")
    with open(sys.argv[3]) as stream:
        source = json.load(stream)
    stats = source.get("stats")
    if not isinstance(stats, dict):
        raise ValueError("Playwright results lack a stats object")
    expected = {
        "passed": stats.get("expected", 0),
        "failed": stats.get("unexpected", 0),
        "skipped": stats.get("skipped", 0),
        "flaky": stats.get("flaky", 0),
    }
    expected["total"] = sum(expected.values())
    for key, value in expected.items():
        if report["summary"].get(key) != value:
            raise ValueError(f"summary.{key} does not match json-results.json stats")
    duration = report["summary"].get("duration_s")
    if not isinstance(duration, (int, float)) or isinstance(duration, bool) or abs(duration - round(stats.get("duration", 0) / 1000, 2)) > 0.02:
        raise ValueError("summary.duration_s does not match json-results.json stats")
    allowed_classifications = {"regression", "test_bug", "flaky", "infra", "unknown"}
    for index, failure in enumerate(report["failures"]):
        if not isinstance(failure, dict) or failure.get("classification") not in allowed_classifications:
            raise ValueError(f"failures[{index}].classification is unsupported")
    if report.get("skipped_analysis") is None:
        report.pop("skipped_analysis", None)
    if isinstance(report.get("platform"), dict):
        report["platform"] = {k: v for k, v in report["platform"].items() if v is not None}
        if not report["platform"]:
            del report["platform"]
    if report.get("truncated") is False:
        report.pop("truncated", None)
        report.pop("truncated_count", None)
    with open(sys.argv[2], "w") as stream:
        json.dump(report, stream)
        stream.write("\n")
except (OSError, ValueError, TypeError, AttributeError) as error:
    print(f"ERROR: invalid evaluation JSON: {error}", file=sys.stderr)
    print(f"Final response preview ({len(raw)} chars): {raw[:600]!r}", file=sys.stderr)
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
