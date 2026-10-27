# evaluation-agent

An [agent-runner](../agent-runner/README.md) bundle that triages Podman Desktop
E2E failures. It reads the Playwright results of a run (`json-results.json`,
`error-context.md`, traces), classifies each failure with the
[`evaluate-e2e-results`](../.skills/evaluate-e2e-results/SKILL.md) skill, and
produces:

- the full JSON report (schema: `task/output.schema.json`) in the step log;
- a plain-text digest in the `summary` result, which `tkn/slack-task.yaml`
  posts to a Slack Workflow Builder trigger. It lists as many failures as fit
  in 2600 characters and the 3072-byte result limit, and says how many it left out.

## Layout

| File | Role |
|---|---|
| `Containerfile` | `FROM agent-runner`, adds the skill and `task/` |
| `task/prompt.md` | Asks for the skill on `{{INPUT_DIR}}` and states the null/omission conventions of the schema |
| `task/output.schema.json` | Strict report schema: summary, failures, skipped analysis, platform |
| `task/post.sh` | Checks the report against `json-results.json`, then renders the Slack digest |
| `tkn/slack-task.yaml` | `post-evaluation-to-slack`: posts the digest; holds the Slack secret only |

## What `post.sh` checks

The output schema checks the report's shape. `post.sh` checks that it describes
*this* run, so a hallucinated or truncated triage never reaches Slack:

- `summary.passed/failed/skipped/flaky/total` equal Playwright's
  `stats.expected/unexpected/skipped/flaky` (and their sum);
- `summary.duration_s` matches `stats.duration` (ms → s, ±0.02);
- failures are listed when `failed > 0`, and `skipped_analysis` is present when
  `skipped > 0`.

Then it removes the null fields that the schema requires and the skill omits, and
runs the skill's `scripts/slack_formatter.py` to make the digest. The formatter
limits characters and the result limit is in bytes, so `post.sh` tries 2600
characters first and steps down until the digest fits in 3072 bytes.

## Pipeline wiring

The evaluation runs as the generic `run-agent` Task with this image. Slack
delivery is a separate TaskRun that gets the bounded digest and the webhook,
but never the model key or the results:

```yaml
- name: evaluate-results
  runAfter: [podman-desktop-runner]
  timeout: 15m
  taskRef:
    resolver: bundles
    params:
    - {name: bundle, value: ghcr.io/podman-desktop/agent-runner-tkn:v0.1.0}
    - {name: name, value: run-agent}
    - {name: kind, value: task}
  params:
  - {name: image, value: ghcr.io/podman-desktop/evaluation-agent:v0.2.0}
  - {name: input-path, value: podman-desktop}   # Playwright output inside qe-results
  - {name: pipeline-name, value: $(context.pipelineRun.name)}
  - {name: artifacts-url, value: $(params.artifacts-url)}
  workspaces:
  - name: input
    workspace: pipelines-data
    subPath: $(tasks.correlate.results.workspace-resources-path)/qe-results

- name: post-evaluation-to-slack
  runAfter: [evaluate-results]
  timeout: 2m
  when:
  - {input: $(tasks.evaluate-results.results.summary), operator: notin, values: [SKIP]}
  taskRef:
    resolver: bundles
    params:
    - {name: bundle, value: ghcr.io/podman-desktop/evaluation-agent-tkn:v0.2.0}
    - {name: name, value: post-evaluation-to-slack}
    - {name: kind, value: task}
  params:
  - {name: text, value: $(tasks.evaluate-results.results.summary)}
```

Bind the `agent-runner` ServiceAccount (no token) to both tasks with
`taskRunSpecs`, as shown in the agent-runner README.

Secrets (created by the namespace owner):

- `codex-api-key`, key `api-key`: a dedicated, spend-limited OpenAI project key.
- `slack-webhook`, key `url`: the Workflow Builder trigger URL. The trigger takes
  one flat variable (default `text`); there is no Slack app or incoming webhook.

## Build and run locally

```bash
# Base + bundle, for local testing on Apple Silicon
make oci-build-all PLATFORM=linux/arm64 \
  AGENT_RUNNER_IMAGE=localhost/agent-runner:dev IMG=localhost/evaluation-agent:dev

podman run --rm --read-only --tmpfs /tmp --tmpfs /var/lib/agent-runner \
  --user 1000770000:0 --cap-drop ALL --security-opt no-new-privileges \
  -e CODEX_API_KEY -e INPUT_DIR=/in -e AGENT_SUMMARY_OUT=/dev/stderr \
  -v ./results/podman-desktop:/in:ro,Z localhost/evaluation-agent:dev
```

Release: `make oci-build oci-push tkn-push VERSION=x.y.z` (amd64 by default).
