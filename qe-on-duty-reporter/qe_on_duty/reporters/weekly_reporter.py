"""Weekly summary report generator."""

from typing import List, Dict
from collections import defaultdict, Counter
from datetime import datetime
from qe_on_duty.models.snapshot import DailySnapshot
from qe_on_duty.config import Config


class WeeklyReporter:
    """Generate weekly summary reports from daily snapshots."""

    def __init__(self, snapshots: List[DailySnapshot], config: Config):
        """
        Initialize weekly reporter.

        Args:
            snapshots: List of daily snapshots (latest from each day)
            config: Configuration object
        """
        self.snapshots = sorted(snapshots, key=lambda s: s.timestamp)
        self.config = config

    def generate(self) -> str:
        """
        Generate weekly summary markdown report.

        Returns:
            Markdown formatted report string
        """
        if not self.snapshots:
            return "# Weekly Summary\n\n*No snapshots available for this week.*"

        sections = [
            self._generate_header(),
            self._generate_highlights(),
            self._generate_active_repos(),
            self._generate_failing_workflows(),
            self._generate_cve_trends(),
            self._generate_daily_links(),
            self._generate_footer()
        ]

        return "\n\n---\n\n".join(filter(None, sections))

    def save(self, filepath: str):
        """
        Save report to markdown file.

        Args:
            filepath: Path to save the report
        """
        with open(filepath, 'w') as f:
            f.write(self.generate())

    def _generate_header(self) -> str:
        """Generate report header."""
        if not self.snapshots:
            return "# QE On-Duty Weekly Summary"

        start_date = self.snapshots[0].date
        end_date = self.snapshots[-1].date
        iso_year, week_num, _ = datetime.strptime(end_date, '%Y-%m-%d').isocalendar()

        return f"""# QE On-Duty Weekly Summary - Week {iso_year}-week-{week_num:02d}

**Period**: {start_date} to {end_date}
**Snapshots**: {len(self.snapshots)} days"""

    def _generate_highlights(self) -> str:
        """Generate weekly highlights."""
        if not self.snapshots:
            return ""

        # Calculate averages
        snapshots_with_summary = [s for s in self.snapshots if s.summary]
        if not snapshots_with_summary:
            return "## Weekly Highlights\n\n*No summary data available.*"

        summaries = [s.summary for s in snapshots_with_summary]

        avg_prs = sum(s.total_prs_needing_qe for s in summaries) / len(summaries)
        total_workflows = sum(s.total_workflow_runs for s in summaries)
        total_success = sum(
            1 for s in snapshots_with_summary for wf in s.workflows
            if not wf.is_fallback and wf.conclusion == 'success'
        )
        success_rate = (total_success / total_workflows * 100) if total_workflows > 0 else 0

        # Use unique alert counts (not per-day summary sums) so a CVE open all
        # week is counted once, matching the CVE Summary section below.
        severity_counts = self._unique_alert_severities()
        total_critical_cves = severity_counts['critical']
        total_high_cves = severity_counts['high']
        total_bugs = sum(s.total_open_bugs for s in summaries)

        return f"""## Weekly Highlights

- 📊 **Average PRs/day needing QE**: {avg_prs:.1f}
- ✅ **Overall Workflow Success Rate**: {success_rate:.1f}%
- 🔒 **CVEs**: {total_critical_cves} Critical, {total_high_cves} High
- 🐛 **Average Open Bugs**: {total_bugs / len(summaries):.0f}"""

    def _generate_active_repos(self) -> str:
        """Generate most active repositories section."""
        pr_counts = Counter()
        workflow_counts = Counter()

        for snapshot in self.snapshots:
            for pr in snapshot.prs:
                pr_counts[pr.repository] += 1
            for wf in snapshot.workflows:
                if not wf.is_fallback:
                    workflow_counts[wf.repository] += 1

        if not pr_counts and not workflow_counts:
            return ""

        sections = ["## Most Active Repositories\n"]

        # Combine and rank
        repo_activity = {}
        for repo in set(pr_counts.keys()) | set(workflow_counts.keys()):
            repo_activity[repo] = (pr_counts[repo], workflow_counts[repo])

        # Sort by total activity
        sorted_repos = sorted(
            repo_activity.items(),
            key=lambda x: x[1][0] + x[1][1],
            reverse=True
        )

        for i, (repo, (prs, workflows)) in enumerate(sorted_repos[:10], 1):
            sections.append(f"{i}. **{repo}** - {prs} PRs, {workflows} workflow runs")

        return "\n".join(sections)

    def _generate_failing_workflows(self) -> str:
        """Generate consistently failing workflows section."""
        # Count failures by workflow + repo
        workflow_failures = defaultdict(lambda: {'failed': 0, 'total': 0})

        for snapshot in self.snapshots:
            for wf in snapshot.workflows:
                if wf.is_fallback:
                    continue
                key = f"{wf.repository} → {wf.workflow_name}"
                workflow_failures[key]['total'] += 1
                if wf.conclusion == 'failure':
                    workflow_failures[key]['failed'] += 1

        # Find workflows that failed multiple times
        consistently_failing = []
        for workflow, counts in workflow_failures.items():
            if counts['failed'] >= 3:  # Failed 3+ times
                consistently_failing.append((workflow, counts['failed'], counts['total']))

        if not consistently_failing:
            return "## Consistently Failing Workflows\n\n*No workflows failed consistently this week.*"

        sections = ["## Consistently Failing Workflows\n"]

        # Sort by failure count
        for workflow, failed, total in sorted(consistently_failing, key=lambda x: x[1], reverse=True):
            sections.append(f"- ❌ **{workflow}** - failed {failed}/{total} times")

        return "\n".join(sections)

    def _unique_alert_severities(self) -> Counter:
        """Latest severity per unique CVE alert (repository, alert_number) across the week."""
        alert_severity = {}
        for snapshot in self.snapshots:
            for cve in snapshot.cves:
                alert_key = (cve.repository, cve.alert_number)
                alert_severity[alert_key] = cve.severity
        return Counter(alert_severity.values())

    def _generate_cve_trends(self) -> str:
        """Generate CVE trends section."""
        if not self.snapshots:
            return ""

        severity_counts = self._unique_alert_severities()
        if not severity_counts:
            return "## CVE Summary\n\n*No CVEs found this week.*"

        return f"""## CVE Summary

- ❌ **Critical**: {severity_counts['critical']} unique alerts
- ⚠️  **High**: {severity_counts['high']} unique alerts
- ℹ️  **Medium**: {severity_counts['medium']} unique alerts
- ℹ️  **Low**: {severity_counts['low']} unique alerts"""

    def _generate_daily_links(self) -> str:
        """Generate links to daily reports."""
        if not self.snapshots:
            return ""

        sections = ["## Daily Reports\n"]

        for snapshot in self.snapshots:
            filename_time = snapshot.time.replace(":", "")
            sections.append(
                f"- [{snapshot.date} {snapshot.time}]"
                f"(../daily/{snapshot.date}/{filename_time}.md)"
            )

        return "\n".join(sections)

    def _generate_footer(self) -> str:
        """Generate report footer."""
        return "*Generated by QE On-Duty automation script*"
