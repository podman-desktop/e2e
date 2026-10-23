#!/usr/bin/env bash
# Generic, non-interactive Codex runner. Arguments are passed to codex exec.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

metadata_mode=''
if [[ $# -eq 1 ]]; then
  case "$1" in
    --help|-h) metadata_mode=help ;;
    --version|-V) metadata_mode=version ;;
  esac
fi

if [[ -z "$metadata_mode" && -z "${CODEX_API_KEY:-}" ]]; then
  log "ERROR: CODEX_API_KEY is required"
  exit 2
fi

agent_model="${AGENT_MODEL:-gpt-6-luna}"
agent_timeout="${AGENT_TIMEOUT:-3m}"
# GNU timeout accepts fractional durations, but zero would disable the limit.
if [[ ! "$agent_timeout" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ || ! "$agent_timeout" =~ [1-9] ]]; then
  log "ERROR: AGENT_TIMEOUT must be a positive duration, for example 3m or 30s"
  exit 2
fi

# Codex refuses to create executable helpers beneath the system temp dir.
# Use a separate writable state volume, with a private directory for each run.
state_root="${AGENT_STATE_DIR:-/var/lib/codex-runner}"
if [[ "$state_root" != /* || ! -d "$state_root" || ! -w "$state_root" ]]; then
  log "ERROR: mount a writable state directory at $state_root (AGENT_STATE_DIR)"
  exit 2
fi
runner_state_dir="$(mktemp -d "$state_root/run.XXXXXXXX")"
runner_pid=''
cleanup() { rm -rf -- "$runner_state_dir"; }
forward_signal() {
  local signal="$1" status="$2"
  trap '' TERM INT HUP
  if [[ -n "$runner_pid" ]]; then
    # timeout owns the child process group and forwards signals to that group.
    kill -s "$signal" "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'forward_signal TERM 143' TERM
trap 'forward_signal INT 130' INT
trap 'forward_signal HUP 129' HUP

mkdir -p "$runner_state_dir/config" "$runner_state_dir/cache" "$runner_state_dir/work"
cd "$runner_state_dir/work"

# Even informational commands may create CLI PATH aliases. Isolate them too,
# so --help/--version work cleanly with a read-only home and no credentials.
if [[ "$metadata_mode" == help ]]; then
  env CODEX_HOME="$runner_state_dir/config" codex exec --help
  exit 0
elif [[ "$metadata_mode" == version ]]; then
  env CODEX_HOME="$runner_state_dir/config" codex --version
  exit 0
fi

# A TOML string encoded as JSON prevents a model name from injecting config.
model_config="$(printf '%s' "$agent_model" | jq -Rs .)"
log "Starting Codex (default model=$agent_model, timeout=$agent_timeout)"

# Configuration defaults allow standard --model/--sandbox flags to override
# them. There is no automatic sandbox downgrade if the host rejects it.
# Keep stdin explicitly attached: background jobs otherwise receive /dev/null.
env CODEX_HOME="$runner_state_dir/config" XDG_CACHE_HOME="$runner_state_dir/cache" \
  timeout --signal=TERM --kill-after=5s "$agent_timeout" \
  codex --ask-for-approval never exec \
    -c "model=$model_config" -c 'sandbox_mode="workspace-write"' \
    --ephemeral --skip-git-repo-check "$@" <&0 &
runner_pid=$!

set +e
wait "$runner_pid"
rc=$?
set -e
runner_pid=''

if [[ $rc -eq 124 ]]; then
  log "ERROR: Codex timed out after $agent_timeout"
elif [[ $rc -ne 0 ]]; then
  log "ERROR: Codex exited with code $rc"
fi
exit "$rc"
