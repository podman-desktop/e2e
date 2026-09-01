#!/usr/bin/env python3
"""QE On-Duty automation script - main entry point."""

import argparse
import os
import sys
from datetime import datetime
from pathlib import Path

from qe_on_duty.config import Config
from qe_on_duty.gh_client import GHClient
from qe_on_duty.collectors.pr_collector import PRCollector
from qe_on_duty.collectors.workflow_collector import WorkflowCollector
from qe_on_duty.collectors.cve_collector import CVECollector
from qe_on_duty.collectors.issue_collector import IssueCollector
from qe_on_duty.models.snapshot import DailySnapshot, SummaryData
from qe_on_duty.reporters.daily_reporter import DailyReporter
from qe_on_duty.reporters.weekly_reporter import WeeklyReporter


def calculate_summary(prs, workflows, cves, issues) -> SummaryData:
    """
    Calculate summary statistics from collected data.

    Args:
        prs: List of PRData objects
        workflows: List of WorkflowData objects
        cves: List of CVEData objects
        issues: List of IssueData objects

    Returns:
        SummaryData object
    """
    overnight = [w for w in workflows if not w.is_fallback]
    return SummaryData(
        total_prs_needing_qe=len(prs),
        total_workflow_runs=len(overnight),
        failed_workflow_runs=len([w for w in overnight if w.conclusion == 'failure']),
        critical_cves=len([c for c in cves if c.severity == 'critical']),
        high_cves=len([c for c in cves if c.severity == 'high']),
        total_open_bugs=len(issues)
    )


def load_daily_snapshots(output_dir: str, start_date: datetime, end_date: datetime) -> list:
    """
    Load daily snapshots for a date range (latest snapshot per day).

    Args:
        output_dir: Base output directory
        start_date: Start date
        end_date: End date

    Returns:
        List of DailySnapshot objects
    """
    from datetime import timedelta

    snapshots = []
    current = start_date

    while current <= end_date:
        date_str = current.strftime('%Y-%m-%d')
        day_dir = os.path.join(output_dir, 'snapshots', date_str)

        if os.path.exists(day_dir):
            # Check for latest.json symlink
            latest_link = os.path.join(day_dir, 'latest.json')
            if os.path.exists(latest_link):
                try:
                    snapshot = DailySnapshot.load(latest_link)
                    snapshots.append(snapshot)
                except Exception as e:
                    print(f"⚠️  Failed to load snapshot for {date_str}: {e}")
            else:
                # Find most recent snapshot in the directory
                snapshot_files = sorted([f for f in os.listdir(day_dir) if f.endswith('.json') and f != 'latest.json'])
                if snapshot_files:
                    latest_file = os.path.join(day_dir, snapshot_files[-1])
                    try:
                        snapshot = DailySnapshot.load(latest_file)
                        snapshots.append(snapshot)
                    except Exception as e:
                        print(f"⚠️  Failed to load snapshot for {date_str}: {e}")

        current = current + timedelta(days=1)

    return snapshots


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Podman Desktop QE On-Duty Automation",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        '--config',
        default='config.yaml',
        help='Path to configuration file (default: config.yaml)'
    )
    parser.add_argument(
        '--weekly',
        action='store_true',
        help='Generate weekly summary report'
    )
    parser.add_argument(
        '--output-dir',
        help='Override output directory'
    )
    parser.add_argument(
        '--date',
        help='Date for report (YYYY-MM-DD), defaults to today'
    )
    parser.add_argument(
        '--time',
        help='Time for report (HHMM), defaults to current time'
    )

    args = parser.parse_args()

    # Load configuration
    try:
        config = Config(args.config)
    except Exception as e:
        print(f"❌ Failed to load configuration: {e}")
        sys.exit(1)

    if args.output_dir:
        config.output_base_dir = args.output_dir
        config.snapshots_dir = os.path.join(args.output_dir, 'snapshots')
        config.reports_dir = os.path.join(args.output_dir, 'reports')

    # Parse date and time
    now = datetime.now()
    report_date = args.date if args.date else now.strftime('%Y-%m-%d')
    report_time = args.time if args.time else now.strftime('%H%M')
    try:
        if len(report_date) != 10 or len(report_time) != 4:
            raise ValueError
        report_datetime = datetime.strptime(
            f"{report_date} {report_time}",
            "%Y-%m-%d %H%M",
        )
    except ValueError:
        parser.error("--date must be YYYY-MM-DD and --time must be HHMM")

    timestamp = report_datetime.isoformat(timespec="seconds")

    if args.weekly:
        # Generate weekly report from existing snapshots
        from datetime import timedelta
        end = datetime.strptime(report_date, '%Y-%m-%d')
        start = end - timedelta(days=6)  # Last 7 days including today

        print(f"📅 Loading snapshots from {start.strftime('%Y-%m-%d')} to {end.strftime('%Y-%m-%d')}...")
        snapshots = load_daily_snapshots(config.output_base_dir, start, end)

        if not snapshots:
            print("❌ No snapshots found for the specified period")
            sys.exit(1)

        print(f"📄 Generating weekly report from {len(snapshots)} snapshots...")
        weekly_reporter = WeeklyReporter(snapshots, config)
        report = weekly_reporter.generate()

        # Determine ISO year/week number
        iso_year, week_num, _ = end.isocalendar()
        report_path = os.path.join(config.reports_dir, 'weekly', f"{iso_year}-week-{week_num:02d}.md")

        os.makedirs(os.path.dirname(report_path), exist_ok=True)
        with open(report_path, 'w') as f:
            f.write(report)

        print(f"📄 Weekly report saved: {report_path}")
        sys.exit(0)

    # Initialize GitHub CLI client
    try:
        gh_client = GHClient(config.gh_cli_path, config.max_retries)
    except Exception as e:
        print(f"❌ {e}")
        sys.exit(1)

    # Get current authenticated user
    try:
        current_user = gh_client.get_current_user()
        print(f"👤 Authenticated as: {current_user}")
    except Exception as e:
        print(f"⚠️  Could not detect current user: {e}")
        current_user = ""

    # Get all repositories with source information
    categorized = config.get_categorized_repositories()
    all_repos = config.get_all_repositories()

    print(f"\n📊 Repositories included in this run ({len(all_repos)} total):")
    if categorized['core']:
        print(f"\n  Core ({len(categorized['core'])}):")
        for repo in categorized['core']:
            print(f"    - {repo}")
    if categorized['domains']:
        print(f"\n  Domains.json — owned by {config.domains_user_name} ({len(categorized['domains'])}):")
        for repo in categorized['domains']:
            print(f"    - {repo}")
    if categorized['custom']:
        print(f"\n  Custom ({len(categorized['custom'])}):")
        for repo in categorized['custom']:
            print(f"    - {repo}")
    print()

    # Daily report - collect fresh data
    # Initialize collectors
    pr_collector = PRCollector(gh_client, config, current_user=current_user)
    workflow_collector = WorkflowCollector(gh_client, config)
    cve_collector = CVECollector(gh_client, config)
    issue_collector = IssueCollector(gh_client, config)

    # Collect data
    print("🔍 Collecting PRs...")
    prs = pr_collector.collect(all_repos)
    print(f"  Found {len(prs)} PRs needing QE review")

    cutoff = workflow_collector.get_overnight_cutoff()
    collection_end = datetime.now()
    print(f"🔍 Collecting workflow runs since {cutoff.strftime('%Y-%m-%d %H:%M')}...")
    workflows = workflow_collector.collect(all_repos)
    overnight = [w for w in workflows if not w.is_fallback]
    fallback = [w for w in workflows if w.is_fallback]
    overnight_failed = len([w for w in overnight if w.conclusion == 'failure'])
    print(f"  Overnight: {overnight_failed} failed / {len(overnight)} total")
    if fallback:
        print(f"  Fallback (latest runs, no overnight activity): {len(fallback)} repos")

    print("🔍 Collecting CVE alerts...")
    cves = cve_collector.collect(all_repos)
    print(f"  Found {len(cves)} CVE alerts")

    print("🔍 Collecting issues...")
    issues = issue_collector.collect(all_repos)
    print(f"  Found {len(issues)} open bugs")

    # Create snapshot
    snapshot = DailySnapshot(
        date=report_date,
        time=report_time[:2] + ":" + report_time[2:],
        timestamp=timestamp,
        prs=prs,
        workflows=workflows,
        cves=cves,
        issues=issues,
        summary=calculate_summary(prs, workflows, cves, issues),
        overnight_cutoff=cutoff.isoformat(timespec="seconds"),
        overnight_window_end=collection_end.isoformat(timespec="seconds")
    )

    # Create output directories
    day_snapshot_dir = os.path.join(config.snapshots_dir, report_date)
    day_report_dir = os.path.join(config.reports_dir, 'daily', report_date)
    os.makedirs(day_snapshot_dir, exist_ok=True)
    os.makedirs(day_report_dir, exist_ok=True)

    # Save snapshot
    snapshot_path = os.path.join(day_snapshot_dir, f"{report_time}.json")
    snapshot.save(snapshot_path)
    print(f"💾 Snapshot saved: {snapshot_path}")

    # Create/update latest.json symlink
    latest_link = os.path.join(day_snapshot_dir, 'latest.json')
    if os.path.lexists(latest_link):
        os.unlink(latest_link)
    os.symlink(f"{report_time}.json", latest_link)
    print(f"🔗 Latest symlink updated: {latest_link}")

    # Generate daily report
    daily_reporter = DailyReporter(snapshot, config)
    report_path = os.path.join(day_report_dir, f"{report_time}.md")
    daily_reporter.save(report_path)
    print(f"📄 Report saved: {report_path}")

    # Print summary to stdout
    print("\n" + "=" * 60)
    print(f"✅ QE On-Duty Report - {report_date} {report_time[:2]}:{report_time[2:]}")
    print("=" * 60)
    qe_reviewers = sorted(pr_collector.qe_reviewers)
    print(f"QE reviewers tracked: {', '.join(qe_reviewers)}")
    print(f"PRs needing QE review: {snapshot.summary.total_prs_needing_qe}")
    print(f"Failed workflows: {snapshot.summary.failed_workflow_runs}/{snapshot.summary.total_workflow_runs}")
    print(f"Critical CVEs: {snapshot.summary.critical_cves}")
    print(f"High CVEs: {snapshot.summary.high_cves}")
    print(f"Open bugs: {snapshot.summary.total_open_bugs}")
    print("=" * 60)


if __name__ == "__main__":
    main()
