# Podman Desktop E2E evaluation agent

The complete evaluation template: a Codex-based image with the
[`evaluate-e2e-results`](../.skills/evaluate-e2e-results) skill baked in, a
[Tekton task](tkn/task.yaml), and optional Slack Workflow Builder reporting.
The image extends the [generic Codex runner](../codex-runner), which contains
no skill or reporting logic.

## Build

From the repository root:

```bash
make -C evaluation-agent oci-build
# Optional publishing, after registry authentication:
make -C evaluation-agent oci-push
make -C evaluation-agent tkn-push
```

The build first creates `localhost/codex-runner:v0.1.0`, then adds the skill and
evaluation adapter. Neither image needs to have been published beforehand.
The final image defaults to `ghcr.io/podman-desktop/evaluation-agent:v0.1.0`.
Override `IMG` and `RUNNER_IMG` for local tags. `PLATFORM=linux/amd64` is the
default even on Apple Silicon; `PLATFORM=linux/arm64` is available for native
local development. Both stages use the same pinned `CODEX_CLI_VERSION`.

The evaluation build uses the repository root as its context and explicitly
selects `evaluation-agent/.containerignore`. It does not impose exclusions on
other images in this repository.

`make tkn-push` pins the bundled task's image version to `IMAGE_TAG`
(default `v${VERSION}`). The existing nightly workflow uses
`IMAGE_TAG=nightly TKN_TAG=nightly`. The bundle installer currently targets a
Linux AMD64 build host, as used by the publishing workflows.

## Run locally

Provide `CODEX_API_KEY` in the calling environment and mount artifacts read-only:

```bash
podman run --rm --read-only --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /var/lib/codex-runner:rw,nosuid,nodev,mode=0770 \
  --cap-drop=all --security-opt=no-new-privileges \
  -e CODEX_API_KEY \
  -v "$PWD/results:/artifacts:ro" \
  ghcr.io/podman-desktop/evaluation-agent:v0.1.0 /artifacts
```

The directory must contain `json-results.json` directly or in a
`podman-desktop/` child, as produced by the e2e runner. The adapter selects the
directory containing the JSON report. The skill also reads available
error contexts, buffered logs, and traces. The adapter emits one evaluation
JSON object on stdout; diagnostics, the Codex thread ID, and token usage go to
stderr. Codex receives the bundled `report.schema.json` as its structured
output contract. The adapter validates the final report before delivery,
removes schema-only null fields, and fails on agent errors, timeout, missing
output, or invalid JSON. It also requires a successful shell command in the
Codex event stream and verifies summary counts against Playwright's own stats;
an agent response that did not inspect the artifacts cannot be posted to Slack.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CODEX_API_KEY` | Required | OpenAI API key injected at runtime |
| `RESULTS_DIR` | `/artifacts` | Artifact directory; the positional argument takes precedence |
| `AGENT_MODEL` | `gpt-6-luna` | Runtime model selection |
| `AGENT_TIMEOUT` | `3m` | Agent deadline, configurable at runtime |
| `AGENT_SANDBOX` | `workspace-write` | Codex command sandbox; explicitly set `danger-full-access` only when the hardened container is the execution boundary |
| `SLACK_WEBHOOK_URL` | Unset | Optional Slack Workflow Builder trigger |
| `SLACK_WORKFLOW_VAR` | `text` | Webhook payload variable |
| `PIPELINE_NAME` | Empty | Slack header label |
| `ARTIFACTS_URL` | Empty | Link to full artifacts |
| `EVALUATION_OUT` | Unset | Optional writable path for the full report |
| `SESSION_OUT` | Unset | Optional writable path for the Codex thread ID |
| `USAGE_OUT` | Unset | Optional writable path for token usage JSON |

Model and timeout overrides work without rebuilding the image. Codex progress
is captured as JSONL separately from the final message. Token usage contains
`input_tokens`, `cached_input_tokens`, and `output_tokens`, or `{}` when no usage
was reported. Cached tokens are part of input tokens, not additional tokens.

If configured, Slack delivery uses the existing skill formatter. The webhook
credential is removed from the agent environment. The report is emitted and
saved before delivery, so a webhook failure does not discard the report. A
webhook failure still returns a nonzero status; each request is limited to 30
seconds, with a 10-second connection timeout.

## OpenShift Pipelines

The task reads `pipelines-data` as a **read-only workspace**. It uses writable
`emptyDir` volumes at `/tmp` and `/var/lib/codex-runner`, a read-only root
filesystem, no added capabilities, and the UID assigned by OpenShift. The
default `workspace-write` mode runs a credential-free
`codex sandbox -P :workspace` probe before calling the model. A cluster that denies Codex's inner
user namespace fails this probe and sends no evaluation or Slack message.
For the existing Claude-style pod boundary, explicitly set the task parameter
`agent-sandbox: danger-full-access`. This skips only Codex's inner sandbox; the
task's read-only artifact workspace, read-only root filesystem, non-root UID,
dropped capabilities, and no privilege escalation still apply. Commands run by
Codex can then access anything available inside the evaluation pod, including
its API key, so keep its service account and mounted credentials minimal and
restrict pod egress as appropriate. There is no automatic sandbox downgrade.
A local image build is not an OpenShift execution test. With
`ignore-errors=true`, Tekton still marks a failed evaluation step successful;
use `false` while validating the cluster integration.
The step sets `HOME=/tekton/home` so Tekton can copy registry credentials to its
writable home volume instead of the UBI image's read-only home directory.

Apply the dedicated [evaluation ServiceAccount](tkn/serviceaccount.yaml) in the
PipelineRun namespace before running the sample pipeline:

```bash
oc apply -n <namespace> -f evaluation-agent/tkn/serviceaccount.yaml
```

Give `evaluate-results` this account through the PipelineRun's
`taskRunSpecs`; the account and that task's pod template disable automatic API
token mounting. Do not attach unrelated Secrets or permissions to this account.
The pipeline binds the evaluation task's workspace with a task-specific
`subPath` of `<run-id>/qe-results`, and passes `.` for both results-path
parameters. The evaluation pod therefore mounts only that run's results
directory, not the entire shared PVC or the sibling host key. The directory
must already exist when the evaluation task starts. Other pipeline tasks retain
their original workspace bindings. This narrows the evaluation pod's mount;
it does not change access granted to other pods in the namespace.

Provision a Secret named `codex-api-key` with key `api-key` through your usual
secret-management mechanism. Set the task's `api-key-secret` parameter to use a
different Secret. The optional existing `slack-webhook` Secret uses key `url`.
Neither credential belongs in task parameters, source control, or images.

The task exposes `session-id` (Codex thread ID) and `token-usage` (small JSON).
The full evaluation stays on stdout because it can exceed Tekton result size
limits. For standalone container runs, use `EVALUATION_OUT` to save it.
`ignore-errors=true` preserves the existing best-effort behavior; set it to
`false` when checking the integration so failures fail the TaskRun.

After applying `tkn/task.yaml` and publishing your image, adapt this example:

```yaml
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  generateName: evaluate-e2e-results-
spec:
  taskRef:
    name: evaluate-e2e-results
  serviceAccountName: evaluation-agent
  podTemplate:
    automountServiceAccountToken: false
  timeout: 4m
  params:
  - name: image-repository
    value: ghcr.io/podman-desktop/evaluation-agent
  - name: image-version
    value: v0.1.0
  - name: workspace-resources-path
    value: .
  - name: workspace-qe-subpath
    value: .
  - name: agent-model
    value: gpt-6-luna
  - name: agent-timeout
    value: 3m
  - name: ignore-errors
    value: 'false'
  workspaces:
  - name: pipelines-data
    subPath: <run-id>/qe-results
    persistentVolumeClaim:
      claimName: pipelines-data
```

Keep the enclosing task timeout above the agent's three-minute default to allow
shutdown and reporting. The runner sends SIGTERM at the deadline and SIGKILL
five seconds later if necessary. Timeout normally returns 124; forced shutdown
can return 137. The task propagates failures unless `ignore-errors=true`.

## Migration from the Claude POC

- Vertex/GCP settings and the credentials workspace are replaced by
  `CODEX_API_KEY` and the API-key Secret.
- The default model is `gpt-6-luna`; the default agent timeout is `3m`.
- The Claude output envelope is replaced by Codex events and final-message
  capture. `session-id` now identifies a Codex thread.
- `agent-max-budget`, `AGENT_MAX_BUDGET`, `cost-usd`, and `COST_OUT` have no
  supported Codex equivalent. The adapter rejects the obsolete environment
  settings instead of silently suggesting a dollar budget is enforced.
  `token-usage`/`USAGE_OUT` replace cost reporting; they are not USD estimates.
- Approval prompts are disabled. The old tool allowlist is replaced by Codex
  sandboxing and read-only artifact mounts; Bash alone never enforced
  read-only access.
