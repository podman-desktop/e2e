# Layer 3: Trace Analysis for Evidence-Backed Root Cause

Use this layer when Layer 1 classified a failure provisionally but the `root_cause` isn't grounded in evidence — the error shows WHAT failed but not WHY.

**When to use Layer 3:**
- `infra` or `regression` at `likely` or `uncertain` confidence
- `unknown` classification (insufficient evidence from error-context.md)
- Status/state assertion mismatch (e.g., machine stayed OFF — but why?)
- Element missing/not visible — but should have existed
- Operation timeout involving external systems

## Finding the trace file

Look in `$ARGUMENTS/traces/` for a zip file matching the test's suite name. The naming pattern is `{suite-name}_w{workerIndex}_trace.zip`.

```bash
ls "$ARGUMENTS/traces/"
```

Match by suite name substring — e.g., for a failure in "podman-machine-e2e" look for `podman-machine-e2e_w0_trace.zip`.

## Extracting the trace

```bash
mkdir -p /tmp/trace-analysis && cd /tmp/trace-analysis && unzip -o "$ARGUMENTS/traces/{name}_trace.zip"
```

The trace file is `trace.trace` — newline-delimited JSON, one event per line.

## Action timeline + errors

Extracts the sequence of test actions and any errors at each step:

```bash
python3 -c "
import json, sys
with open('/tmp/trace-analysis/trace.trace') as f:
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

**`pageError` events are high-value signals** — app-level JavaScript errors that occur before test actions. They're invisible in error-context.md but often explain why the UI is in a broken state.

## Exhaustive console scan

Scan ALL severity levels for failure keywords — app code frequently logs critical errors at `console.log`, not `console.error`.

```bash
python3 -c "
import json
KEYWORDS = ['error', 'fail', 'typeerror', 'referenceerror', 'syntaxerror',
    'reject', 'crash', 'abort', 'econnrefused', 'enotfound', 'etimedout',
    'fetch failed', 'tls', 'cert', 'ssl', 'socket', 'refused', 'timeout',
    'unauthorized', 'forbidden', 'unreachable', 'cannot', 'unable']
with open('/tmp/trace-analysis/trace.trace') as f:
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
