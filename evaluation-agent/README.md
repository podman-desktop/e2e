# evaluation-agent

An [agent-runner](../agent-runner/README.md) bundle that triages Podman Desktop
E2E failures. It reads the Playwright results of a run (`json-results.json`,
`error-context.md`, traces), classifies each failure with the
[`evaluate-e2e-results`](../.skills/evaluate-e2e-results/SKILL.md) skill, and
produces:

- the full JSON report (schema: `task/output.schema.json`) in the step log;
- a Slack digest that `tkn/slack-task.yaml` posts to a Slack Workflow Builder
  trigger. With run-agent's `output` workspace bound, `post.sh` writes every
  failure to `digest.json` as Slack-sized messages: an overview of the run, then
  each failure group, worst first, with its reason once and every test it hit.
  The `summary` result always holds the overview alone (at most 3072 bytes), the
  go/no-go for the Slack task and its fallback.

## Layout

| File | Role |
|---|---|
| `Containerfile` | `FROM agent-runner`, adds the skill and `task/` |
| `task/prompt.md` | Asks for the skill on `{{INPUT_DIR}}` and states the null/omission conventions of the schema |
| `task/output.schema.json` | Strict report schema: summary, failures, skipped analysis, platform |
| `task/post.sh` | Checks the report against `json-results.json`, then renders the Slack digest |
| `tkn/slack-task.yaml` | `post-evaluation-to-slack`: posts the digest messages in order; holds the Slack secret only |

## What `post.sh` checks

The output schema checks the report's shape. `post.sh` checks that it describes
*this* run, so a hallucinated or truncated triage never reaches Slack:

- `summary.passed/failed/skipped/flaky/total` equal Playwright's
  `stats.expected/unexpected/skipped/flaky` (and their sum);
- `summary.duration_s` matches `stats.duration` (ms → s, ±0.02);
- failures are listed when `failed > 0`, and `skipped_analysis` is present when
  `skipped > 0`.

Then it removes the null fields that the schema requires and the skill omits,
adds the run's start time and, when the skill hit its 20-failure budget, the
failed tests it never reached (from `json-results.json`, listed without a
verdict), and runs the skill's `scripts/slack_formatter.py`:

- `--max-bytes 3072` → the `summary` result: the overview, fitted to the result
  limit as Tekton measures it (JSON-encoded);
- `--split-chars 3500` → `$OUTPUT_DIR/digest.json` (`{"parts": [...]}`), when
  run-agent sets `OUTPUT_DIR`: every failure, nothing left out.

The digest header names the run from `RUN_INFO` (run-agent's `run-info` param):
`pd_version`, `trigger`, `os`, `os_version`, `arch`, `podman_version`,
`provider`, `rootful`, `user_networking`. Without it, the formatter guesses OS and
backend from `PIPELINE_NAME`.

## Pipeline wiring

The evaluation runs as the generic `run-agent` Task with this image. Slack
delivery is a separate TaskRun that gets the digest (read-only) and the
webhook, but never the model key or the results:

```yaml
- name: evaluate-results
  runAfter: [podman-desktop-runner]
  timeout: 15m
  # Makes Tekton resolve the result used in subPath below.
  when:
  - {input: $(tasks.correlate.results.workspace-resources-path), operator: notin, values: [""]}
  taskRef:
    resolver: bundles
    params:
    - {name: bundle, value: ghcr.io/podman-desktop/agent-runner-tkn:v0.1.0}
    - {name: name, value: run-agent}
    - {name: kind, value: task}
  params:
  - {name: image, value: ghcr.io/podman-desktop/evaluation-agent:v0.2.0}
  - {name: input-path, value: podman-desktop}   # Playwright output inside qe-results
  - {name: api-key-secret, value: codex-api-key}
  - {name: api-key-secret-key, value: api-key}
  - {name: pipeline-name, value: $(context.pipelineRun.name)}
  - {name: artifacts-url, value: $(params.artifacts-url)}
  - name: run-info
    value: |
      pd_version=$(params.tag-name)
      trigger=$(params.trigger-event)
      os=$(tasks.host-info.results.os)
      podman_version=$(params.podman-version)
      provider=$(params.podman-provider)
  workspaces:
  - name: input
    workspace: pipelines-data
    subPath: $(tasks.correlate.results.workspace-resources-path)/qe-results
  - name: output
    workspace: pipelines-data
    subPath: $(tasks.correlate.results.workspace-resources-path)/evaluation

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
  workspaces:
  - name: digest
    workspace: pipelines-data
    subPath: $(tasks.correlate.results.workspace-resources-path)/evaluation
```

The Slack task needs the same `when` on the `correlate` result as
`evaluate-results` when it binds the subPath. Without the `digest` workspace it
posts the `summary` overview as one message. With it, it posts each message of
`digest.json` in order, 2 s apart, at most 15 per run (the 15th says how many
more were left out), and falls back to the overview when the file is missing,
a link, over 256 KiB or not a list of messages.

Bind the `agent-runner` ServiceAccount (no token) to both tasks with
`taskRunSpecs`, as shown in the agent-runner README.

Secrets (created by the namespace owner):

- A dedicated, spend-limited OpenAI project key, in the Secret and key named by
  `api-key-secret` and `api-key-secret-key` (`codex-api-key` and `api-key` above).
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
