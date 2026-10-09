# QE On-Duty — Quick Guide

Two pieces work together: a **reporter** (Python, collects data) and a **triage skill** (interactive, routes you to action).

## 1. The Reporter (`qe-on-duty-reporter/`)

Collects, across 28+ Podman Desktop repos, four things: PRs needing QE review, failing CI workflow runs, open CVEs, and open bugs. Writes a JSON **snapshot** + a Markdown **report**.

**Prereqs:** Python 3.8+, `gh` CLI authenticated (`gh auth login`), `pip install -r requirements.txt`. Config lives in `config.yaml` (repo list, QE labels, your `domains_user_name`, workflow/CVE/issue filters).

```bash
cd qe-on-duty-reporter
python main.py                       # today's snapshot + report
python main.py --date 2026-10-08     # specific date
python main.py --weekly              # aggregate the week (prose only)
```

**Output:**

```text
output/snapshots/YYYY-MM-DD/HHMM.json   (+ latest.json symlink)
output/reports/daily/YYYY-MM-DD/HHMM.md
output/reports/weekly/YYYY-week-NN.md
```

## 2. The Triage Skill (`qe-on-duty-triage`)

A **router** — it reads the latest snapshot and hands each item to the right specialist skill. It never investigates itself.

| Item          | Delegates to                                      |
| ------------- | ------------------------------------------------- |
| Failed CI run | `investigate-gh-run`                              |
| Open bug      | `issue-requirements`                             |
| CVE           | `create-github-issue` (one at a time, never parallel) |
| Test-bug fix  | `playwright-testing` (in the target repo)        |

**Invoke** (after a report exists):

```text
/qe-on-duty-triage               # latest daily snapshot
/qe-on-duty-triage 2026-10-08    # that date
/qe-on-duty-triage weekly        # weekly markdown
```

**Flow:** pick a category → pick item(s) by number (`all`/`skip`) → pick an action → it dispatches. Multiple failed runs are deduped by workflow and fanned out to parallel agents (capped ~5, confirmed first), then results come back as one combined table.

## Typical daily use

```bash
cd qe-on-duty-reporter && python main.py        # 1. generate
```

```text
/qe-on-duty-triage                              # 2. triage in Claude Code
```

> Category: *Failed CI runs (6)* → items `1,3` → *Investigate root cause*
> → skill checks for an existing tracking issue, then runs `investigate-gh-run`,
> reports root cause + classification (App / Test / Flaky / Infra) + recommended fix.

**Rules:** report must exist first (no fabricated data); empty categories are skipped; a missing delegate skill is reported, not faked; another repo is never edited/committed without confirmation.
