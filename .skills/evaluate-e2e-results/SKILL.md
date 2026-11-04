---
name: evaluate-e2e-results
description: >-
  Batch evaluation of Playwright E2E test failures from CI artifacts.
  Non-interactive, single-pass. Reads json-results.json, error-context.md,
  and trace files from a results directory. Classifies each failure and
  outputs structured JSON. Designed for headless, single-turn agent runs
  in CI pipelines.
  Use this skill whenever the user wants to evaluate, analyze, or triage
  E2E test results, Playwright test failures, or CI test artifacts —
  even if they don't say "evaluate" explicitly.
---

# E2E Test Failure Evaluation

## Context

This skill powers the **pre-release test evaluation pipeline** for Podman Desktop. Its output feeds directly into Slack notifications that engineers use to decide whether failures block a release. Every `root_cause` must be grounded in actual log/trace evidence — not inferred from the error message alone — because engineers need to confidently distinguish "infrastructure issue, safe to ship" from "real regression, blocks release."

## Protocol

This is a **non-interactive batch evaluation** running headlessly (one turn, no
user present) inside a CI pipeline. Any agent runtime that can read files and
run shell commands can execute it.

**Rules:**
- Never ask follow-up questions — work with what is available
- Never modify any files — read-only analysis
- Output **only** a single JSON object — no markdown fences, no prose, no preamble
- If evidence is insufficient, express it in `confidence: uncertain` — do not guess

## Input

The results directory is named in the request and is usually also exported to
the shell as `$RESULTS_DIR`. Every command in this skill and its reference files
reads that variable, so set it once before anything else and the rest just work:

```bash
export RESULTS_DIR="${RESULTS_DIR:-<path from the request>}"
ls "$RESULTS_DIR"
```

The `ls` confirms the path resolves. A results bundle normally holds
`json-results.json`, a `traces/` directory, and one output directory per failing
test.

## Step 1: Parse json-results.json

The file can be 2MB+, so never read it directly — this command extracts the
summary and one record per failing test:

```bash
python3 -c "
import json, re, os
ANSI = re.compile(r'\x1b\[[0-9;]*m')
RD = os.environ['RESULTS_DIR']
with open(RD + '/json-results.json') as f:
    data = json.load(f)

# Playwright reports no 'total' or 'passed' — derive them, and note that
# stats.duration is milliseconds while the output schema wants seconds.
st = data.get('stats', {})
print(json.dumps({'summary': {
    'total': st.get('expected',0) + st.get('unexpected',0) + st.get('flaky',0) + st.get('skipped',0),
    'passed': st.get('expected',0),
    'failed': st.get('unexpected',0),
    'skipped': st.get('skipped',0),
    'flaky': st.get('flaky',0),
    'duration_s': round(st.get('duration',0)/1000, 2),
}}, indent=2))

# Reports produced on Windows runners carry backslash paths; the digest and
# the local filesystem both want forward slashes.
def slash(p):
    return (p or '').replace(chr(92), '/')

def error_context(attachments):
    # The attachment path is absolute on the CI machine. Its last two segments
    # — test output directory and filename — are what exists locally.
    for a in attachments:
        if a.get('name') == 'error-context' and a.get('path'):
            return RD + '/' + '/'.join(slash(a['path']).split('/')[-2:])
    return None

def find_failures(suites, path='', depth=0):
    for suite in suites:
        # The outermost suite title is the spec file path, which spec_file
        # already carries — start the describe chain one level in.
        title = suite.get('title', '')
        current = path if depth == 0 else ((path + ' > ' + title) if path else title)
        for spec in suite.get('specs', []):
            if spec.get('ok', True):
                continue
            for test in spec.get('tests', []):
                # Playwright appends one result per retry attempt. They are
                # the same failure, so emit ONE record and carry the attempt
                # count — reporting each attempt separately would list the
                # same test two or three times in the digest.
                # A test Playwright counted as unexpected does not always have
                # a result with status 'failed': a test that ran out of time
                # reports 'timedOut', and one abandoned after maxFailures
                # reports 'interrupted'. Matching only 'failed' would drop
                # those tests, leaving a digest that counts failures it cannot
                # list.
                bad = [r for r in test.get('results', [])
                       if r.get('status') in ('failed', 'timedOut', 'interrupted')]
                if not bad:
                    continue
                last = bad[-1]
                msg = ANSI.sub('', last.get('error', {}).get('message', ''))
                print(json.dumps({
                    'test': spec.get('title'), 'suite': current,
                    'spec_file': slash(spec.get('file')), 'line': spec.get('line'),
                    'status': last.get('status'),
                    'error': msg.split(chr(10))[0][:300],
                    'error_full': msg[:800],
                    'workerIndex': last.get('workerIndex'),
                    # start_time + duration_ms locate this test inside its
                    # worker's trace, which also holds the tests around it.
                    'start_time': last.get('startTime'),
                    'duration_ms': last.get('duration'),
                    'attempts': len(bad),
                    'error_context': error_context(last.get('attachments', [])),
                }, indent=2))
        find_failures(suite.get('suites', []), current, depth + 1)

find_failures(data.get('suites', []))
"
```

The `summary` block it prints goes straight into the output — don't recompute
it by hand.

If `stats.unexpected == 0`, check the report's top-level errors before calling
the run clean:

```bash
python3 -c "
import json, os
data = json.load(open(os.environ['RESULTS_DIR'] + '/json-results.json'))
print(json.dumps(data.get('errors', []), indent=2)[:2000])
"
```

A config or `globalSetup` failure lands there and nowhere else, because it
happens before any test exists to be counted — so the stats can read zero
failures while the run never actually tested anything. The array is empty on a
healthy run, which makes anything in it signal. Report those errors as
`failures` (see `references/layer2-logs.md`) rather than sending an all-clear.
Only when it is empty should you skip to Step 3 (skipped analysis) and output
an empty `failures` array.

Two things the command handles that are easy to get wrong by hand: Playwright
colours its error messages with ANSI escapes, which turn into `[2m[31m` litter
in Slack if not stripped, and Windows runners emit `\` paths that break both
path matching and readability.

**One entry per failing test** — never one per retry attempt. A test that failed
on every retry is a single failure with `attempts: 3`, and that repetition is
evidence the failure is deterministic rather than flaky.

## Step 2: Classify each failure — stop at the cheapest sufficient layer

The three layers cost very different amounts, so climb only as far as the
evidence requires:

| Layer | Source | Cost |
|-------|--------|------|
| 1 | `error-context.md` — the Playwright assertion and page snapshot | one file read per failure |
| 2 | `json-results.json` — app stdout/stderr, full error stack, top-level errors | one command for the whole run |
| 3 | `traces/*.zip` — action timeline, console, pageErrors | unzip + parse a multi-MB archive per failure |

**Read `references/layer1-quick.md` now.** It has the full Layer 1 protocol: finding error-context.md, applying error shortcut patterns, classification categories, and when to escalate.

Apply Layer 1 to every failure. After Layer 1, route each failure:

| Outcome | Action |
|---------|--------|
| `test_bug` at any confidence | **Done** — record result, no deeper layer needed |
| `flaky` with `attempts: 1` | **Done** |
| `flaky` with `attempts > 1` | **Layer 2** — it failed the same way on every retry, which is the opposite of what a flake does. Let the logs confirm before the digest tells the reader to ignore it |
| `regression` or `infra` at `confirmed` with a clear root_cause | **Done** |
| No `error_context` path, or `workerIndex: -1` | **Layer 2** — the artifact does not exist, so json-results.json is the only evidence |
| `regression` or `infra` at `likely` or `uncertain` | **Layer 2**, then Layer 3 if the logs explain nothing |
| `unknown` | **Layer 2**, then Layer 3 if the logs explain nothing |

**Read `references/layer2-logs.md`** for anything routed to Layer 2. Its log
scan runs once and covers every failure at once, so run it before deciding
which failures still need a trace — app logs frequently explain a Layer 1
"element never appeared" outright, and a resolved failure is one trace you
don't have to unzip.

**Read `references/layer3-trace.md`** for whatever Layer 2 leaves unexplained — it has the trace extraction and console scan protocol that provides root_cause evidence.

## Step 3: Analyze skipped tests

Read the "Skipped test analysis" section in `references/layer1-quick.md`.

## Step 4: Assign `title` to all failures

After classifying **all** failures, do a single grouping pass:

- `title` = 3–6 word noun-phrase naming the **underlying issue**, not the test name
- Failures sharing the same root cause **must** get the **same `title`** — it drives Slack grouping
- Examples: `"krunkit Crash on Start"`, `"Registry Pull Timeout"`, `"CDP Runner Incompatibility"`, `"Podman Machine Init Failure"`
- Assign in one pass after seeing all failures — never per-failure during classification

## Step 5: Output JSON

Output **only** a single valid JSON object. No markdown fences, no preamble. Must be directly parseable by `json.loads()`.

```json
{
  "summary": {
    "total": 278,
    "passed": 191,
    "failed": 2,
    "skipped": 85,
    "flaky": 0,
    "duration_s": 1242.68
  },
  "failures": [
    {
      "test": "Test name from spec.title",
      "suite": "describe block title",
      "spec_file": "tests/playwright/src/specs/example.spec.ts",
      "line": 298,
      "duration_ms": 10006,
      "attempts": 3,
      "status": "failed | timedOut | interrupted",
      "error": "Short error message (first line only)",
      "classification": "regression | test_bug | flaky | infra | unknown",
      "confidence": "confirmed | likely | uncertain",
      "title": "Short noun-phrase (3-6 words) — identical for failures sharing the same root cause",
      "root_cause": "Two short sentences, 45 words max: the symptom, then the mechanism. Plain language, no nested parentheticals.",
      "evidence": ["source: what it shows"],
      "recommended_action": "One concrete next step, 30 words max",
      "layer": 1
    }
  ],
  "skipped_analysis": {
    "total_skipped": 50,
    "by_design": 42,
    "cascade": 8,
    "unresolved": 0,
    "by_design_reasons": [
      {"reason": "Reason text from annotation", "count": 2, "spec_file": "..."}
    ],
    "cascade_details": [
      {"skipped_test": "Test name", "caused_by_failure": "Failed test name", "spec_file": "..."}
    ]
  },
  "platform": {
    "os": "linux | darwin | win32",
    "arch": "x64 | arm64",
    "node_version": "...",
    "playwright_version": "...",
    "ci_url": "...",
    "commit": "...",
    "branch": "..."
  },
  "truncated": false,
  "truncated_count": 0
}
```

### Field requirements

- `failures[].error`: First line of error.message only, ANSI escapes stripped — not the full stack trace
- `failures[].suite`: The `describe` title only. The outermost Playwright suite
  is the spec file path, which `spec_file` already carries — repeating it here
  makes the Slack line read `tests\playwright\...spec.ts > Network smoke tests`.
- `failures[].spec_file`: Repo-relative path with forward slashes, even when the
  report came from a Windows runner.
- `failures[].attempts`: How many times the test ran and failed (1 when retries
  are off). Each test appears **once** regardless of this number. Identical
  failures across every retry argue against `flaky`.
- `failures[].status`: The last result's Playwright status — `failed`,
  `timedOut`, or `interrupted`. `interrupted` means the run was cut short
  (usually `maxFailures`), so the test is not really a verdict on anything;
  say so instead of classifying it.
- `failures[].root_cause`: WHY the test failed, grounded in actual log/trace evidence. If Layer 1 shows WHAT failed but not WHY, go to Layer 2 and then Layer 3. "Machine stayed OFF" is not enough — "WSL pipe unreachable, event stream ECONNRESET" is.

  **Write it to be skimmed.** This line is read in Slack by an engineer deciding
  whether to block a release. Hard limits:
  - **Two short sentences, 45 words total.** First sentence: the observable
    symptom. Second: the mechanism behind it.
  - **No nested parentheticals and no chains of em-dashes.** If a clause needs
    a bracket, it is supporting detail — move it to `evidence`.
  - **Plain language.** Prefer "the command never appeared in the palette" over
    "the page snapshot captured at timeout shows the palette search box still
    holding the typed command text".

  Good: `The "Synchronize certificates" command is missing from the command
  palette. The palette returned no matches for the full 180s wait, so the sync
  task was never created.`

  Bad (one 70-word sentence, three parentheticals): `After starting an
  interactive/TTY container and opening its details, the Logs tab renders the
  empty-state ('No Log' heading, 'Log output of alpine-container') instead of
  the xterm buffer, across the original attempt and both retries (all 3 fail
  identically at ~5.1s with the same hidden .xterm-rows element) — the
  container's state was already confirmed Running moments earlier…`
- `failures[].recommended_action`: One concrete next step, 30 words max. What to
  open, check, or try first — not a list of alternatives.
- `failures[].evidence`: 1–3 strings citing specific sources. Format: `"source: what it shows"`. Sources: `error-context.md`, `json-results.json`, `stdout`, `trace`, `console`. Put the detail that does **not** belong in `root_cause` here.
- `failures[].layer`: The layer whose evidence grounded the `root_cause`, not
  the layer that produced the classification label. Layer 1 classifying a
  timeout and Layer 2's app log explaining it is `2`; the same failure needing
  the trace is `3`. The digest shows this as the basis of the verdict, so an
  inflated number makes a guess look investigated.
- `failures[].title`: Assigned after all failures are classified. Identical for failures sharing root cause.
- `skipped_analysis`: Always present when `summary.skipped > 0`. `by_design`,
  `cascade` and `unresolved` must sum to `total_skipped` — a skip you cannot
  attribute belongs in `unresolved`, not in `cascade`.
- `platform`: Fill only fields the artifacts actually support —
  `playwright_version` from `config.version`, plus whatever `config.metadata`
  carries (often just `actualWorkers`). The OS can be read off the runner paths
  in the report or the pipeline name. **Omit a key rather than invent it**: a
  wrong `commit` sends someone bisecting the wrong range, and nothing downstream
  needs these fields to be present.
- `truncated` / `truncated_count`: Only when more than 20 failures exist. Omit
  both otherwise.

## Slack formatting (post-processing step)

The bundled `scripts/slack_formatter.py` transforms evaluation JSON into a flat `{"text": "..."}` payload for a Slack Workflow Builder webhook trigger (not Block Kit).

```bash
# <agent CLI, headless> ... > /tmp/evaluation-raw.txt
cat /tmp/evaluation-raw.txt | python3 /path/to/slack_formatter.py \
  --pipeline-name "$PIPELINE_NAME" \
  --artifacts-url "$ARTIFACTS_URL" \
  | curl -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL"
```

Environment variables `ARTIFACTS_URL`, `PIPELINE_NAME`, `SLACK_WORKFLOW_VAR` can substitute for CLI args.

## Constraints

- **No questions** — never ask for clarification; work with available evidence
- **No file modifications** — read-only analysis
- **Single pass** — analyze once, output once
- **JSON only** — entire stdout must be a single parseable JSON object
- **Budget**: process up to 20 failures in order; add `"truncated": true` and `"truncated_count"` if more exist
- **Trace budget**: Layers 1 and 2 are cheap and cover every failure; traces are
  not. On a run with many unexplained failures, spend traces on the
  `regression` and `infra` candidates — those decide whether the release ships —
  and report the rest at the confidence Layer 2 supports. An honest `uncertain`
  is more useful than twenty shallow traces that blow the context window before
  the output is written.
