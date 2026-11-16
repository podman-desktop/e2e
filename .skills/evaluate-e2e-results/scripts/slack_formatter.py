#!/usr/bin/env python3
"""Transform evaluate-e2e-results JSON into Slack Workflow Builder messages.

Reads evaluation JSON from stdin and writes a flat payload for a Slack Workflow
Builder webhook trigger (not Block Kit). Three output modes:

  default          {"<var>": "<text>"}: the whole digest as one message. Over
                   SLACK_MAX_CHARS it falls back to the overview, which still
                   names every failure group.
  --split-chars N  {"parts": ["...", ...]}: the overview, then every failure
                   group in full, packed into messages of at most N characters.
                   Post each part as its own trigger call, in order.
  --max-bytes N    {"<var>": "<overview>"}: the overview alone, fitted to N
                   bytes of JSON-encoded text (a Tekton result).

Usage:
  <agent CLI, headless> ... | python3 slack_formatter.py | curl -X POST -H 'Content-type: application/json' -d @- "$WEBHOOK_URL"
  python3 slack_formatter.py --pipeline-name "pde2e-nightly-libkrun" --artifacts-url "https://..." < eval.json

Environment variables (substitute for CLI args):
  ARTIFACTS_URL       — link to full artifacts
  PIPELINE_NAME       — pipeline identifier (fallback for OS + backend)
  RUN_INFO            — key=value lines describing the run, see RUN_INFO_KEYS
  SLACK_WORKFLOW_VAR  — payload key (default: "text")
  SLACK_MAX_CHARS     — default mode's limit (default: 3500, 0: no limit)
  SLACK_SPLIT_CHARS   — same as --split-chars
  SLACK_MAX_BYTES     — same as --max-bytes

Optional input keys besides the skill's output, added by a post-processing step:
  run_started  — ISO 8601 start time of the test run
  unanalysed   — [{test, spec_file, line}]: failed tests the evaluator did not
                 reach (over its failure budget), listed without a verdict
"""
import argparse
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

# Workflow Builder renders the variable as plain text — mrkdwn (*bold*, `code`,
# <url|label>) is NOT parsed, so this formatter emits plain text only. Unicode
# emoji, capitals, rules and spacing do render, and are what carries structure.

# classification -> (icon, verdict label, what it means for a release reader)
VERDICT = {
    "regression": ("⛔", "PRODUCT BUG", "a real bug in Podman Desktop"),
    "test_bug": ("🐛", "TEST BUG", "the test code is wrong, not the app"),
    "flaky": ("🔄", "FLAKY TEST", "timing-sensitive, not a product problem"),
    "infra": ("🚧", "INFRASTRUCTURE", "CI environment, not a product problem"),
    "unknown": ("❓", "NEEDS INVESTIGATION", "not enough evidence to classify"),
}

# Worst first: a product bug decides the release, an unclassified failure may
# hide one, and infra decides whether the run can be trusted at all.
CLASS_RANK = {"regression": 0, "unknown": 1, "infra": 2, "test_bug": 3, "flaky": 4}
CONFIDENCE_RANK = {"confirmed": 0, "likely": 1, "uncertain": 2}

# confidence -> hedge applied to the verdict label
CONFIDENCE_PREFIX = {"confirmed": "", "likely": "LIKELY ", "uncertain": "POSSIBLY "}

# analysis layer -> what the verdict was actually based on
LAYER_BASIS = {1: "error context", 2: "app logs", 3: "trace analysis"}

HEAVY_RULE = "━" * 30
RULE = "─" * 30

# Slack folds a long message behind "show more" and some workflow steps reject
# an oversized variable outright. Stay comfortably under 4000 characters.
DEFAULT_MAX_CHARS = 3500

BACKEND_TOKENS = {
    "applehv": "Apple HV",
    "libkrun": "libkrun",
    "hyperv": "Hyper-V",
    "wsl": "WSL",
    "qemu": "QEMU",
}

OS_LABELS = {"darwin": "macOS", "macos": "macOS", "windows": "Windows", "linux": "Linux", "rhel": "RHEL"}

# RUN_INFO keys this formatter shows; anything else is ignored.
RUN_INFO_KEYS = {
    "pd_version", "trigger", "os", "os_version", "arch",
    "podman_version", "provider", "rootful", "user_networking",
}
RUN_INFO_MAX_VALUE = 60
TRUE_VALUES = {"1", "true", "yes", "on"}

# Free text from the model is cut at these lengths.
MAX_TITLE = 120
MAX_TEST_LINE = 300


def extract_json(raw: str) -> dict:
    """Decode the evaluation object, tolerating a ```json fence or stray prose.

    raw_decode stops at the end of the first JSON value, so trailing fences and
    commentary after the object are ignored.
    """
    start = raw.find("{")
    if start < 0:
        raise ValueError("No JSON object found in input")
    obj, _ = json.JSONDecoder().raw_decode(raw[start:])
    return obj


def encoded_len(text: str) -> int:
    """Size of text as a JSON string value encoded by Go's json.Marshal.

    Tekton stores results that way, and the agent-runner entrypoint bounds the
    summary with the same rule (agent-runner/entrypoint.sh): <, > and & become
    6-byte \\u escapes, as do other control characters, U+2028, U+2029 and
    U+FFFD; quote, backslash, tab, newline and CR take 2; the rest is UTF-8.
    Keep the two in step.
    """
    size = 0
    for ch in text:
        c = ord(ch)
        if c in (60, 62, 38, 0x2028, 0x2029, 0xFFFD) or (c < 32 and c not in (9, 10, 13)):
            size += 6
        elif c in (34, 92, 9, 10, 13):
            size += 2
        elif c < 0x80:
            size += 1
        elif c < 0x800:
            size += 2
        elif c < 0x10000:
            size += 3
        else:
            size += 4
    return size


def _clean(value, max_len: int) -> str:
    """One line of untrusted text: no control characters, bounded length."""
    text = re.sub(r"[\x00-\x1f\x7f  ]+", " ", str(value or "")).strip()
    return text if len(text) <= max_len else text[: max_len - 1].rstrip() + "…"


def _run_info(raw: str | None) -> dict[str, str]:
    """Parse RUN_INFO: key=value lines, known keys only, empty values dropped."""
    info: dict[str, str] = {}
    for line in (raw or "").splitlines():
        key, sep, value = line.partition("=")
        key = key.strip().lower()
        value = _clean(value, RUN_INFO_MAX_VALUE)
        if sep and key in RUN_INFO_KEYS and value:
            info[key] = value
    return info


def _parse_pipeline(pipeline_name: str | None) -> tuple[str, str | None]:
    """Return (os_label, backend_label | None) from a pipeline name like
    'pde2e-prerelease-v1.30.1-libkrun-6.1.2-darwin-arm64-26.0.1'."""
    if not pipeline_name:
        return "E2E", None

    name_lower = pipeline_name.lower()
    if "darwin" in name_lower or "macos" in name_lower:
        os_label = "macOS"
    elif "win" in name_lower or "windows" in name_lower:
        os_label = "Windows"
    elif "linux" in name_lower:
        os_label = "Linux"
    else:
        os_label = "E2E"

    backend = None
    for token, label in BACKEND_TOKENS.items():
        if token in name_lower:
            backend = label
            break

    return os_label, backend


def _dedupe_failures(failures: list) -> list:
    """Collapse repeated entries for the same test into one, keeping the count.

    Playwright records one result per retry attempt. The skill is told to emit a
    single entry per test, but if it reports each attempt instead, the same test
    would be listed two or three times in the digest. Fold them here and keep
    the highest attempt count seen, so the reader learns the test failed on
    every retry — which is evidence against a flake.
    """
    occurrences = Counter()
    first: dict[tuple, dict] = {}
    ordered: list[dict] = []

    for f in failures:
        # Keyed on the test's identity — title, describe path, file — and
        # deliberately not on line: a retry can report a different failing line
        # (a later assertion got further), and keying on it would let the same
        # test through twice. The describe path is in the key because `test`
        # holds the bare title, which two suites in one file can share.
        key = (f.get("test"), f.get("suite"), f.get("spec_file"))
        occurrences[key] += 1
        if key not in first:
            entry = dict(f)
            first[key] = entry
            ordered.append(entry)

    for key, entry in first.items():
        try:
            declared = int(entry.get("attempts") or 1)
        except (TypeError, ValueError):
            declared = 1
        entry["attempts"] = max(declared, occurrences[key])

    return ordered


def _severity(f: dict) -> tuple[int, int]:
    return (
        CLASS_RANK.get(f.get("classification"), CLASS_RANK["unknown"]),
        CONFIDENCE_RANK.get(f.get("confidence"), CONFIDENCE_RANK["uncertain"]),
    )


def _group_failures(failures: list) -> list[tuple[str | None, dict, list]]:
    """Group failures by title and order the groups worst first.

    The evaluator reports failures in test-run order, so nothing upstream puts
    the worst first: sort by the worst classification in the group, then its
    best confidence, then group size, then first appearance. An untitled
    failure is its own group. Returns (title | None, representative, members).
    """
    groups: dict[object, list] = {}
    for idx, f in enumerate(failures):
        key = f.get("title") or ("untitled", idx)
        groups.setdefault(key, []).append(f)

    ranked = []
    for first_seen, (key, members) in enumerate(groups.items()):
        rep = min(members, key=_severity)
        title = key if isinstance(key, str) else None
        ranked.append(((_severity(rep), -len(members), first_seen), title, rep, members))
    ranked.sort(key=lambda g: g[0])
    return [(title, rep, members) for _, title, rep, members in ranked]


def _truncate(text: str, max_len: int) -> str:
    """Trim to max_len, preferring a sentence end and never cutting mid-word."""
    if len(text) <= max_len:
        return text
    window = text[:max_len - 1]
    # Prefer ending on a sentence boundary if one sits in the last third.
    sentence_end = max(window.rfind(". "), window.rfind("; "))
    if sentence_end > max_len * 0.6:
        return window[:sentence_end].rstrip(",;:—- ") + "."
    space = window.rfind(" ")
    return (window[:space] if space > 0 else window).rstrip(",;:—- ") + "…"


def _triage(failures: list) -> tuple[str, list[str]]:
    """Return (headline verdict, per-bucket breakdown lines, worst first)."""
    counts = Counter(f.get("classification", "unknown") for f in failures)
    product = counts["regression"]
    # "likely" is a hedge, and hedging a confirmed regression reads as a guess.
    # Only apply it when nothing in the product-bug bucket is confirmed.
    product_confirmed = any(
        f.get("classification") == "regression" and f.get("confidence") == "confirmed"
        for f in failures
    )

    if product:
        hedge = "" if product_confirmed else "likely "
        headline = (
            f"{product} {hedge}product bug{'s' if product != 1 else ''}"
            " — review before release"
        )
    elif counts["unknown"]:
        headline = f"{counts['unknown']} failure(s) could not be classified — needs a look"
    elif failures:
        # Name every kind present: "test-code failures only" over a run that
        # is mostly infrastructure sends the reader to the wrong team.
        kinds = [name for key, name in (("infra", "infrastructure"), ("test_bug", "test code"),
                                         ("flaky", "flaky tests")) if counts[key]]
        headline = f"{' and '.join(kinds) or 'non-product'} failures only — no product impact identified"
    else:
        headline = "no failures"

    breakdown = []
    for key in sorted(counts, key=lambda k: CLASS_RANK.get(k, CLASS_RANK["unknown"])):
        icon, label, meaning = VERDICT.get(key, VERDICT["unknown"])
        breakdown.append(f"{icon} {counts[key]} {label.lower()} — {meaning}")
    return headline, breakdown


def _format_duration(duration_s: float) -> str:
    mins = int(duration_s // 60)
    secs = int(duration_s % 60)
    return f"{mins}m{secs}s" if mins else f"{secs}s"


def _format_started(value) -> str | None:
    """ISO 8601 start time -> 'YYYY-MM-DD HH:MM UTC', or None if unparseable."""
    if not value:
        return None
    try:
        started = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    return started.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def _plural(n: int, word: str) -> str:
    return f"{n} {word}{'s' if n != 1 else ''}"


class Digest:
    """One evaluation, rendered as an overview plus one block per failure group."""

    def __init__(self, data: dict, artifacts_url: str | None = None,
                 pipeline_name: str | None = None, run_info: dict[str, str] | None = None):
        self.data = data
        self.artifacts_url = artifacts_url
        self.pipeline_name = _clean(pipeline_name, 200) if pipeline_name else None
        self.info = run_info or {}
        self.summary = data.get("summary") or {}
        self.platform = data.get("platform") or {}
        self.failures = _dedupe_failures(data.get("failures") or [])
        self.groups = _group_failures(self.failures)
        self.unanalysed = self._unanalysed(data.get("unanalysed") or [])

        # A header that says "all tests passed" above a list of failures
        # destroys trust in the whole digest, so let the failures themselves win
        # when the summary disagrees with them.
        self.failed = self.summary.get("failed", 0) or len(self.failures) + len(self.unanalysed)

        name_os, name_backend = _parse_pipeline(pipeline_name)
        os_value = self.info.get("os") or self.platform.get("os") or ""
        self.os_label = OS_LABELS.get(os_value.lower(), os_value) or (
            None if name_os == "E2E" else name_os)
        provider = self.info.get("provider", "")
        self.backend = BACKEND_TOKENS.get(provider.lower(), provider) or name_backend

    def _unanalysed(self, entries: list) -> list[dict]:
        """Failed tests the evaluator never reached, minus any it did report."""
        seen = {(f.get("test"), os.path.basename(f.get("spec_file") or "")) for f in self.failures}
        out = []
        for e in entries:
            if not isinstance(e, dict):
                continue
            key = (e.get("test"), os.path.basename(e.get("spec_file") or ""))
            if key not in seen:
                seen.add(key)
                out.append(e)
        return out

    def _not_reported(self) -> int:
        """Failures the evaluator skipped that nobody listed by name."""
        if self.unanalysed or not self.data.get("truncated"):
            return 0
        return self.data.get("truncated_count", 0) or 0

    # --- Header -----------------------------------------------------------

    def _has_run_info(self) -> bool:
        return bool(self.info.get("pd_version") or self.info.get("trigger"))

    def _subject(self) -> str:
        """'Podman Desktop v1.30.7' when the run says so, else the suite label."""
        if self._has_run_info():
            return " ".join(filter(None, ["Podman Desktop", self.info.get("pd_version")]))
        label = f"{self.os_label} E2E Tests" if self.os_label else "E2E Tests"
        return f"{label} ({self.backend})" if self.backend else label

    def _outcome(self) -> tuple[str, str]:
        s = self.summary
        passed, flaky, skipped, total = (s.get(k, 0) or 0 for k in ("passed", "flaky", "skipped", "total"))
        if self.failed:
            classes = Counter(f.get("classification", "unknown") for f in self.failures)
            unexplained = self.unanalysed or self._not_reported() or not self.failures
            if classes["regression"] or classes["unknown"] or unexplained:
                return "🚨", f"{self.failed} FAILED"
            return "⚠️", f"{self.failed} FAILED, NO PRODUCT IMPACT FOUND"
        # "all 319 tests passed" above a stats line reading "63 skipped" is a
        # false claim, and these suites skip 60+ tests on a normal night.
        if passed + flaky and skipped:
            return "✅", f"NO FAILURES — {passed + flaky} PASSED, {skipped} SKIPPED"
        if passed + flaky:
            return "✅", f"ALL {total or passed + flaky} PASSED"
        # Nothing failed and nothing ran: a setup collapse, not a success.
        return "⛔", "NO TESTS RAN"

    def title(self, label: str = "") -> str:
        icon, outcome = self._outcome()
        # Capitals carry the emphasis; names and versions keep their spelling.
        trigger = None
        subject = " ".join(filter(None, [self.os_label, "E2E TESTS"]))
        if self.backend:
            subject += f" ({self.backend})"
        if self._has_run_info():
            trigger = f"{self.info['trigger'].upper()} E2E" if self.info.get("trigger") else "E2E"
            subject = " ".join(filter(None, ["PODMAN DESKTOP", self.info.get("pd_version")]))
        parts = [subject, trigger, outcome]
        return f"{icon} " + " — ".join(p for p in parts if p) + label

    def compact_header(self, label: str) -> str:
        """One line naming the run, for the messages after the overview."""
        if self._has_run_info():
            bits = [self._subject(), self._platform_text(), self.backend]
        else:
            bits = [self._subject()]  # the suite label already names OS and backend
        return "🧾 " + " · ".join(b for b in bits if b) + f" — failures{label}"

    def _platform_text(self) -> str | None:
        bits = [self.os_label, self.info.get("os_version"),
                self.info.get("arch") or _clean(self.platform.get("arch"), 20)]
        return " ".join(b for b in bits if b) or None

    def facts(self) -> list[str]:
        lines = []
        platform = self._platform_text()
        if platform:
            lines.append(f"🖥 Platform: {platform}")

        podman = [self.info.get("podman_version"), self.backend]
        if "rootful" in self.info:
            podman.append("rootful" if self.info["rootful"].lower() in TRUE_VALUES else "rootless")
        if self.info.get("user_networking", "").lower() in TRUE_VALUES:
            podman.append("user-mode networking")
        podman = [p for p in podman if p]
        if podman:
            lines.append("🦭 Podman: " + " · ".join(podman))

        started = _format_started(self.data.get("run_started"))
        duration = self.summary.get("duration_s", 0)
        if started:
            lines.append(f"🕒 Started: {started}" + (f" · ran {_format_duration(duration)}" if duration else ""))
        elif duration:
            lines.append(f"🕒 Duration: {_format_duration(duration)}")

        lines.append("📊 Results: " + self._stats())

        source = []
        if self.platform.get("branch"):
            source.append(f"branch {_clean(self.platform['branch'], 80)}")
        if self.platform.get("commit"):
            source.append(f"commit {_clean(self.platform['commit'], 40)[:8]}")
        if source:
            lines.append("🔀 Source: " + " · ".join(source))
        if self.pipeline_name:
            lines.append(f"🏷 Run: {self.pipeline_name}")
        return lines

    def _stats(self) -> str:
        s = self.summary
        passed, flaky, skipped, total = (s.get(k, 0) or 0 for k in ("passed", "flaky", "skipped", "total"))
        skipped_analysis = self.data.get("skipped_analysis") or {}
        cascade = skipped_analysis.get("cascade", 0)
        by_design = skipped_analysis.get("by_design", 0)

        skip_detail = ""
        if skipped:
            if cascade and by_design:
                skip_detail = f" ({by_design} by design, {cascade} cascaded)"
            elif cascade:
                skip_detail = f" ({cascade} cascaded)"
            else:
                skip_detail = " (all by design)"

        parts = [f"✅ {passed} passed", f"❌ {self.failed} failed"]
        if flaky:
            parts.append(f"🔄 {flaky} flaky")
        parts.append(f"⚠️ {skipped} skipped{skip_detail}")
        ran = (total or passed + flaky + self.failed + skipped) - skipped
        if ran > 0:
            parts.append(f"{100 * (passed + flaky) / ran:.1f}% pass rate")
        return "   ".join(parts)

    def verdict(self) -> list[str]:
        if not self.failures:
            return []
        headline, breakdown = _triage(self.failures)
        lines = ["", f"🧭 VERDICT: {headline}"]
        lines.extend(f"   {b}" for b in breakdown)
        cascade = (self.data.get("skipped_analysis") or {}).get("cascade", 0)
        if cascade:
            lines.append(
                f"   ⚠️ {_plural(cascade, 'further test')} never ran"
                " after an earlier failure — that coverage is unverified"
            )
        return lines

    def group_list(self, limit: int | None = None) -> list[str]:
        """The 'Failure groups' list; with limit, only the first `limit` groups."""
        if not self.groups and not self.unanalysed and not self._not_reported():
            return []
        lines = ["", "📋 Failure groups (worst first):"]
        shown = self.groups if limit is None else self.groups[:limit]
        for idx, (title, rep, members) in enumerate(shown):
            icon = VERDICT.get(rep.get("classification"), VERDICT["unknown"])[0]
            name = _clean(title or rep.get("test") or "Unlabelled failure", MAX_TITLE)
            lines.append(f"   {idx + 1}. {icon} {name} — {_plural(len(members), 'test')}")
        hidden = self.groups[len(shown):]
        if hidden:
            tests = sum(len(m) for _, _, m in hidden)
            lines.append(f"   … and {_plural(len(hidden), 'more group')} ({_plural(tests, 'test')})")
        if self.unanalysed:
            lines.append(f"   ❔ {_plural(len(self.unanalysed), 'failed test')}"
                         " not analysed — over the evaluator's budget")
        elif self._not_reported():
            lines.append(f"   ❔ {_plural(self._not_reported(), 'further failure')}"
                         " not analysed — see the full artifacts")
        return lines

    def links(self) -> list[str]:
        foot = []
        if self.artifacts_url:
            foot.append(f"🔗 Logs & artifacts: {self.artifacts_url}")
        ci_url = self.platform.get("ci_url")
        if ci_url and ci_url != self.artifacts_url:
            foot.append(f"🔗 CI run: {ci_url}")
        return [""] + foot if foot else []

    def overview(self, label: str = "", group_limit: int | None = None) -> str:
        lines = [HEAVY_RULE, self.title(label), HEAVY_RULE]
        lines += self.facts()
        lines += self.verdict()
        lines += self.group_list(group_limit)
        lines += self.links()
        return "\n".join(lines).strip()

    def fit_overview(self, fits, label: str = "") -> str:
        """The overview with as many group-list entries as `fits` allows.

        The header, verdict and links are never cut; only the tail of the group
        list gives way, replaced by a count of what it left out.
        """
        for limit in range(len(self.groups), -1, -1):
            text = self.overview(label, group_limit=limit)
            if fits(text):
                return text
        raise SystemExit("ERROR: the digest overview alone is over the size limit")

    # --- Failure groups ---------------------------------------------------

    def blocks(self) -> list[tuple[list[str], list[str], list[str]]]:
        """Per group: (heading lines, continued-heading lines, test lines)."""
        out = []
        for idx, (title, rep, members) in enumerate(self.groups):
            classification = rep.get("classification", "unknown")
            icon, label, _meaning = VERDICT.get(classification, VERDICT["unknown"])
            hedge = CONFIDENCE_PREFIX.get(rep.get("confidence"), "POSSIBLY ")
            name = _clean(title, MAX_TITLE) if title else "Unlabelled failure"
            heading = f"{idx + 1}. {icon} {hedge}{label} — {name}"
            count = f" ({_plural(len(members), 'test')})" if len(members) > 1 else ""

            # The reason is stated once for the group, then every test it hit.
            head = [RULE, heading + count]
            root_cause = _clean(rep.get("root_cause") or "No root cause determined", 2000)
            head.append("Why: " + _truncate(root_cause, 320))
            action = _truncate(_clean(rep.get("recommended_action"), 2000), 200)
            if action:
                head.append(f"Next: {action}")
            layer = rep.get("layer")
            if layer:
                head.append(f"Basis: {LAYER_BASIS.get(layer, 'error context')} (layer {layer})")
            out.append((head, [RULE, heading + " (continued)"], [self._test_line(f) for f in members]))

        if self.unanalysed:
            heading = (f"❔ NOT ANALYSED ({len(self.unanalysed)}) — over the evaluator's budget,"
                       " no verdict; see the artifacts")
            out.append(([RULE, heading], [RULE, heading + " (continued)"],
                        [self._test_line(e) for e in self.unanalysed]))
        return out

    @staticmethod
    def _test_line(f: dict) -> str:
        # Test name and location go on one line: Slack renders this in a
        # proportional font, so a wrapped line restarts at column 0 and any
        # column alignment is lost anyway — fewer, shorter lines read better.
        spec = os.path.basename(f.get("spec_file") or "")
        line_no = f.get("line") or ""
        loc = f"{spec}:{line_no}" if spec and line_no else spec
        parts = [str(f.get("test") or "Unknown test")]
        if loc:
            parts.append(loc)
        attempts = f.get("attempts", 1)
        if isinstance(attempts, int) and attempts > 1:
            parts.append(f"failed {attempts}/{attempts} attempts")
        return _clean("• " + "  ·  ".join(parts), MAX_TEST_LINE)


def _pack(blocks, budget: int) -> list[list[str]]:
    """Pack group blocks into messages of at most `budget` characters.

    A group goes whole into the next message when it does not fit the current
    one. A group bigger than a whole message is split between its test lines
    and goes on under a '(continued)' heading. Nothing is dropped.
    """
    def size(lines: list[str]) -> int:
        return len("\n".join(lines))

    parts: list[list[str]] = []
    current: list[str] = []
    for head, cont_head, tests in blocks:
        if current and size(current + [""] + head + tests) <= budget:
            current += [""] + head + tests
            continue
        if current:
            parts.append(current)
        current, heading_len = list(head), len(head)
        for test in tests:
            if size(current + [test]) > budget and len(current) > heading_len:
                parts.append(current)
                current, heading_len = list(cont_head), len(cont_head)
            current.append(test)
    if current:
        parts.append(current)
    return parts


def render_parts(digest: Digest, split_chars: int) -> list[str]:
    """The overview, then every failure group, as messages of <= split_chars."""
    longest_label = " (99/99)"
    room = len(digest.compact_header(longest_label)) + 1
    groups = _pack(digest.blocks(), split_chars - room)
    total = 1 + len(groups)

    def label(i: int) -> str:
        return f" ({i}/{total})" if total > 1 else ""

    parts = [digest.fit_overview(lambda t: len(t) <= split_chars, label(1))]
    for i, lines in enumerate(groups, start=2):
        parts.append("\n".join([digest.compact_header(label(i))] + lines).strip())
    return parts


def format_workflow_text(data: dict, artifacts_url: str | None = None,
                         pipeline_name: str | None = None, run_info: str | None = None,
                         max_chars: int = DEFAULT_MAX_CHARS) -> str:
    """The whole digest as one message; the overview alone if that is too long."""
    digest = Digest(data, artifacts_url, pipeline_name, _run_info(run_info))
    body: list[str] = []
    for head, _cont, tests in digest.blocks():
        body += [""] + head + tests
    text = "\n".join([digest.overview()] + body).strip()
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    return digest.fit_overview(lambda t: len(t) <= max_chars)


def main():
    parser = argparse.ArgumentParser(description="Transform evaluation JSON to Slack Workflow Builder payloads")
    parser.add_argument("--artifacts-url", default=None, help="URL to full test artifacts")
    parser.add_argument("--pipeline-name", default=None, help="Pipeline name (fallback for OS + backend)")
    parser.add_argument("--run-info", default=None, help="key=value lines describing the run")
    parser.add_argument("--workflow-var", default=None, help="Payload key name (default: 'text')")
    parser.add_argument("--max-chars", type=int, default=None,
                        help="Default mode: one message of at most N characters (0: no limit)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--split-chars", type=int, default=None,
                      help='Write {"parts": [...]}: every failure, in messages of at most N characters')
    mode.add_argument("--max-bytes", type=int, default=None,
                      help="Write the overview alone, at most N bytes JSON-encoded")
    args = parser.parse_args()

    def env_int(name: str) -> int | None:
        value = os.environ.get(name)
        return int(value) if value else None

    artifacts_url = args.artifacts_url or os.environ.get("ARTIFACTS_URL")
    pipeline_name = args.pipeline_name or os.environ.get("PIPELINE_NAME")
    run_info = args.run_info if args.run_info is not None else os.environ.get("RUN_INFO")
    workflow_var = args.workflow_var or os.environ.get("SLACK_WORKFLOW_VAR") or "text"
    split_chars, max_bytes = args.split_chars, args.max_bytes
    if split_chars is None and max_bytes is None:
        split_chars, max_bytes = env_int("SLACK_SPLIT_CHARS"), env_int("SLACK_MAX_BYTES")
        if split_chars and max_bytes:
            parser.error("set only one of SLACK_SPLIT_CHARS and SLACK_MAX_BYTES")

    data = extract_json(sys.stdin.read())
    digest = Digest(data, artifacts_url, pipeline_name, _run_info(run_info))

    if split_chars:
        payload = {"parts": render_parts(digest, split_chars)}
    elif max_bytes:
        payload = {workflow_var: digest.fit_overview(lambda t: encoded_len(t) <= max_bytes)}
    else:
        max_chars = args.max_chars if args.max_chars is not None else env_int("SLACK_MAX_CHARS")
        if max_chars is None:
            max_chars = DEFAULT_MAX_CHARS
        payload = {workflow_var: format_workflow_text(data, artifacts_url, pipeline_name, run_info, max_chars)}
    print(json.dumps(payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
