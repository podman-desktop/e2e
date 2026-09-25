#!/usr/bin/env bash
#
# Headless entrypoint for the Podman Desktop E2E evaluation agent.
#
# Runs the `evaluate-e2e-results` Claude Code skill non-interactively against a
# results directory, prints the evaluation JSON to stdout, and (optionally) posts
# a Slack Block Kit message. It only ever writes to /tmp and an ephemeral config
# directory — the input results directory is treated as read-only.
#
# Usage:
#   entrypoint.sh [RESULTS_DIR]
#
# Auth — Google Vertex AI (never bake secrets into the image):
#   ANTHROPIC_VERTEX_PROJECT_ID     GCP project id (required).
#   CLOUD_ML_REGION                 Vertex region, e.g. global (required).
#   GOOGLE_APPLICATION_CREDENTIALS  Path to a mounted GCP service-account JSON
#                       (or an application_default_credentials.json). A bare
#                       `gcloud auth print-access-token` value is NOT usable.
#   CLAUDE_CODE_USE_VERTEX          Forced to 1 by this script.
#
# Optional env:
#   RESULTS_DIR         Results dir if not passed as $1 (default: /artifacts).
#   AGENT_MODEL         Model alias/id            (default: claude-sonnet-5).
#   AGENT_TIMEOUT       Wall-clock cap for the run (default: 30m).
#   AGENT_MAX_BUDGET    Max USD spend on API calls (default: 5).
#   SLACK_WEBHOOK_URL   If set, the digest is POSTed to this Slack Workflow
#                       Builder trigger (…/triggers/…) as a flat text variable.
#   SLACK_WORKFLOW_VAR  Variable name for the workflow-trigger payload
#                       (default: text). Must match the workflow's webhook var.
#   PIPELINE_NAME       Shown in the Slack header.
#   ARTIFACTS_URL       Linked from the Slack footer.
#   EVALUATION_OUT      If set, the evaluation JSON is also written to this path
#                       (e.g. a Tekton result path).
#   COST_OUT            If set, the run cost (USD) is written to this path.
#   SESSION_OUT         If set, the session id is written to this path.
#
set -euo pipefail

SKILL_DIR="/opt/evaluation-agent/skills/evaluate-e2e-results"

log() { printf '%s\n' "$*" >&2; }

# --- Preconditions -----------------------------------------------------------
# Auth provider: Google Vertex AI. Fail fast with a clear message if any of the
# required config is missing.
export CLAUDE_CODE_USE_VERTEX=1
: "${ANTHROPIC_VERTEX_PROJECT_ID:?ANTHROPIC_VERTEX_PROJECT_ID is required for Vertex auth}"
: "${CLOUD_ML_REGION:?CLOUD_ML_REGION is required for Vertex auth (e.g. global)}"
# Vertex uses Google ADC: a service-account/ADC JSON via
# GOOGLE_APPLICATION_CREDENTIALS, or the auto-discovered default ADC file.
# A bare `gcloud auth print-access-token` value is NOT usable here.
adc_default="${HOME:-/home/agent}/.config/gcloud/application_default_credentials.json"
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  [[ -r "$GOOGLE_APPLICATION_CREDENTIALS" ]] || {
    log "ERROR: GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS is not a readable file (mount it into the container)"
    exit 2
  }
elif [[ ! -r "$adc_default" ]]; then
  log "ERROR: no Google credentials found. Set GOOGLE_APPLICATION_CREDENTIALS to a mounted service-account/ADC JSON, or mount an ADC file to $adc_default"
  exit 2
fi
log "Auth: Vertex AI (project=$ANTHROPIC_VERTEX_PROJECT_ID region=$CLOUD_ML_REGION)"

RESULTS_DIR="${1:-${RESULTS_DIR:-/artifacts}}"
if [[ ! -d "$RESULTS_DIR" ]]; then
  log "ERROR: results directory not found: $RESULTS_DIR"
  exit 2
fi

AGENT_MODEL="${AGENT_MODEL:-claude-sonnet-5}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-30m}"
AGENT_MAX_BUDGET="${AGENT_MAX_BUDGET:-5}"

# --- Ephemeral, per-run config dir -------------------------------------------
# A fresh CLAUDE_CONFIG_DIR per run isolates session state so concurrent
# containers never corrupt each other's ~/.claude, and no stale session exists
# to trigger a resume prompt. --print is already non-interactive, so this is
# belt-and-suspenders.
CLAUDE_CONFIG_DIR="$(mktemp -d)"
export CLAUDE_CONFIG_DIR
trap 'rm -rf "$CLAUDE_CONFIG_DIR"' EXIT

# Make the baked (read-only) skill discoverable as a personal skill.
mkdir -p "$CLAUDE_CONFIG_DIR/skills"
ln -s "$SKILL_DIR" "$CLAUDE_CONFIG_DIR/skills/evaluate-e2e-results"

# --- Run the agent -----------------------------------------------------------
# Read-only tool posture: allow only the tools the skill needs. With --print and
# --permission-prompts none, anything not on the allowlist is denied outright
# (never hangs waiting for approval). Container-level guards (non-root,
# read-only mounts, no egress except the API) are the real boundary.
OUT_FILE="$(mktemp)"
trap 'rm -rf "$CLAUDE_CONFIG_DIR" "$OUT_FILE"' EXIT

log "Evaluating results in: $RESULTS_DIR (model=$AGENT_MODEL, timeout=$AGENT_TIMEOUT, budget=\$$AGENT_MAX_BUDGET)"

set +e
timeout "$AGENT_TIMEOUT" claude --print "/evaluate-e2e-results $RESULTS_DIR" \
  --output-format json \
  --model "$AGENT_MODEL" \
  --max-budget-usd "$AGENT_MAX_BUDGET" \
  --permission-prompts none \
  --allowedTools "Skill,Read,Glob,Grep,Bash" \
  --add-dir "$RESULTS_DIR" \
  --no-session-persistence \
  >"$OUT_FILE"
rc=$?
set -e

if [[ $rc -eq 124 ]]; then
  log "ERROR: agent timed out after $AGENT_TIMEOUT"
  exit 124
fi
if [[ $rc -ne 0 ]]; then
  log "ERROR: claude exited with code $rc"
  cat "$OUT_FILE" >&2 || true
  exit "$rc"
fi

# --- Postmortem metadata + error discipline ----------------------------------
session_id="$(jq -r '.session_id // empty' "$OUT_FILE")"
cost="$(jq -r '.total_cost_usd // empty' "$OUT_FILE")"
is_error="$(jq -r '.is_error // false' "$OUT_FILE")"
log "session_id=$session_id cost_usd=$cost is_error=$is_error"

[[ -n "${SESSION_OUT:-}" ]] && printf '%s' "$session_id" >"$SESSION_OUT"
[[ -n "${COST_OUT:-}" ]] && printf '%s' "$cost" >"$COST_OUT"

if [[ "$is_error" == "true" ]]; then
  log "ERROR: agent reported is_error=true"
  cat "$OUT_FILE" >&2 || true
  exit 1
fi

# The skill's evaluation report is the .result field of the JSON envelope.
EVAL_FILE="$(mktemp)"
trap 'rm -rf "$CLAUDE_CONFIG_DIR" "$OUT_FILE" "$EVAL_FILE"' EXIT
jq -r '.result' "$OUT_FILE" >"$EVAL_FILE"

# Validate the skill produced parseable evaluation JSON before we act on it.
if ! jq -e '.summary and (.failures | type == "array")' "$EVAL_FILE" >/dev/null 2>&1; then
  log "ERROR: evaluation output is not valid evaluation JSON"
  cat "$EVAL_FILE" >&2 || true
  exit 1
fi

# --- Optional Slack post -----------------------------------------------------
# The org's only usable delivery channel is a Slack Workflow Builder trigger
# (…/triggers/…), which reads flat variables — not Block Kit. The formatter
# collapses the report into a single text variable (default name: text).
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  log "Posting evaluation to Slack (workflow trigger, var=${SLACK_WORKFLOW_VAR:-text})..."
  python3 "$SKILL_DIR/scripts/slack_formatter.py" \
    --pipeline-name "${PIPELINE_NAME:-}" \
    --artifacts-url "${ARTIFACTS_URL:-}" \
    --workflow-var "${SLACK_WORKFLOW_VAR:-text}" \
    <"$EVAL_FILE" \
    | curl -sS --fail -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL"
  log "Slack post complete."
fi

# --- Emit the evaluation JSON ------------------------------------------------
[[ -n "${EVALUATION_OUT:-}" ]] && cat "$EVAL_FILE" >"$EVALUATION_OUT"
cat "$EVAL_FILE"
