# Layer 2: App Logs and the Full Error Record

Layer 1 reads the Playwright assertion. Layer 2 reads what the **application**
was saying while that assertion failed, plus the parts of the failure record
Step 1 truncated away. It needs no unzipping and costs one command for the
whole run, so try it before paying for a trace.

Two kinds of failures land here:

1. **Layer 1 saw WHAT failed but not WHY** — the app logs usually say why. A
   heading that never rendered is explained by the fetch that errored out
   moments earlier.
2. **There is no error-context.md at all** — load-time errors and worker
   crashes, where `json-results.json` is the only evidence that exists.

## Part 1: Scan the app logs

Each failed result carries `stdout[]` and `stderr[]` — the Electron main and
renderer output captured during that test. On a Podman Desktop run these lines
carry the extension logs, which is where provider, registry, and network
problems surface first.

```bash
python3 -c "
import json, re, os
ANSI = re.compile(r'\x1b\[[0-9;]*m')
KEYWORDS = ['error', 'fail', 'cannot', 'unable', 'refused', 'timeout', 'denied',
    'econn', 'enoent', 'etimedout', 'crash', 'rate limit', 'unauthorized',
    'socket hang up', 'exit code', 'unreachable']
RD = os.environ['RESULTS_DIR']
data = json.load(open(RD + '/json-results.json'))
seen = set()

def walk(suites):
    for suite in suites:
        for spec in suite.get('specs', []):
            if spec.get('ok', True): continue
            for test in spec.get('tests', []):
                for r in test.get('results', []):
                    if r.get('status') != 'failed': continue
                    print('=== ' + str(spec.get('title')))
                    for chunk in r.get('stdout', []) + r.get('stderr', []):
                        text = ANSI.sub('', chunk.get('text', '')).strip()
                        low = text.lower()
                        if not any(k in low for k in KEYWORDS): continue
                        # The same provider warning repeats dozens of times per
                        # test; one copy is enough to reason from.
                        key = (spec.get('title'), text[:80])
                        if key in seen: continue
                        seen.add(key)
                        print('   ' + text[:250].replace(chr(10), ' '))
        walk(suite.get('suites', []))

walk(data.get('suites', []))
"
```

Read the output against the noise list in `layer1-quick.md` — missing optional
binaries (`docker-compose`, `kind`, `kubectl`) are expected on these runners and
explain nothing. What *is* signal:

| Log line | Reading |
|---|---|
| `API rate limit exceeded for <ip>` | GitHub API throttling the runner. Extension version checks fail, so setup screens never populate → `infra` |
| `socket hang up` / `ECONNRESET` / `Error when handling events` | The event stream to the podman socket dropped → `infra` |
| `no running provider for the matching container` | The machine is not up — pair it with whatever the test asserted |
| `Error: Failed to execute command: spawn <app binary> ENOENT` | The app under test is missing, not an optional CLI → `infra` |
| An unhandled exception from `packages/main` or an extension | App-side defect → `regression` |

A log line is only evidence if it precedes the failure and plausibly causes it.
The same scan over a *passing* test would show the same missing-binary warnings,
which is exactly why they are noise.

## Part 2: Failures with no error-context.md

These never produced an attachment because the test never properly ran:

- **Load-time error** — `workerIndex: -1`, `duration: 0`. The spec file failed
  to import: syntax error, circular dependency, missing module, throwing
  top-level statement.
- **Worker crash** — the process died mid-test, often
  `Worker process exited unexpectedly` or a signal name.
- **Setup/teardown failure** — `globalSetup` or a `beforeAll` hook threw; the
  failure is attributed to a test but caused outside it.

Pull the untruncated error and stack:

```bash
python3 -c "
import json, re, os
ANSI = re.compile(r'\x1b\[[0-9;]*m')
RD = os.environ['RESULTS_DIR']
data = json.load(open(RD + '/json-results.json'))

def walk(suites):
    for suite in suites:
        for spec in suite.get('specs', []):
            if spec.get('ok', True): continue
            for test in spec.get('tests', []):
                for r in test.get('results', []):
                    if r.get('status') != 'failed': continue
                    err = r.get('error', {})
                    print('=== ' + str(spec.get('title')))
                    print(ANSI.sub('', err.get('message', ''))[:1200])
                    print(ANSI.sub('', err.get('stack', ''))[:1200])
        walk(suite.get('suites', []))

walk(data.get('suites', []))
print('TOP-LEVEL ERRORS: ' + json.dumps(data.get('errors', []))[:2000])
"
```

Two sources beyond the failure record:

- **`data['errors']`** — the report's top-level array. Config and global-setup
  failures land here and nowhere else. It is empty on a healthy run, so anything
  in it is signal.
- **`$RESULTS_DIR/output.log`** — raw runner output when the bundle includes it.
  Install failures and provisioning errors appear here before Playwright starts.

### Classifying load-time and crash errors

| What the error shows | Classification | Confidence | Why |
|---|---|---|---|
| `SyntaxError` / `Cannot access '...' before initialization` in a spec or page object | `test_bug` | `confirmed` | Test code does not parse, or circular import |
| `Cannot find module './pages/...'` — a path inside the test tree | `test_bug` | `confirmed` | A file was renamed without updating imports |
| `Cannot find module '<npm package>'` | `infra` | `likely` | Dependency install did not complete on the runner |
| `Worker process exited unexpectedly` with a signal | `infra` | `likely` | Runner out of memory, or the Electron process crashed |
| `globalSetup` threw — missing binary, failed login, unreachable registry | `infra` | `confirmed` | Environment was never provisioned |

A load-time error fails every test in its file at once. When several failures
share one import error they share one root cause — give them the same `title`
in Step 4 so the digest shows one problem, not twelve.

### No trace exists for these

Tracing starts when a test starts, so for `workerIndex: -1` there is nothing on
disk and Layer 3 only burns budget. A worker that crashed mid-test may have left
a partial trace for its `workerIndex` — that one is worth a look.

## Writing the result

Report `layer: 2` when a log line or the stack is what grounded your
`root_cause`, and cite it verbatim in `evidence`:

- ✅ `root_cause`: `The Compose setup screen never rendered. The extension's
  version lookup hit the GitHub API rate limit, so the onboarding step had no
  release data to show.`
  `evidence`: `["stdout: [compose] Failed to retrieve latest Compose version: API rate limit exceeded for 20.210.128.41"]`
- ✅ `root_cause`: `The spec file failed to import. 'ResourcesPage' is imported
  from ./model/pages/resources-page, which no longer exists after the rename.`
  `evidence`: `["json-results.json: Cannot find module './model/pages/resources-page' at specs/resources.spec.ts:4"]`
- ❌ `root_cause`: `The test did not run.` — that restates `duration: 0` and
  tells the engineer nothing about whether to ship.

If the log scan turns up nothing causal, say so and escalate to Layer 3 rather
than promoting a noise line into a root cause.
