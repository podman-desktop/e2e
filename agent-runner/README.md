# agent-runner

A hardened base image and Tekton Task for running **headless Codex agents on CI**
(OpenShift Pipelines). The base carries the Codex CLI, the security policy and a
generic entrypoint, but no task of its own. Each CI job is a small **bundle**
image built `FROM agent-runner` that adds skills, a prompt and an output schema.

```
agent-runner (this directory)          bundle, e.g. evaluation-agent
├── Codex CLI 0.164.0 (pinned)          ├── /etc/codex/skills/<skill>/   skills
├── /etc/codex/requirements.toml       ├── /opt/agent/task/prompt.md
├── /etc/codex/managed_config.toml     ├── /opt/agent/task/output.schema.json
├── /usr/local/bin/agent-runner        └── /opt/agent/task/post.sh      (optional)
└── tkn/task.yaml  (run-agent Task)
```

The security policy lives in one place and every bundle inherits it. Adding a new
CI agent is content only (Markdown + JSON schema), with no new shell, image
hardening or Tekton YAML to review.

## Bundle contract

| Path in the bundle image | Required | Purpose |
|---|---|---|
| `/opt/agent/task/prompt.md` | yes | The request. `{{INPUT_DIR}}` is replaced with the input path; a prompt that uses it needs an input. Name the skill explicitly (`$skill-name`). |
| `/opt/agent/task/output.schema.json` | yes | JSON schema the final answer must match (`codex exec --output-schema`). |
| `/opt/agent/task/post.sh` | no | Bundle-specific checks; must be executable (a non-executable file fails with exit 2). Run as `post.sh <report.json> [<input-dir>]` (the input dir only when there is one). Non-zero fails the run. May write a short summary to `$AGENT_SUMMARY_FILE`. It never sees the API key. |
| `/etc/codex/skills/<name>/` | no | Skills, in Codex's admin skill location (root-owned, read-only). |

Runtime environment:

| Variable | Default | Meaning |
|---|---|---|
| `INPUT_DIR` | — | Optional directory the agent works on (read-only mount). Leave it unset for a job that needs no input data. |
| `CODEX_API_KEY` | — (required) | OpenAI API key. See [Secrets](#secrets). |
| `AGENT_MODEL` | `gpt-6-luna` | Model alias or id. |
| `AGENT_REASONING_EFFORT` | `high` | Model reasoning effort: `none`, `minimal`, `low`, `medium`, `high` or `xhigh`. Higher costs more tokens and time. |
| `AGENT_TIMEOUT` | `12m` | Hard wall-clock limit for the agent (GNU `timeout` syntax). |
| `AGENT_POST_TIMEOUT` | `1m` | Hard wall-clock limit for `post.sh`. Keep `AGENT_TIMEOUT` + `AGENT_POST_TIMEOUT` plus the image pull below the pipelineTask timeout (15m in the examples): a TaskRun killed by that timeout fails despite `onError: continue`. |
| `AGENT_SUMMARY_OUT` | — | Where to copy the post-check summary (the Tekton result). `SKIP` unless the run fully succeeds. |
| `AGENT_SUMMARY_MAX_BYTES` | `3072` | Upper bound on the summary, under Tekton's 4096-byte result limit. |
| `OUTPUT_DIR` | — | Optional writable directory that also receives `report.json`. |

Flow: validate the configuration (an `INPUT_DIR`, when set, must be readable)
→ create a fresh Codex home for this run →
`codex exec --ephemeral --output-schema … -o report.json` under `timeout` → check
the answer is a JSON object → print it to the log → run `post.sh` → publish the
summary.

Exit codes: `2` bad configuration, `124` timeout, any other non-zero is an agent
or post-check failure. Every failure leaves summary `SKIP`. In Tekton the
`run-agent` step has `onError: continue`: the exit code is recorded on the step
and the TaskRun still succeeds, so the advisory agent never fails the
PipelineRun.

## Adding a bundle

1. Write the skill under `.skills/<name>/` (`SKILL.md` + optional `scripts/`,
   `references/`).
2. Create `<bundle>/task/prompt.md` and `<bundle>/task/output.schema.json`. Add
   `post.sh` if the answer can be checked against the input.
3. Add a Containerfile:

   ```dockerfile
   ARG AGENT_RUNNER_IMAGE=ghcr.io/podman-desktop/agent-runner:v0.1.0
   FROM ${AGENT_RUNNER_IMAGE}
   USER 0
   COPY .skills/<name> /etc/codex/skills/<name>
   COPY <bundle>/task/ /opt/agent/task/
   RUN chmod -R a+rX,go-w /etc/codex/skills /opt/agent/task
   USER 1001
   ```

4. Run it with the `run-agent` Task and `image: <your bundle>`.

`evaluation-agent/` is the reference bundle.

## Running in OpenShift Pipelines

`tkn/task.yaml` is a generic `run-agent` Task. A pipeline uses it like this:

```yaml
tasks:
- name: evaluate-results
  runAfter: [podman-desktop-runner]
  timeout: 15m
  # Tekton substitutes a result in subPath only when a param or when
  # expression of this task also uses it.
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
  - {name: input-path, value: podman-desktop}
  - {name: pipeline-name, value: $(context.pipelineRun.name)}
  workspaces:
  - name: input
    workspace: pipelines-data
    # Only this run's results; other runs on the shared PVC stay invisible.
    subPath: $(tasks.correlate.results.workspace-resources-path)/qe-results
```

The `input` workspace is optional. A job that needs no input data leaves it
unbound, along with `input-path` and the `when` expression, and the agent then
has no PVC mounted at all.

The task runs under its own ServiceAccount, which the namespace that runs the
pipeline creates. It holds no RoleBindings and mounts no token, so a
prompt-injected agent cannot use the Kubernetes API:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agent-runner
automountServiceAccountToken: false
```

The PipelineRun binds it to that task only:

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
spec:
  taskRunSpecs:
  - pipelineTaskName: evaluate-results
    serviceAccountName: agent-runner
    podTemplate:
      automountServiceAccountToken: false
```

In a `tekton.dev/v1beta1` PipelineRun the fields are `taskServiceAccountName`
and `taskPodTemplate`. The API silently drops the v1 names there, and the task
then runs as `pipeline` with its token mounted. Check the pod's
`spec.serviceAccountName` after the first run.

### Secrets

The Task reads one Secret, named by the `api-key-secret` param (default
`codex-api-key`), with the key under `api-key`. Use a **dedicated OpenAI project
key with a spend limit**, used only by CI agents, so that a leaked key costs at
most that limit and can be rotated without touching anything else:

```bash
oc create secret generic codex-api-key --from-literal=api-key="$OPENAI_PROJECT_KEY"
```

Don't give the agent pod any other credential. Reporting (Slack, etc.) runs in
a separate Task that gets the bounded `summary` result, not the model key.

One exception is outside the Task's control: Tekton copies docker-type secrets
linked to the ServiceAccount into `/tekton/creds-secrets` and the step's `HOME`
(`/tekton/home`), where the agent can read them. On OpenShift every
ServiceAccount gets such an image-pull secret for the internal registry. Link no
other secrets to `agent-runner`, and treat that pull secret as readable by the
agent.

## Security model

**Threat model.** Agent input is CI output: logs, page snapshots and traces.
Any of it can contain text that steers the model (prompt injection), and the
model can simply make a wrong call. We can't make the model trustworthy, so we
make it **harmless**: the pod limits what it can reach, Codex config limits what
it tries, and the only credential it is given is spend-capped (see
[Secrets](#secrets) for the image-pull secret OpenShift adds).

| Asset | Protected by |
|---|---|
| Kubernetes API, other secrets | ServiceAccount without a token or RoleBindings |
| Other runs' data on the shared PVC | Read-only workspace bound with a run-scoped `subPath` |
| The image and its policy | Non-root, `readOnlyRootFilesystem`, root-owned `/etc/codex`, no privilege escalation, all capabilities dropped, `seccompProfile: RuntimeDefault` |
| The model API key | Excluded from every command the model runs; dedicated project key with a spend limit |
| Other services (Slack, ...) | Their credentials live only in separate Tasks |
| Pipeline result | Hard timeouts; `onError: continue` keeps the advisory agent from failing the run |

### Codex policy (`codex/`)

- **`requirements.toml`** is Codex's enforced admin layer: user config, profiles
  and `-c` flags cannot loosen it.
  - Approval is `never` only, because nobody is there to approve.
  - Web search is disabled, and all MCP servers are disabled (empty `[mcp_servers]`).
    These are the two built-in ways to move data that shell rules don't cover.
  - `forbidden` rules cover network clients, `git`, package managers and environment dumps.
- **`managed_config.toml`** holds the defaults that override user config:
  - `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` (see below).
  - History persistence off, and no update checks.
  - `shell_environment_policy` drops `*KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`,
    `*CREDENTIAL*` and `*WEBHOOK*` variables from every command the model runs.
- **The image** has no `curl`, `wget`, `git`, `ssh`, `npm` or package manager.
  The rules are a second line, not the only one.

### Inner sandbox

Codex's own sandbox (bubblewrap + seccomp) needs user namespaces, which an
OpenShift Pipelines pod can't create. The fix would be `hostUsers: false` with
the `restricted-v3` or `nested-container` SCC, but Tekton's pod template doesn't
expose `hostUsers` yet (SRVKP-9726). We don't weaken the cluster to make it start,
and Codex's guidance allows `danger-full-access` inside an isolated container.
So **the pod is the sandbox**.

Upgrade path, once user namespaces are available to TaskRuns: replace
`sandbox_mode` in `managed_config.toml` with a permission profile (read-only
filesystem except the output directory, `network.enabled = false`) and restrict
`allowed_permission_profiles` in `requirements.toml`. Bundles change nothing.

### Residual risks (accepted)

- **The rules are a blocklist.** Codex has no default-deny, and an `allow` rule
  would run a command *outside* any sandbox. Skills need `python3`, so a
  determined injection can still open an HTTPS connection with the Python
  standard library. What it could send is the read-only input and, at worst,
  the spend-capped API key.
- **The key is in the Codex process environment.** A command can still read
  `/proc/<pid>/environ` as the same UID. The spend cap and rotation bound this.
- **Egress is not restricted.** NetworkPolicy filters by IP and the model API is
  behind a CDN, so it can't tell "OpenAI" from "any HTTPS host". If needed, add a
  pod-label NetworkPolicy (port 443 to non-cluster CIDRs + DNS) or an egress
  proxy / EgressFirewall `dnsName` rule agreed with the namespace owners.

## Build

```bash
make oci-build                          # ghcr.io/podman-desktop/agent-runner:v$(VERSION), linux/amd64
make oci-build PLATFORM=linux/arm64 IMG=localhost/agent-runner:dev   # local testing on Apple Silicon
make oci-push
make tkn-push                           # run-agent Task bundle
```

## Local run

The same restrictions as the cluster pod:

```bash
podman run --rm --read-only --tmpfs /tmp --tmpfs /var/lib/agent-runner \
  --user 1000770000:0 --cap-drop ALL --security-opt no-new-privileges \
  -e CODEX_API_KEY -e INPUT_DIR=/in -v ./results:/in:ro,Z \
  ghcr.io/podman-desktop/evaluation-agent:v0.2.0
```
