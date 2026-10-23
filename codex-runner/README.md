# Codex CI runner

A generic headless Codex runtime based on Red Hat UBI 9 Node.js 22 Minimal.
It includes Bash, Python, Git, jq, unzip, curl, CA certificates, and GNU timeout.
Skills, task definitions, evaluation logic, and reporting are supplied by the
consumer; none are included in this image.

## Build

From the repository root:

```bash
make -C codex-runner oci-build
# Optional, explicit publishing after authenticating to your registry:
make -C codex-runner oci-push
```

The default image is `ghcr.io/podman-desktop/codex-runner:v0.1.0`. Override `IMG`
to use your own registry or a local tag. `PLATFORM` defaults to `linux/amd64`
for the CI nodes, including when building on Apple Silicon; use
`PLATFORM=linux/arm64` for a native ARM development image. The Codex package
supports these two Linux architectures. The UBI manifest-list digest and
`CODEX_CLI_VERSION` are pinned; change the version explicitly when upgrading.

`codex-runner/` is the entire build context. Its `.containerignore` only affects
this image. `EXTRA_BUILD_ARGS` accepts additional build flags.

## Run

Provide an API key in the calling environment; do not put it in the image or
command arguments. Mount inputs read-only when the agent should only inspect
them. Use absolute container paths in prompts and output options: each run
starts in a new scratch working directory.

```bash
podman run --rm --read-only --tmpfs /tmp:rw,nosuid,nodev \
  --tmpfs /var/lib/codex-runner:rw,nosuid,nodev,mode=0770 \
  --cap-drop=all --security-opt=no-new-privileges \
  -e CODEX_API_KEY \
  -v "$PWD/artifacts:/artifacts:ro" \
  ghcr.io/podman-desktop/codex-runner:v0.1.0 \
  'Summarize the files under /artifacts.'

# Or read the prompt from stdin (-i is required; no TTY is needed):
printf '%s\n' 'Summarize /artifacts.' | podman run --rm -i \
  -e CODEX_API_KEY -e AGENT_MODEL=gpt-6-luna -e AGENT_TIMEOUT=3m \
  -v "$PWD/artifacts:/artifacts:ro" \
  ghcr.io/podman-desktop/codex-runner:v0.1.0 -
```

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `CODEX_API_KEY` | Required | OpenAI API key, injected only at runtime |
| `AGENT_MODEL` | `gpt-6-luna` | Default model; selectable at runtime |
| `AGENT_TIMEOUT` | `3m` | Positive GNU timeout duration; zero is rejected |
| `AGENT_STATE_DIR` | `/var/lib/codex-runner` | Writable parent for private per-run state; keep outside the system temporary directory |

Arguments are passed to `codex exec`. Standard options include `--json` for
JSONL events, `--output-last-message /output/report.txt` for the final response,
`--output-schema /input/schema.json`, and `--cd /workspace`. Mount output
directories writable when using file outputs. Explicit `--model` and
`--sandbox` arguments override the runner defaults. `--help` and `--version`
work without credentials.

The runner uses `--ask-for-approval never`, `--ephemeral`, and
`--skip-git-repo-check`. It defaults to `workspace-write` sandboxing in the
scratch directory, allowing temporary analysis while input mounts remain
read-only. It does not retry with weaker sandbox permissions if the host
cannot support Codex's Linux sandbox. Confirm sandbox support on your target
OpenShift cluster before using the image in a pipeline; local container checks
do not establish cluster compatibility.

At the deadline, GNU timeout sends SIGTERM to the command group and escalates
to SIGKILL after five seconds. Normal failures retain their exit code; a
timeout normally returns 124 (137 if forced termination is necessary).
Container termination signals are forwarded to the command group. Configure
the enclosing task timeout to allow time for this shutdown and any reporting.

## OpenShift and consumers

The image defaults to UID 1001 and supports an arbitrary OpenShift-assigned UID
in group 0 without a passwd entry. Configuration, caches, and the working
directory are isolated under a private per-run state directory, then removed
on exit. Codex creates executable helper aliases there and requires this state
to live outside the system temporary directory.

For a read-only root filesystem, provide writable volumes at `/tmp` and
`/var/lib/codex-runner`. With Podman, use the tmpfs mounts shown above; with
OpenShift, use `emptyDir` volumes with the SCC's volume permissions. A writable
home directory is not needed. Inject `CODEX_API_KEY` from a Secret in the
consuming task.

For a skill-specific image, extend this image and copy reviewed skills into
`/etc/codex/skills/<name>/`. Task authors own skill invocation, result validation,
and delivery. The generic runner imposes a time limit, not a dollar budget;
Codex event usage reports tokens rather than a USD cost.

See [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode),
[skill discovery](https://learn.chatgpt.com/docs/build-skills), and
[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna).
