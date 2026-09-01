# QE On-Duty Automation

Automated data collection and reporting for Podman Desktop QE on-duty rotation responsibilities.

## Overview

This script automates the monitoring of:
- Pull requests requiring QE review (labels: `qe/testing-required`, `qe/review`)
- CI/CD workflow test results across 28+ repositories
- CVE/Dependabot security alerts
- Open bug reports

It generates daily snapshots (JSON) and human-readable reports (Markdown) to track QE activities throughout the week.

## Prerequisites

### Required Software

1. **Python 3.8+**
   ```bash
   python3 --version
   ```

2. **GitHub CLI (`gh`)**
   ```bash
   # Install gh CLI
   # https://cli.github.com/
   
   # Verify installation
   gh --version
   ```

3. **GitHub Authentication**
   ```bash
   # Authenticate with GitHub
   gh auth login
   
   # Verify authentication
   gh auth status
   ```

### Required Permissions

Your GitHub account needs:
- Read access to all monitored repositories
- `security_events` scope for Dependabot alerts (some repos may not grant this)

## Installation

1. **Clone or navigate to the repository**
   ```bash
   cd qe-on-duty-reporter
   ```

2. **Install Python dependencies**
   ```bash
   pip install -r requirements.txt
   ```

3. **Verify configuration**
   Edit `config.yaml` if needed to customize:
   - Repository lists
   - Filter labels
   - Output directory
   - Time ranges

## Usage

### Daily Report (Default)

Run once or multiple times per day to capture current state:

```bash
# Run with current date/time
python main.py

# Run with specific date
python main.py --date 2026-04-21

# Run with specific date and time
python main.py --date 2026-04-21 --time 1430
```

**Output**:
- JSON snapshot: `output/snapshots/YYYY-MM-DD/HHMM.json`
- Markdown report: `output/reports/daily/YYYY-MM-DD/HHMM.md`
- Symlink: `output/snapshots/YYYY-MM-DD/latest.json` → points to most recent

### Weekly Report

Aggregate daily snapshots into a weekly summary:

```bash
# Generate weekly report for current week
python main.py --weekly

# Generate weekly report for specific week ending on date
python main.py --weekly --date 2026-04-25
```

**Output**:
- Markdown report: `output/reports/weekly/YYYY-week-NN.md`

### Custom Configuration

```bash
# Use custom config file
python main.py --config /path/to/config.yaml

# Use custom output directory
python main.py --output-dir /tmp/qe-reports
```

## Output Structure

```text
output/
├── snapshots/
│   └── 2026-04-21/
│       ├── 0930.json          # 9:30 AM run
│       ├── 1430.json          # 2:30 PM run
│       └── latest.json        # Symlink to 1430.json
└── reports/
    ├── daily/
    │   └── 2026-04-21/
    │       ├── 0930.md
    │       └── 1430.md
    └── weekly/
        └── 2026-week-16.md
```

## Configuration

Edit `config.yaml` to customize behavior:

```yaml
github:
  cli_path: "gh"              # Path to gh CLI
  max_retries: 3              # Retry failed commands

repositories:
  core:
    - "podman-desktop/podman-desktop"
    - "podman-desktop/e2e"
  domains_json: "/path/to/domains.json"  # Extension repos

pr_filters:
  labels:
    - "qe/testing-required"
    - "qe/review"
  assignee_teams:
    - "qe-reviewers"

workflow_filters:
  max_age_days: 7             # Only workflows from last 7 days

cve_filters:
  states: ["open"]
  severities: ["critical", "high", "medium", "low"]

issue_filters:
  labels: ["kind/bug"]
  states: ["open"]
  max_age_days: 30
```

## Troubleshooting

### Authentication Issues

```bash
# Check gh auth status
gh auth status

# Re-authenticate if needed
gh auth login

# Use token if needed
export GITHUB_TOKEN="ghp_your_token_here"
gh auth status
```

### Rate Limiting

The `gh` CLI handles rate limiting automatically. If you hit limits:
- Wait for the reset time (shown in error message)
- Script will pause and retry automatically

### Permission Errors

Some repositories may not grant access to Dependabot alerts (403/404 errors). This is expected and the script will continue with other repositories.

### Missing Data

If no data appears for certain repositories:
- Verify repository names in `config.yaml`
- Check that repositories exist and you have access
- Verify labels/filters match your repository structure

## Development

### Project Structure

```text
qe-on-duty-reporter/
├── qe_on_duty/
│   ├── gh_client.py           # GitHub CLI wrapper
│   ├── config.py              # Configuration management
│   ├── collectors/            # Data collectors
│   │   ├── pr_collector.py
│   │   ├── workflow_collector.py
│   │   ├── cve_collector.py
│   │   └── issue_collector.py
│   ├── models/
│   │   └── snapshot.py        # Data models
│   ├── reporters/
│   │   ├── daily_reporter.py
│   │   └── weekly_reporter.py
│   └── utils/
│       └── repository_parser.py
├── main.py                    # CLI entry point
├── config.yaml
└── requirements.txt
```

### Running Tests

```bash
# Run unit tests (when implemented)
pytest tests/

# Run with coverage
pytest --cov=qe_on_duty tests/
```

### Adding New Collectors

1. Create new collector in `qe_on_duty/collectors/`
2. Inherit from base pattern (see existing collectors)
3. Add data model in `qe_on_duty/models/snapshot.py`
4. Update `main.py` to include new collector
5. Update reporters to display new data

## Automation

### Cron Job

```bash
# Edit crontab
crontab -e

# Run daily at 9 AM
0 9 * * * cd /path/to/qe-on-duty && /usr/bin/python3 main.py

# Run weekly report on Fridays at 5 PM
0 17 * * 5 cd /path/to/qe-on-duty && /usr/bin/python3 main.py --weekly
```

### GitHub Actions

See `.github/workflows/qe-on-duty-daily.yaml` (example not included in initial implementation)

## License

Internal Red Hat tool for Podman Desktop QE team.

## Support

For issues or questions:
- File an issue in the repository
- Contact the QE team on Slack

---

**Generated by**: Podman Desktop QE Team
**Maintained by**: QE On-Duty rotation
