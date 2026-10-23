# Layer 3: Trace Analysis for Evidence-Backed Root Cause

Use this layer when a failure still has no evidence-backed `root_cause` after
Layer 2 — the error shows WHAT failed, and the app logs didn't say why.

**When to use Layer 3:**
- `infra` or `regression` at `likely` or `uncertain` that the Layer 2 log scan left unexplained
- `unknown` classification (insufficient evidence from error-context.md and logs)
- Status/state assertion mismatch (e.g., machine stayed OFF — but why?)
- Element missing/not visible — but should have existed
- Operation timeout involving external systems
- You suspect a renderer-side `pageError`, which never reaches stdout

Traces are the expensive layer: a single archive runs to several MB and a few
thousand events. Spend it on failures that will change someone's release
decision — a `regression` or `infra` candidate — not on confirming a `test_bug`
you already understand.

## Finding the trace file

Traces are named `{suite-name}_w{workerIndex}_trace.zip`:

```bash
ls "$RESULTS_DIR/traces/"
```

**Match on `_w{workerIndex}_`, taken from the failure record.** The suite name
in the filename comes from the Playwright project, not the spec file, so
`compose-onboarding-smoke.spec.ts` lives in `compose-onboarding-e2e_w0_trace.zip`
— substring-matching the spec name finds nothing or, worse, finds a neighbour's
trace. Workers are unique within a run, so the index is exact.

## Extracting the trace

Extract each archive into its own directory keyed by worker. `unzip -o` into a
shared path leaves the previous `trace.trace` in place if the extraction fails,
and you would then read one failure's evidence while writing another's
root_cause:

```bash
WORKER=0  # from the failure record
DEST="/tmp/trace-analysis/w$WORKER"
mkdir -p "$DEST"
unzip -o "$RESULTS_DIR/traces/"*_w${WORKER}_trace.zip trace.trace -d "$DEST"
```

The trace file is `trace.trace` — newline-delimited JSON, one event per line.

**A trace covers everything that worker ran, not just the failing test.** The
earlier tests in it passed, so a console error from the middle of the file may
belong to a test that succeeded. Locate the failing test's segment first — the
action titles name the test steps — and treat only events inside it as evidence
for this failure.

## Scoping to the failing test

Trace events are timestamped on a monotonic clock, and `context-options` carries
the pair (`wallTime`, `monotonicTime`) that converts them to wall clock. The
failure record from Step 1 has `startTime` and `duration_ms`, so the failing
test's window is known exactly. Filtering to it is what makes the difference
between 70 relevant events and 2000 mixed ones.

Export the window once, then run both scans below:

```bash
export TRACE_DIR="/tmp/trace-analysis/w0"
export TEST_START="2026-10-12T03:29:17.286Z"   # result.startTime
export TEST_DURATION_MS="2486"                  # result.duration
```

## Action timeline, errors, and pageErrors

```bash
python3 -c "
import json, os, datetime

TD = os.environ['TRACE_DIR']
start = datetime.datetime.fromisoformat(os.environ['TEST_START'].replace('Z', '+00:00')).timestamp() * 1000
end = start + float(os.environ['TEST_DURATION_MS']) + 2000
events = [json.loads(l) for l in open(TD + '/trace.trace')]
ctx = next((e for e in events if e.get('type') == 'context-options'), {})
base = ctx.get('wallTime', 0) - ctx.get('monotonicTime', 0)
print('platform: ' + str(ctx.get('platform')) + '  playwright: ' + str(ctx.get('playwrightVersion')))

def in_window(e):
    t = e.get('startTime') or e.get('time') or e.get('endTime')
    # A few seconds of lead-in catches the app error that set up the failure.
    return t is not None and start - 5000 <= base + t <= end

for e in events:
    if not in_window(e): continue
    t = e.get('type')
    if t == 'before':
        label = e.get('title') or (str(e.get('class')) + '.' + str(e.get('method')))
        sel = str(e.get('params', {}).get('selector', ''))[:90]
        print('[' + str(e.get('callId')) + '] ' + label + (' selector=' + sel if sel else ''))
    elif t == 'after' and e.get('error'):
        msg = str(e['error'].get('message', ''))[:200].replace(chr(10), ' ')
        print('[' + str(e.get('callId')) + '] ERROR: ' + msg)
    elif t == 'event' and e.get('method') == 'pageError':
        err = e.get('params', {}).get('error', {}).get('error', {})
        print('PAGE_ERROR: ' + str(err.get('message', ''))[:200].replace(chr(10), ' '))
"
```

Read the timeline backwards from the end: the last few actions before the error
are what the test was doing when it gave up.

**`pageError` events are high-value signals** — app-level JavaScript errors in
the renderer. They never reach stdout, so Layer 2 cannot see them, and they
often explain why the UI was in a broken state before the test ever asserted.

## Console scan

Scan all severity levels, not just `error` — app code frequently logs the
decisive line at `console.log`.

```bash
python3 -c "
import json, os, datetime

KEYWORDS = ['error', 'fail', 'typeerror', 'referenceerror', 'syntaxerror',
    'reject', 'crash', 'abort', 'econnrefused', 'enotfound', 'etimedout',
    'fetch failed', 'tls', 'cert', 'ssl', 'socket', 'refused', 'timeout',
    'unauthorized', 'forbidden', 'unreachable', 'cannot', 'unable']

TD = os.environ['TRACE_DIR']
start = datetime.datetime.fromisoformat(os.environ['TEST_START'].replace('Z', '+00:00')).timestamp() * 1000
end = start + float(os.environ['TEST_DURATION_MS']) + 2000
events = [json.loads(l) for l in open(TD + '/trace.trace')]
ctx = next((e for e in events if e.get('type') == 'context-options'), {})
base = ctx.get('wallTime', 0) - ctx.get('monotonicTime', 0)

for e in events:
    if e.get('type') != 'console': continue
    if not (start - 5000 <= base + e.get('time', 0) <= end): continue
    text = (e.get('text') or ' '.join(str(a.get('preview') or a.get('value') or '') for a in e.get('args', [])))[:300]
    mt = e.get('messageType', '')
    if mt in ('error', 'warning') or any(k in text.lower() for k in KEYWORDS):
        print('CONSOLE [' + mt + ']: ' + text.replace(chr(10), ' '))
"
```

If a scan returns nothing, widen the window before concluding the trace is
clean — a cause that predates the test by more than five seconds (a machine
that died during the previous test) is still a real cause, it just belongs to
the run rather than to this test.

## What to look for

- **`pageError` before test assertions** — app JS error → explains broken UI state
- **`ECONNRESET` / `ECONNREFUSED` in console** — network/pipe failure → `infra`
- **IPC channel errors** — broken main↔renderer communication → `infra` or `regression`
- **Sequence of actions** — where did the test hang? What was the last successful action?
- **Error at a specific `before` step** — maps directly to the failing test action

## Using trace evidence in root_cause

The `root_cause` must cite what the trace actually showed, not what you infer:

- ✅ `"WSL pipe unreachable — trace shows ECONNRESET on ipcRenderer channel during machine restart"`
- ✅ `"pageError 'Cannot read properties of undefined (reading start)' at machine.ts:42 before status check"`
- ❌ `"Machine did not restart within 360s"` (this just restates the assertion, not the cause)

If the trace provides no additional signal (no console errors, no pageErrors, clean action timeline up to the timeout), state that explicitly:

- `"Machine did not transition to RUNNING within 360s — trace shows no errors or pageEvents; underlying cause undetermined"`
