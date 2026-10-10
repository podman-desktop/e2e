---
name: evaluate-e2e-results
description: >-
  Batch evaluation of Playwright E2E test failures from CI artifacts.
  Non-interactive, single-pass. Reads json-results.json, error-context.md,
  and trace files from a results directory. Classifies each failure and
  outputs structured JSON. Designed for --print mode in CI pipelines.
  Use this skill whenever the user wants to evaluate, analyze, or triage
  E2E test results, Playwright test failures, or CI test artifacts —
  even if they don't say "evaluate" explicitly.
---

# E2E Test Failure Evaluation

## Context

This skill powers the **pre-release test evaluation pipeline** for Podman Desktop. Its output goes directly into Slack notifications that engineers read to decide whether failures block a release. Every root_cause must be grounded in actual log/trace evidence — not inferred from the error message alone — because engineers need to confidently distinguish "infrastructure issue, safe to ship" from "real regression, blocks release."

## Protocol

This is a **non-interactive batch evaluation**. You are running in `--print` mode inside a CI pipeline. There is no human to ask questions to.

**Rules:**
- Never ask follow-up questions — work with what is available
- Never modify any files — read-only analysis
- Output **only** a single JSON object (the evaluation report) — no markdown, no prose, no explanation outside the JSON
- Classify at the cheapest sufficient layer, but **always ground root_cause in evidence** — if Layer 1 classifies but doesn't explain *why*, escalate to Layer 3 for the root_cause
- If evidence is insufficient for a confident classification, say so in the `confidence` field — do not guess

The results directory path is provided as: $ARGUMENTS

## Input contract

The results directory contains Playwright test output:

```
$ARGUMENTS/
  json-results.json                              — Primary data source (Playwright JSON reporter)
  junit-results.xml                              — JUnit XML (supplementary)
  {slugified-test-path}/error-context.md         — AI-formatted failure context per failed test
  traces/{suite}_w{worker}_trace.zip             — Playwright trace archives
  videos/                                        — Test videos (not used)
  html-results/                                  — HTML report (not used)
```

**Start by reading `json-results.json`** — it contains the complete test run data including error details, attachments pointing to error-context.md files, and test metadata.

**Performance note:** json-results.json can be 2MB+. Instead of reading the raw file (which consumes context window), use `python3` via Bash to extract only what you need — stats, failed specs, and their error details. Example:

```bash
python3 -c "
import json
with open('$ARGUMENTS/json-results.json') as f:
    data = json.load(f)
stats = data.get('stats', {})
print(json.dumps(stats, indent=2))

def find_failures(suites, path=''):
    for suite in suites:
        current = (path + ' > ' + suite.get('title','')) if path else suite.get('title','')
        for spec in suite.get('specs', []):
            if not spec.get('ok', True):
                for test in spec.get('tests', []):
                    for result in test.get('results', []):
                        if result.get('status') == 'failed':
                            print(json.dumps({
                                'test': spec.get('title'), 'suite': current,
                                'file': spec.get('file'), 'line': spec.get('line'),
                                'error': result.get('error',{}).get('message','')[:500],
                                'workerIndex': result.get('workerIndex'),
                                'duration': result.get('duration'),
                                'attachments': result.get('attachments', []),
                            }, indent=2))
        if suite.get('suites'):
            find_failures(suite['suites'], current)

find_failures(data.get('suites', []))
"
```

Similarly, extract skipped tests and platform metadata via python3 rather than reading the full file.

## Step 1: Parse json-results.json

Read `$ARGUMENTS/json-results.json` and extract:

1. **Run summary** from `stats`: `expected` (passed), `unexpected` (failed), `skipped`, `flaky`, `duration`
2. **Platform info** from `config.metadata`: CI commit, build URL, git branch
3. **All failed tests** by traversing the suite hierarchy:

```
suites[] → suites[] → specs[] where ok === false
  → tests[] → results[] where status === "failed"
```

For each failed test, collect:
- `spec.title` — test name
- `spec.file` — spec file path
- `spec.line` — line number
- `result.duration` — execution time in ms
- `result.error.message` — error message
- `result.error.stack` — stack trace
- `result.error.location` — file, line, column of the error
- `result.errors[]` — all errors (may have multiple)
- `result.attachments[]` — paths to error-context.md files (name: "error-context")
- `result.workerIndex` — `-1` indicates a load-time error (no test execution)
- `result.stdout` / `result.stderr` — process output during the test

The parent suite's `title` gives you the spec file name; the parent describe block's `title` gives you the test group.

**If `stats.unexpected === 0`**, output the summary-only JSON (empty `failures` array) but still analyze skipped tests (Step 3) before outputting.

## Step 2: Analyze each failure (layered)

Process each failed test through analysis layers in order. Stop at the first layer that provides sufficient evidence for classification.

### Layer 1: error-context.md (try first — classifies ~70% of failures)

For each failed test, check `result.attachments[]` for entries with `name: "error-context"`. The `path` field contains the absolute path used during the CI run — rebase it to the local results directory:

1. Extract the relative path after the last `output/` segment
2. Prepend `$ARGUMENTS/` to get the local path
3. Read the file

The error-context.md contains:
- `# Test info` — test name and source location
- `# Error details` — the full Playwright error with locator, expected value, timeout, call log
- `# Test source` — source code around the failure with `>` marker at the failing line

**When Layer 1 is sufficient for both classification AND root_cause:** The error shows a self-explanatory cause — a test code error (`ReferenceError`, `SyntaxError`), a clear assertion mismatch with expected vs received values, or a locator that doesn't match any element. The error message itself IS the evidence. This covers `test_bug` and most `flaky` classifications.

**When Layer 1 classifies but root_cause needs Layer 3:** The error-context.md tells you WHAT failed but not WHY. Typical signals:
- Status/state assertions (`toHaveText("RUNNING")` got `"OFF"`) — the error shows the state mismatch, but not what caused the wrong state (infrastructure? app bug? timing?)
- Element not found/not visible — but the element should exist (navigation links, connection cards), so something upstream broke
- Timeouts on operations that involve external systems (machine start, container operations, registry pulls)

For these cases, **classify provisionally at Layer 1** but **escalate to Layer 3 to fill in root_cause with actual log evidence**. The root_cause field goes into Slack notifications for release decisions — "machine stayed OFF" is not actionable, but "WSL pipe unreachable, event stream ECONNRESET" tells the engineer it's infrastructure.

### Layer 2: json-results.json errors (for failures without error-context.md)

Some failures produce no error-context.md:
- **Load-time errors** (`workerIndex: -1`, `duration: 0`): import failures, syntax errors, circular dependencies. The `error.message` and `error.stack` from json-results.json contain the full diagnostic.
- **Crashes or early exits**: test process died before Playwright could generate artifacts.

For these, the `result.error` object in json-results.json is the primary evidence. The error message + stack trace is usually sufficient to classify.

### Layer 3: Trace analysis (root_cause evidence — used for ~30% of failures)

Use when:
- error-context.md is absent AND json-results.json error is insufficient
- **Layer 1 classified but root_cause is not grounded in evidence** — the error says WHAT failed but not WHY (e.g., status assertion mismatch, element missing without explanation, operation timeout)
- You suspect a `pageError` or console error happened before the test actions
- Classification is `infra` or `regression` — these affect release decisions and need evidence-backed root_cause

Find the trace file: look in `$ARGUMENTS/traces/` for a zip file matching the test's suite name pattern (`{suite-name}_w{workerIndex}_trace.zip`).

Extract and parse:

```bash
mkdir -p /tmp/trace-analysis && cd /tmp/trace-analysis && unzip -o "$ARGUMENTS/traces/{name}_trace.zip"
```

#### Action timeline + errors

```bash
python3 -c "
import json, sys
with open('trace.trace') as f:
    for line in f:
        obj = json.loads(line.strip())
        t = obj.get('type', '')
        if t == 'before':
            cid = obj.get('callId', '')
            cls = obj.get('class', '')
            method = obj.get('method', '')
            sel = str(obj.get('params', {}).get('selector', ''))[:100]
            title = obj.get('title', '')
            label = title or f'{cls}.{method}'
            print(f'[{cid}] {label} selector={sel}' if sel else f'[{cid}] {label}')
        elif t == 'after' and obj.get('error'):
            err = obj['error']
            msg = err.get('message', '')[:200]
            print(f'[{obj[\"callId\"]}] ERROR: {msg}')
        elif t == 'event':
            method = obj.get('method', '')
            if method == 'pageError':
                err = obj.get('params', {}).get('error', {}).get('error', {})
                print(f'PAGE_ERROR: {err.get(\"message\", \"\")[:200]}')
"
```

#### Exhaustive console scan

Scan ALL severity levels for failure keywords — application code frequently logs critical errors at `console.log` level, not `console.error`.

```bash
python3 -c "
import json
KEYWORDS = ['error', 'fail', 'typeerror', 'referenceerror', 'syntaxerror',
    'reject', 'crash', 'abort', 'econnrefused', 'enotfound', 'etimedout',
    'fetch failed', 'tls', 'cert', 'ssl', 'socket', 'refused', 'timeout',
    'unauthorized', 'forbidden', 'unreachable', 'cannot', 'unable']
with open('trace.trace') as f:
    for line in f:
        obj = json.loads(line.strip())
        if obj.get('type') != 'console': continue
        args = obj.get('args', [])
        text = ' '.join(str(a.get('preview', '') or a.get('value', '')) for a in args)[:300]
        mt = obj.get('messageType', '')
        if mt in ('error', 'warning') or any(k in text.lower() for k in KEYWORDS):
            print(f'CONSOLE [{mt}]: {text}')
"
```

**Key signal from traces:** `pageError` events (app-level JavaScript errors) that occur before test actions. These are invisible in error-context.md but often explain why the UI is in a broken state.

## Step 3: Analyze skipped tests

Skipped tests can hide regressions. A silently skipped suite in a release run could mean an entire feature area went untested. Traverse the suite hierarchy to categorize every skipped test.

### How Playwright reports skips

There are two distinct kinds:

1. **By-design skips** — `test.annotations[]` contains an entry with `type: "skip"` and usually a `description` explaining why (e.g., `"Certificate sync via podman machine ssh hangs on Windows CI runners"`). These are intentional exclusions for this platform/config.

2. **Cascade skips** — `test.annotations[]` is empty, but a prior test in the same `test.describe.serial` block failed. Playwright auto-skips remaining tests in that serial suite. These represent hidden test coverage loss caused by a failure.

### How to detect each kind

```
For each skipped test (result.status === "skipped"):
  if test.annotations[] has entry with type === "skip":
    → by_design skip, reason = annotation.description
  else:
    → cascade skip, find the failed test in the same parent suite
```

### What to report

Group by-design skips by their skip reason (many tests share the same reason). Link cascade skips back to the failure that caused them — use the failed test name from the same parent suite.

This matters for release decisions: 52 skipped tests is fine if they're all by-design platform exclusions. But if 8 of those are cascade skips from an infra failure, engineers need to know that the machine lifecycle tests were never actually validated.

## Classification

Classify each failure into exactly one category with a confidence level.

### Categories

| Category | Definition | Typical signals |
|----------|-----------|-----------------|
| `regression` | App behavior changed — test was previously passing and is now failing due to an app code change | Assertion mismatch on app state, element missing that was previously present, new error in app code |
| `test_bug` | Test code is wrong — bad locator, wrong assertion, stale page object, import error in test code | `ReferenceError` in test file, locator doesn't match current DOM structure, assertion checks wrong value |
| `flaky` | Timing-sensitive or non-deterministic — would likely pass on retry | Timeout on element that eventually appears, race with async data loading, animation blocking interaction |
| `infra` | CI environment issue, not app or test code | Missing binary, network failure, provisioning error, container storage corruption, registry pull failure |
| `unknown` | Insufficient evidence to classify | Error message is ambiguous, no error-context.md, no trace, error doesn't match known patterns |

### Confidence levels

| Level | Definition |
|-------|-----------|
| `confirmed` | Evidence directly demonstrates the root cause (e.g., import error with exact stack trace, or assertion showing exact expected vs received) |
| `likely` | Evidence strongly suggests the cause but an alternative explanation exists (e.g., timeout that usually indicates flakiness but could be a real regression) |
| `uncertain` | Multiple plausible explanations — classification is the best guess from available evidence |

## Error → diagnosis shortcuts

Use these patterns to fast-track classification without deep analysis. Match against `result.error.message` from json-results.json.

| Error pattern | Classification | Confidence | Rationale |
|---------------|---------------|------------|-----------|
| `ReferenceError: Cannot access '...' before initialization` | `test_bug` | `confirmed` | Circular dependency in test code |
| `SyntaxError` in test file | `test_bug` | `confirmed` | Test code doesn't parse |
| `TypeError: Cannot read properties of undefined` in test file | `test_bug` | `confirmed` | Test code runtime error |
| `expect(locator).toBeVisible() failed` with timeout ≤ 10s | `flaky` | `likely` | Short timeout, element may appear later |
| `expect(locator).toBeVisible() failed` with timeout > 30s | `regression` | `likely` | Long timeout — element probably never renders |
| `expect(locator).toHaveText()` actual vs expected mismatch | `regression` | `likely` | App produces different text than expected |
| `strict mode violation: ... resolved to N elements` | `test_bug` | `likely` | Locator is too broad |
| `intercepts pointer events` | `flaky` | `likely` | Modal or overlay blocking — timing issue |
| `Test timeout of N ms exceeded` + `Target page closed` | `flaky` | `likely` | Operation exceeded overall test timeout |
| `ECONNREFUSED` / `ENOTFOUND` / `ETIMEDOUT` | `infra` | `likely` | Network issue in CI environment |
| `no such file or directory` for system binary | `infra` | `confirmed` | Missing dependency |
| `unable to copy from source docker://` | `infra` | `likely` | Registry pull failure |
| `overlay/.../merged: no such file` / `copier subprocess` | `infra` | `confirmed` | Container storage corruption |

## Electron-specific patterns

Podman Desktop is an Electron app. These patterns appear in traces and error-context.md:

- **IPC failures**: console errors mentioning `ipcRenderer`, `ipcMain`, or channel names — broken main↔renderer communication
- **Preload script errors**: errors during preload — renderer lacks expected APIs
- **`ipcNative` object missing**: `Attempted to get the 'ipcNative' object but it was missing` — **this is noise**, ignore it. It appears in normal Electron startup and does not indicate a failure.
- **Webview loading**: webview's document failed to load — check for webview console messages
- **`file://` URLs**: Electron loads local files — `file://` network requests in traces are normal, not failures

## Noise to ignore

These errors appear in normal test runs and do not indicate failures:

- `Gtk: gtk_widget_add_accelerator: assertion failed` — Electron/Gtk compat on Linux
- `npm warn Unknown env config` — pnpm/npm config mismatch
- `cpu-features install: Error: Unable to detect compiler type` — optional native module
- `Error trying to run the version on docker-compose. Binary might not be there` — expected when compose is not installed
- `Error: Failed to execute command: spawn kind ENOENT` — expected when kind is not installed
- `Attempted to get the 'ipcNative' object but it was missing` — normal Electron startup
- `Removing raw traces folder:` — normal cleanup log
- `Saving a video file took:` — normal video save log

When these appear in `result.stderr` or console output, do not count them as failure evidence.

## Output contract

Output **only** a single JSON object. No markdown fences, no explanation text, no preamble. The JSON must be valid and parseable.

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
      "error": "Short error message from error.message (first line only)",
      "classification": "regression | test_bug | flaky | infra | unknown",
      "confidence": "confirmed | likely | uncertain",
      "root_cause": "One sentence explaining why the test failed",
      "evidence": [
        "Brief citation of the evidence that supports the classification"
      ],
      "recommended_action": "Specific action to fix or investigate",
      "layer": 1
    }
  ],
  "skipped_analysis": {
    "total_skipped": 50,
    "by_design": 42,
    "cascade": 8,
    "by_design_reasons": [
      {
        "reason": "Certificate sync via podman machine ssh hangs on Windows CI runners",
        "count": 2,
        "spec_file": "tests/playwright/src/specs/certificate-sync-smoke.spec.ts"
      }
    ],
    "cascade_details": [
      {
        "skipped_test": "Podman machine operations - EDIT privileges",
        "caused_by_failure": "Podman machine operations - RESTART",
        "spec_file": "tests/playwright/src/specs/z-podman-machine-onboarding.spec.ts"
      }
    ]
  },
  "platform": {
    "os": "linux | darwin | win32",
    "arch": "x64 | arm64",
    "node_version": "from config.argv[0] path or metadata",
    "playwright_version": "from config.version or trace context-options",
    "ci_url": "from config.metadata.ci.buildHref if available",
    "commit": "from config.metadata.ci.commitHash if available",
    "branch": "from config.metadata.gitCommit.branch if available"
  }
}
```

### Field requirements

- `summary`: Always present. Computed from `stats` in json-results.json.
- `failures`: Array of failure objects. Empty array if no failures (all-pass run). One entry per unique failed spec (not per retry).
- `failures[].error`: First line of the error message only — not the full stack trace.
- `failures[].root_cause`: One sentence explaining WHY the test failed, grounded in actual evidence from logs/traces — not inferred from the error message alone. If Layer 1 only shows WHAT failed (e.g., "status was OFF"), the root_cause must cite what Layer 3 found (e.g., "WSL pipe unreachable, event stream ECONNRESET during machine restart"). If no deeper evidence is available, state what is known and flag the gap: "Machine did not restart within 360s — no trace available to determine underlying cause."
- `failures[].evidence`: Array of 1-3 short strings citing specific evidence. Format: `"source: what it shows"`. Sources: `error-context.md`, `json-results.json`, `trace`, `console`, `stderr`. Evidence must come from actual file content, not from assumptions about what might have happened.
- `failures[].layer`: The deepest analysis layer used for this failure (1, 2, or 3). If Layer 1 classified but Layer 3 provided the root_cause evidence, report `3`.
- `skipped_analysis`: Always present when `summary.skipped > 0`. Breaks down skipped tests into by-design and cascade categories.
- `skipped_analysis.by_design_reasons[]`: Grouped by skip reason. Each entry has `reason` (the annotation description), `count`, and `spec_file`.
- `skipped_analysis.cascade_details[]`: One entry per cascade-skipped test. Each links `skipped_test` to `caused_by_failure` (the failed test in the same serial suite) and `spec_file`.
- `platform`: Extracted from json-results.json metadata. Fields are optional — include what is available.

## Slack formatting (optional post-processing)

The bundled `scripts/slack_formatter.py` transforms the evaluation JSON into a Slack Block Kit message. It is not part of the evaluation — run it as a separate pipeline step after the skill produces its output.

```bash
# In the Tekton task step:
claude --print ... > /tmp/evaluation-raw.txt
cat /tmp/evaluation-raw.txt | python3 /path/to/slack_formatter.py \
  --pipeline-name "$PIPELINE_NAME" \
  --artifacts-url "$ARTIFACTS_URL" \
  | curl -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL"
```

The formatter:
- Strips any preamble text before the JSON (handles `--print` mode behavior)
- Shows header with pass/fail status and platform
- Lists each failure with classification emoji, root_cause, and recommended action
- Shows cascade skip summary when failures caused additional test skips
- Adds links to artifacts and CI run when provided

Environment variables `ARTIFACTS_URL`, `PIPELINE_NAME` can substitute for CLI args.

## Constraints

- **No questions**: Never ask the user for clarification. Work with available evidence.
- **No file modifications**: Read-only analysis. Never write, edit, or create files.
- **Single pass**: Analyze once, output once. No iterative refinement.
- **JSON only**: Your entire output must be a single valid JSON object. No markdown fences (no ` ```json `), no prose before or after, no "here is the result" preamble. The raw stdout must be directly parseable by `json.loads()` — the CI pipeline pipes your output to a JSON parser.
- **Budget awareness**: Process failures in order. If you have many failures (>20), prioritize the first 20 and add a `"truncated": true` field to the output with `"truncated_count"` showing how many were skipped.
