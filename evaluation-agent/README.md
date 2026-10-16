# Podman Desktop E2E evaluation agent

A container image that runs the [`evaluate-e2e-results`](../ai-eval/skills/evaluate-e2e-results)
Claude Code skill **headlessly** to triage Podman Desktop Playwright E2E
failures, and (optionally) posts the verdict to Slack.

It is designed to run as a Tekton task **after** the `e2e-runner` task, reading
the `qe-results` the runner wrote to the shared workspace. The results directory
is treated as **read-only** — the agent only writes to `/tmp` and an ephemeral
config directory.

## What it does

1. Invokes `claude --print` against a results directory with the
   `evaluate-e2e-results` skill, authenticating to **Google Vertex AI**.
2. Captures the evaluation JSON, logs the session id + cost, fails on error.
3. If `SLACK_WEBHOOK_URL` is set, formats the result with the skill's
   `slack_formatter.py` and POSTs a flat text digest to a Slack **Workflow
   Builder trigger** (`https://hooks.slack.com/triggers/…`).
4. Prints the evaluation JSON to stdout.

## Inputs

The results directory must contain the Playwright artifacts produced by
`e2e-runner` (`json-results.json`, `junit-results.xml`,
`{slug}/error-context.md`, `traces/*_trace.zip`).

## Environment

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ANTHROPIC_VERTEX_PROJECT_ID` | yes | — | GCP project id hosting the Vertex AI models |
| `CLOUD_ML_REGION` | yes | — | Vertex region (`global` recommended; some models lack quota in regional endpoints) |
| `GOOGLE_APPLICATION_CREDENTIALS` | yes | — | Path to a mounted GCP service-account/ADC JSON (a bare access token is **not** usable) |
| `RESULTS_DIR` | no | `/artifacts` | Results dir if not passed as `$1` |
| `AGENT_MODEL` | no | `claude-sonnet-5` | Model alias/id |
| `AGENT_TIMEOUT` | no | `30m` | Wall-clock cap (`timeout` syntax) |
| `AGENT_MAX_BUDGET` | no | `5` | Max USD spend on API calls |
| `SLACK_WEBHOOK_URL` | no | — | If set, the digest is POSTed to this Slack Workflow Builder trigger |
| `SLACK_WORKFLOW_VAR` | no | `text` | Variable name for the trigger payload; must match the workflow's webhook variable |
| `PIPELINE_NAME` | no | — | Slack header label |
| `ARTIFACTS_URL` | no | — | Slack footer link |
| `COST_OUT` / `SESSION_OUT` | no | — | Write outputs to these paths (used for Tekton results) |

**Auth:** the agent uses Google Vertex AI (`CLAUDE_CODE_USE_VERTEX=1` is set by
the entrypoint). Provide `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION`, and a
mounted service-account/ADC JSON via `GOOGLE_APPLICATION_CREDENTIALS`. A bare
`gcloud auth print-access-token` value is **not** usable. The service account
needs the **Vertex AI User** role on the project.

## Build

The build context is the **repository root** so the skill can be copied from
`ai-eval/skills/` (requires PR #625):

```bash
make oci-build          # podman build ... -f Containerfile ..
make oci-push           # push the image
make tkn-push           # push the tekton task bundle
```

## Run locally

Mount the results **read-only** and pass the mount path as the argument:

```bash
podman run --rm \
  -e CLAUDE_CODE_USE_VERTEX=1 \
  -e ANTHROPIC_VERTEX_PROJECT_ID="$PROJECT_ID" \
  -e CLOUD_ML_REGION=global \
  -e GOOGLE_APPLICATION_CREDENTIALS=/creds/service-account.json \
  -v "$PWD/service-account.json:/creds/service-account.json:ro" \
  -v "$PWD/results:/artifacts:ro" \
  ghcr.io/podman-desktop/evaluation-agent:nightly /artifacts
```

Add `-e SLACK_WEBHOOK_URL -e PIPELINE_NAME -e ARTIFACTS_URL` to also post to Slack.

## Tekton

The task `evaluate-e2e-results` (see [`tkn/task.yaml`](tkn/task.yaml)) consumes a
`pipelines-data` workspace and a `gcp-credentials` workspace (the Vertex
service-account JSON), and exposes `cost-usd` and `session-id` results. The full
evaluation JSON is intentionally **not** a Tekton result (it exceeds the result
size limit) — it stays on the task's stdout and is delivered to Slack.

It expects:

- workspace `gcp-credentials` — a secret holding the service-account JSON
  (default key `service-account.json`)
- secret `slack-webhook` with key `url` (optional) — the published Workflow
  Builder trigger URL

```yaml
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  name: evaluate-e2e-results-run
spec:
  taskRef:
    resolver: bundles
    params:
    - name: bundle
      value: ghcr.io/podman-desktop/evaluation-agent-tkn:v0.1.0
    - name: name
      value: evaluate-e2e-results
    - name: kind
      value: task
  params:
  - name: workspace-resources-path
    value: <same path used by the e2e-runner run>
  - name: vertex-project-id
    value: "<gcp-project-id>"
  - name: pipeline-name
    value: "pd-e2e-podman macOS applehv"
  workspaces:
  - name: pipelines-data
    persistentVolumeClaim:
      claimName: pipelines-data
  - name: gcp-credentials
    secret:
      secretName: gcp-credentials
```

## Security notes

- Runs as a non-root user; the skill is baked read-only and cannot be overwritten.
- Fresh `CLAUDE_CONFIG_DIR` per run — no cross-run session-state corruption, no
  resume prompt to hang on.
- Read-only tool allowlist (`Read,Glob,Grep,Bash`) with non-interactive
  permission handling; no secrets baked into the image.
- Wall-clock `timeout` + `--max-budget-usd` guard against stuck runs and runaway
  cost; exit codes and the `is_error` field are checked, and the session id +
  cost are logged for postmortem.
