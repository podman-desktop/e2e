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

The results directory is named in the request and is also exported to the shell
as `$RESULTS_DIR`. Every command below uses `$RESULTS_DIR`; if the variable is
unset in your shell, substitute the literal path from the request.

## Step 1: Parse json-results.json

Use python3 to extract stats, failures, and platform info (the file can be 2MB+):

```bash
python3 -c "
import json
with open('$RESULTS_DIR/json-results.json') as f:
    data = json.load(f)
stats = data.get('stats', {})
print(json.dumps(stats, indent=2))

def find_failures(suites, path=''):
    for suite in suites:
        current = (path + ' > ' + suite.get('title','')) if path else suite.get('title','')
        for spec in suite.get('specs', []):
            if not spec.get('ok', True):
                for test in spec.get('tests', []):
                    # Playwright appends one result per retry attempt. They are
                    # the same failure, so emit ONE record and carry the attempt
                    # count — reporting each attempt separately would list the
                    # same test two or three times in the digest.
                    failed = [r for r in test.get('results', []) if r.get('status') == 'failed']
                    if not failed:
                        continue
                    last = failed[-1]
                    print(json.dumps({
                        'test': spec.get('title'), 'suite': current,
                        'file': spec.get('file'), 'line': spec.get('line'),
                        'error': last.get('error',{}).get('message','')[:500],
                        'workerIndex': last.get('workerIndex'),
                        'duration': last.get('duration'),
                        'attempts': len(failed),
                        'attachments': last.get('attachments', []),
                    }, indent=2))
        if suite.get('suites'):
            find_failures(suite['suites'], current)

find_failures(data.get('suites', []))
"
```

If `stats.unexpected === 0`, skip to Step 3 (skipped analysis) then output with empty `failures` array.

**One entry per failing test** — never one per retry attempt. A test that failed
on every retry is a single failure with `attempts: 3`, and that repetition is
evidence the failure is deterministic rather than flaky.

## Step 2: Classify each failure — stop at the cheapest sufficient layer

**Read `references/layer1-quick.md` now.** It has the full Layer 1 protocol: finding error-context.md, applying error shortcut patterns, classification categories, and when to escalate.

Apply Layer 1 to every failure. After Layer 1, route each failure:

| Outcome | Action |
|---------|--------|
| `test_bug` or `flaky` at any confidence | **Done** — record result, no trace needed |
| `workerIndex: -1` (load-time error) | **Classify inline**: read `result.error.message` + stack from json-results.json, apply shortcut patterns → done |
| `regression` or `infra` at `confirmed` with a clear root_cause | **Done** |
| `regression` or `infra` at `likely` or `uncertain` | **Escalate to Layer 3** |
| `unknown` | **Escalate to Layer 3** |

For escalated failures: **read `references/layer3-trace.md`** — it has the trace extraction and console scan protocol that provides root_cause evidence.

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
  }
}
```

### Field requirements

- `failures[].error`: First line of error.message only — not the full stack trace
- `failures[].attempts`: How many times the test ran and failed (1 when retries
  are off). Each test appears **once** regardless of this number. Identical
  failures across every retry argue against `flaky`.
- `failures[].root_cause`: WHY the test failed, grounded in actual log/trace evidence. If Layer 1 shows WHAT failed but not WHY, use Layer 3. "Machine stayed OFF" is not enough — "WSL pipe unreachable, event stream ECONNRESET" is.

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
- `failures[].evidence`: 1–3 strings citing specific sources. Format: `"source: what it shows"`. Sources: `error-context.md`, `json-results.json`, `trace`, `console`, `stderr`. Put the detail that does **not** belong in `root_cause` here.
- `failures[].layer`: Deepest layer used (1, 2, or 3). If Layer 1 classified but Layer 3 filled root_cause, report `3`.
- `failures[].title`: Assigned after all failures are classified. Identical for failures sharing root cause.
- `skipped_analysis`: Always present when `summary.skipped > 0`.
- `platform`: Include what is available from `config.metadata` in json-results.json.

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
