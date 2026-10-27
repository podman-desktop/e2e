#!/usr/bin/env bash
# Generic headless Codex runner. Runs the task bundle in $AGENT_TASK_DIR:
#   prompt.md           required; {{INPUT_DIR}} is replaced with the input path
#   output.schema.json  required; the final answer must match it
#   post.sh             optional; post.sh <report.json> <input-dir>, may write
#                       a short summary to $AGENT_SUMMARY_FILE
# Exit codes: 2 bad configuration, 124 timeout, other non-zero agent failure.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $2"; exit "$1"; }

task_dir="${AGENT_TASK_DIR:-/opt/agent/task}"
state_root="${AGENT_STATE_DIR:-/var/lib/agent-runner}"
model="${AGENT_MODEL:-gpt-6-luna}"
agent_timeout="${AGENT_TIMEOUT:-5m}"
summary_out="${AGENT_SUMMARY_OUT:-}"
summary_max_bytes="${AGENT_SUMMARY_MAX_BYTES:-3072}"
input_dir="${INPUT_DIR:-${1:-}}"

# Consumers (e.g. a Slack task) skip on SKIP, so set it before anything fails.
[[ -z "$summary_out" ]] || printf 'SKIP' >"$summary_out"

[[ -n "${CODEX_API_KEY:-}" ]] || die 2 "CODEX_API_KEY is required"
[[ -r "$task_dir/prompt.md" ]] || die 2 "bundle has no $task_dir/prompt.md"
[[ -r "$task_dir/output.schema.json" ]] || die 2 "bundle has no $task_dir/output.schema.json"
[[ -n "$input_dir" && -d "$input_dir" && -r "$input_dir" ]] \
  || die 2 "INPUT_DIR must name a readable directory: '${input_dir}'"
# GNU timeout treats 0 as "no limit", so require a non-zero duration.
[[ "$agent_timeout" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ && "$agent_timeout" =~ [1-9] ]] \
  || die 2 "AGENT_TIMEOUT must be a positive duration, e.g. 5m"
[[ -d "$state_root" && -w "$state_root" ]] \
  || die 2 "mount a writable directory at AGENT_STATE_DIR ($state_root)"

input_dir="$(cd -- "$input_dir" && pwd -P)"
export INPUT_DIR="$input_dir"

# A fresh Codex home per run: no config, auth or history carries over. Codex
# refuses helper executables under the system temp dir, hence the state root.
run_dir="$(mktemp -d "$state_root/run.XXXXXXXX")"
mkdir -p "$run_dir/home" "$run_dir/cache" "$run_dir/work"
agent_pid=''
trap 'rm -rf -- "$run_dir"' EXIT
# Forward Tekton's TERM to the agent so it stops before the pod is killed.
on_signal() {
  trap '' TERM INT
  [[ -z "$agent_pid" ]] || { kill -TERM "$agent_pid" 2>/dev/null; wait "$agent_pid" 2>/dev/null; }
  exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

prompt="$(<"$task_dir/prompt.md")"
prompt="${prompt//'{{INPUT_DIR}}'/$input_dir}"
# Encode the model as a TOML string so the value cannot inject other config.
model_toml="$(jq -Rn --arg m "$model" '$m')"
report="$run_dir/report.json"

log "agent-runner: model=$model timeout=$agent_timeout input=$input_dir"
cd "$run_dir/work"
env CODEX_HOME="$run_dir/home" XDG_CACHE_HOME="$run_dir/cache" \
  timeout --signal=TERM --kill-after=10s "$agent_timeout" \
  codex exec -c "model=$model_toml" --ephemeral --skip-git-repo-check \
    --output-schema "$task_dir/output.schema.json" \
    --output-last-message "$report" "$prompt" </dev/null &
agent_pid=$!
rc=0
wait "$agent_pid" || rc=$?
agent_pid=''

(( rc != 124 )) || die 124 "agent timed out after $agent_timeout"
(( rc == 0 )) || die "$rc" "agent exited with code $rc"
jq -e 'type == "object"' "$report" >/dev/null 2>&1 \
  || die 1 "agent did not return a JSON object; first bytes: $(head -c 300 "$report" 2>/dev/null)"

# The full report always goes to the log; results only carry the summary.
jq . "$report"
if [[ -n "${OUTPUT_DIR:-}" ]]; then
  cp -- "$report" "$OUTPUT_DIR/report.json"
fi

[[ -x "$task_dir/post.sh" ]] || exit 0
summary="$run_dir/summary"
# The post-check is bundle code; it never needs the model credential.
env -u CODEX_API_KEY AGENT_SUMMARY_FILE="$summary" \
  "$task_dir/post.sh" "$report" "$input_dir" || die 1 "post-check failed"

if [[ -n "$summary_out" && -s "$summary" ]]; then
  size="$(wc -c <"$summary")"
  (( size <= summary_max_bytes )) \
    || die 1 "summary is $size bytes, over AGENT_SUMMARY_MAX_BYTES=$summary_max_bytes"
  cp -- "$summary" "$summary_out"
fi
