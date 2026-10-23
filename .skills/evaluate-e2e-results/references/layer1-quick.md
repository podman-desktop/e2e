# Layer 1: Quick Classification from error-context.md

This is the first and cheapest analysis layer. It classifies ~70% of failures without touching trace files.

## Finding error-context.md

Step 1 already resolved this: each failure record carries an `error_context`
path pointing into `$RESULTS_DIR`. Read that file.

If the field is `null`, the test produced no error-context attachment — that is
a Layer 2 failure, not a missing file. If the path is non-null but absent from
disk, the attachment did not survive artifact upload; fall back to Layer 2
rather than hunting for it.

The error-context.md contains:
- `# Test info` — test name and source location
- `# Error details` — full Playwright error with locator, expected value, timeout, call log
- `# Test source` — source code around the failure with `>` marker at the failing line

## Error → classification shortcuts

Apply these before reading error-context.md. Match against `result.error.message` from json-results.json.

| Error pattern | Classification | Confidence | Rationale |
|---------------|---------------|------------|-----------|
| `ReferenceError: Cannot access '...' before initialization` | `test_bug` | `confirmed` | Circular dependency in test code |
| `SyntaxError` in test file | `test_bug` | `confirmed` | Test code doesn't parse |
| `TypeError: Cannot read properties of undefined` in test file | `test_bug` | `confirmed` | Test code runtime error |
| `expect(locator).toBeVisible() failed` with timeout ≤ 10s, `attempts: 1` | `flaky` | `likely` | Short timeout — the element may simply have needed longer |
| the same, but failing on every retry (`attempts > 1`) | `unknown` | `uncertain` | An element that never appears in three independent runs is not slow; the timeout length says nothing here |
| `expect(locator).toBeVisible() failed` with timeout > 30s | `regression` | `likely` | Long timeout — element probably never renders |
| `expect(locator).toHaveText()` actual vs expected mismatch | `regression` | `likely` | App produces different text than expected |
| `strict mode violation: ... resolved to N elements` | `test_bug` | `likely` | Locator is too broad |
| `intercepts pointer events` | `flaky` | `likely` | Modal or overlay blocking — timing issue |
| `Test timeout of N ms exceeded` + `Target page closed` | `flaky` | `likely` | Operation exceeded overall test timeout |
| `ECONNREFUSED` / `ENOTFOUND` / `ETIMEDOUT` | `infra` | `likely` | Network issue in CI environment |
| `no such file or directory` for system binary | `infra` | `confirmed` | Missing dependency |
| `unable to copy from source docker://` | `infra` | `likely` | Registry pull failure |
| `overlay/.../merged: no such file` / `copier subprocess` | `infra` | `confirmed` | Container storage corruption |

## When Layer 1 is sufficient

**Stop at Layer 1 when** the error-context.md shows a self-explanatory cause where the error message IS the evidence:
- A test code error (`ReferenceError`, `SyntaxError`, `TypeError` in test file)
- A clear assertion mismatch with expected vs received values
- A locator that doesn't match any element (`strict mode violation`)
- Any shortcut-table pattern at `confirmed` confidence

**Escalate when** error-context.md tells you WHAT failed but not WHY:
- Status/state assertions (`toHaveText("RUNNING")` got `"OFF"`) — the state mismatch is clear, but what caused the wrong state isn't
- Element not found/not visible — but the element should exist (navigation links, connection cards)
- Timeouts on operations involving external systems (machine start, container ops, registry pulls)
- Any `infra` or `regression` classification at `likely` or `uncertain` confidence
- A `flaky` verdict on a test with `attempts > 1`. A flake is something that
  passes on retry; a test that failed identically three times did not flake,
  and "timing-sensitive, not a product problem" is the most expensive wrong
  answer this skill can give — it tells a release reader to look away.

Escalate to **Layer 2 first** (`layer2-logs.md`). Its log scan is one command
for the whole run, and the app usually logged the cause — a fetch that was rate
limited, a provider that was never running — while Layer 1 only saw the UI
symptom. Go to Layer 3 for what the logs leave unexplained.

## Classification categories

| Category | Definition |
|----------|-----------|
| `regression` | App behavior changed — test was previously passing, now fails due to app code change |
| `test_bug` | Test code is wrong — bad locator, wrong assertion, stale page object, import error |
| `flaky` | Timing-sensitive or non-deterministic — would likely pass on retry |
| `infra` | CI environment issue — missing binary, network failure, provisioning error, storage corruption |
| `unknown` | Insufficient evidence — escalate to Layer 2, then Layer 3 |

## Confidence levels

| Level | Definition |
|-------|-----------|
| `confirmed` | Evidence directly demonstrates the root cause |
| `likely` | Evidence strongly suggests the cause but an alternative explanation exists |
| `uncertain` | Multiple plausible explanations — best guess from available evidence |

## Electron-specific patterns

Podman Desktop is an Electron app. These appear in error-context.md and traces:

- **IPC failures**: console errors mentioning `ipcRenderer`, `ipcMain`, or channel names — broken main↔renderer communication
- **Preload script errors**: errors during preload — renderer lacks expected APIs
- **`ipcNative` object missing**: `Attempted to get the 'ipcNative' object but it was missing` — **this is noise**, ignore it. Normal Electron startup.
- **`file://` URLs**: Electron loads local files — `file://` network requests are normal, not failures

## Noise to ignore

These appear in normal test runs and do not indicate failures:

- `Gtk: gtk_widget_add_accelerator: assertion failed` — Electron/Gtk compat on Linux
- `npm warn Unknown env config` — pnpm/npm config mismatch
- `cpu-features install: Error: Unable to detect compiler type` — optional native module
- `Error trying to run the version on docker-compose. Binary might not be there` — expected when compose is not installed
- `Error: Failed to execute command: spawn kind ENOENT` — expected when kind is not installed
- `Attempted to get the 'ipcNative' object but it was missing` — normal Electron startup
- `Removing raw traces folder:` — normal cleanup log
- `Saving a video file took:` — normal video save log

## Skipped test analysis

Traverse the suite hierarchy to categorize every skipped test.

### Three kinds of skips

1. **By-design skips** — `test.annotations[]` has an entry with `type: "skip"`
   or `type: "fixme"`, usually with a `description` explaining why (e.g.,
   `"Certificate sync via podman machine ssh hangs on Windows CI runners"`).
   Intentional exclusions.

2. **Cascade skips** — a test inside a `test.describe.serial` block that never
   ran because an earlier test in that block failed. These are hidden coverage
   loss and belong next to the failure that caused them.

3. **Unresolved skips** — a skip with no annotation explaining it and no failed
   predecessor to blame. Normally zero.

### Detection

Playwright records serial mode as an annotation, so both halves of a cascade
are things you can check rather than infer:

```
For each skipped test:
  if annotations has type "skip" or "fixme":
    → by_design, reason = annotation.description
  elif annotations has type "serial" AND an earlier test in the same suite failed:
    → cascade, caused by that failure
  else:
    → unresolved
```

Keep the third branch. An empty annotation list is not evidence of a cascade —
a run that hit `maxFailures` abandons every test it never reached, and those
have nothing to do with any particular failure. Blaming them on the nearest
failed test invents a causal link an engineer will then go chase. The counts
must still sum to `total_skipped`, so report `unresolved` rather than folding
it into one of the other two.

### What to report

- Group by-design skips by their skip reason
- Link cascade skips back to the failure that caused them
- 52 skipped is fine if all by-design. 8 cascade skips from an infra failure means machine lifecycle tests were never validated — engineers need to know this.
