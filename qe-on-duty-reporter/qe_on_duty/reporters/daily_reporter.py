"""Daily markdown report generator."""

from typing import List, Dict
from collections import defaultdict
from datetime import datetime
from qe_on_duty.models.snapshot import DailySnapshot, WorkflowData
from qe_on_duty.config import Config


class DailyReporter:
    """Generate daily markdown reports from snapshots."""

    def __init__(self, snapshot: DailySnapshot, config: Config):
        """
        Initialize daily reporter.

        Args:
            snapshot: Daily snapshot data
            config: Configuration object
        """
        self.snapshot = snapshot
        self.config = config

    def generate(self) -> str:
        """
        Generate markdown report.

        Returns:
            Markdown formatted report string
        """
        sections = [
            self._generate_header(),
            self._generate_summary(),
            self._generate_pr_section(),
            self._generate_workflow_section(),
            self._generate_cve_section(),
            self._generate_issue_section(),
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
        return f"# QE On-Duty Report - {self.snapshot.date} {self.snapshot.time}\n\n**Generated**: {self.snapshot.timestamp}"

    def _generate_summary(self) -> str:
        """Generate summary section."""
        summary = self.snapshot.summary
        if not summary:
            return "## Summary\n\nNo data available."

        return f"""## Summary

- 🔍 **PRs Needing QE Review**: {summary.total_prs_needing_qe}
- {self._get_workflow_emoji(summary)} **Overnight Workflows**: {summary.failed_workflow_runs} failed / {summary.total_workflow_runs} total
- {self._get_cve_emoji(summary)} **CVEs**: {summary.critical_cves} Critical, {summary.high_cves} High
- 🐛 **Open Bugs**: {summary.total_open_bugs}"""

    def _get_workflow_emoji(self, summary) -> str:
        """Get emoji for workflow status."""
        if summary.failed_workflow_runs == 0:
            return "✅"
        elif summary.failed_workflow_runs < 5:
            return "⚠️"
        else:
            return "❌"

    def _get_cve_emoji(self, summary) -> str:
        """Get emoji for CVE status."""
        if summary.critical_cves > 0:
            return "❌"
        elif summary.high_cves > 0:
            return "⚠️"
        else:
            return "✅"

    def _generate_pr_section(self) -> str:
        """Generate pull requests section."""
        if not self.snapshot.prs:
            return "## 1. Pull Requests Requiring QE Review\n\n*No PRs requiring QE review found.*"

        # Group PRs by repository
        prs_by_repo = defaultdict(list)
        for pr in self.snapshot.prs:
            prs_by_repo[pr.repository].append(pr)

        sections = ["## 1. Pull Requests Requiring QE Review\n"]

        for repo in sorted(prs_by_repo.keys()):
            sections.append(f"### {repo}")
            for pr in prs_by_repo[repo]:
                draft_marker = " 🚧 (Draft)" if pr.draft else ""
                labels = ", ".join(f"`{label}`" for label in pr.labels if label in self.config.get_pr_labels())
                assignees_str = ", ".join(f"@{a}" for a in pr.assignees) if pr.assignees else "none"
                reviewers_str = ", ".join(
                    f"team:@{r[5:]}" if r.startswith("team:") else f"@{r}"
                    for r in pr.requested_reviewers
                ) if pr.requested_reviewers else "none"
                sections.append(
                    f"- 🔍 **[#{pr.number}]({pr.url})** {pr.title}{draft_marker}\n"
                    f"  - Labels: {labels if labels else 'none'}\n"
                    f"  - Author: @{pr.author}\n"
                    f"  - Assignees: {assignees_str}\n"
                    f"  - Requested reviewers: {reviewers_str}\n"
                    f"  - Updated: {pr.updated_at}"
                )

        return "\n\n".join(sections)

    def _get_overnight_window_str(self) -> str:
        """Format the overnight window actually used to collect this snapshot's workflows."""
        cutoff = self.snapshot.overnight_cutoff
        window_end = self.snapshot.overnight_window_end
        if not cutoff or not window_end:
            return "unknown (older snapshot, window not recorded)"
        cutoff_str = datetime.fromisoformat(cutoff).strftime('%Y-%m-%d %H:%M')
        end_str = datetime.fromisoformat(window_end).strftime('%Y-%m-%d %H:%M')
        return f"{cutoff_str} — {end_str}"

    def _generate_workflow_section(self) -> str:
        """Generate CI/CD workflow section (failed overnight + fallback latest)."""
        window = self._get_overnight_window_str()
        overnight = [wf for wf in self.snapshot.workflows if not wf.is_fallback]
        overnight_failed = [wf for wf in overnight if wf.conclusion == 'failure']
        fallback = [wf for wf in self.snapshot.workflows if wf.is_fallback]

        sections = [f"## 2. Workflow Runs (Overnight)\n\n**Window**: {window}\n"]

        if overnight_failed:
            sections.append("### Failed Runs\n")
            self._append_grouped_workflows(sections, overnight_failed)
        else:
            sections.append("*No failed workflow runs in the overnight window.*\n")

        overnight_passed = [wf for wf in overnight if wf.conclusion == 'success']
        if overnight_passed:
            sections.append("### Passing Runs\n")
            self._append_grouped_workflows(sections, overnight_passed)

        if fallback:
            sections.append("### Latest Runs (no overnight activity)\n")
            self._append_grouped_workflows(sections, fallback)

        return "\n\n".join(sections)

    def _append_grouped_workflows(self, sections: list, workflows: List[WorkflowData]):
        """Group workflows by repo and append formatted blocks to sections."""
        core_repos = set(self.config.core_repositories)
        by_repo = defaultdict(list)
        for wf in workflows:
            by_repo[wf.repository].append(wf)

        core = sorted(r for r in by_repo if r in core_repos)
        ext = sorted(r for r in by_repo if r not in core_repos)

        for repo in core + ext:
            sections.append(self._format_repo_workflows(repo, by_repo[repo]))

    def _format_repo_workflows(self, repo: str, workflows: List[WorkflowData]) -> str:
        """Format workflows for a single repository."""
        lines = [f"#### {repo}"]

        for wf in workflows[:10]:
            emoji = self._get_status_emoji(wf.conclusion)
            date_str = wf.started_at[:10] if wf.started_at else ""
            fallback_marker = f" *(latest, {date_str})*" if wf.is_fallback else ""
            lines.append(
                f"- {emoji} **{wf.workflow_name}** (#{wf.run_number}) - {wf.conclusion}{fallback_marker} - [Link]({wf.url})"
            )

        if len(workflows) > 10:
            lines.append(f"\n  *...and {len(workflows) - 10} more runs*")

        return "\n".join(lines)

    def _get_status_emoji(self, conclusion: str) -> str:
        """Map workflow conclusion to emoji."""
        emoji_map = {
            'success': '✅',
            'failure': '❌',
            'cancelled': '⚠️',
            'skipped': '⏭️',
            'neutral': '➖',
            'timed_out': '⏱️',
        }
        return emoji_map.get(conclusion, '❓')

    def _generate_cve_section(self) -> str:
        """Generate CVE/security alerts section."""
        if not self.snapshot.cves:
            return "## 3. Security Alerts (CVEs)\n\n*No open CVE alerts found.*"

        # Group by severity
        cves_by_severity = defaultdict(list)
        for cve in self.snapshot.cves:
            cves_by_severity[cve.severity].append(cve)

        sections = ["## 3. Security Alerts (CVEs)\n"]

        # Order by severity
        for severity in ['critical', 'high', 'medium', 'low']:
            if severity in cves_by_severity:
                emoji = "❌" if severity == "critical" else "⚠️" if severity == "high" else "ℹ️"
                sections.append(f"### {emoji} {severity.capitalize()} Severity\n")

                for cve in cves_by_severity[severity]:
                    sections.append(
                        f"- **[{cve.cve_id}]({cve.url})** in `{cve.repository}`\n"
                        f"  - Package: `{cve.package_name}` (vulnerable: {cve.vulnerable_version}, patched: {cve.patched_version})\n"
                        f"  - Alert #{cve.alert_number}"
                    )

        return "\n\n".join(sections)

    def _generate_issue_section(self) -> str:
        """Generate open bugs section."""
        if not self.snapshot.issues:
            return "## 4. Open Bugs\n\n*No open bugs found.*"

        # Group by repository
        issues_by_repo = defaultdict(list)
        for issue in self.snapshot.issues:
            issues_by_repo[issue.repository].append(issue)

        sections = ["## 4. Open Bugs\n"]

        for repo in sorted(issues_by_repo.keys()):
            issues = issues_by_repo[repo]
            sections.append(f"### {repo} ({len(issues)} bugs)\n")

            for issue in issues[:10]:  # Limit to 10 per repo
                sections.append(
                    f"- 🐛 **[#{issue.number}]({issue.url})** {issue.title}\n"
                    f"  - Created: {issue.created_at} | Comments: {issue.comments_count}"
                )

            if len(issues) > 10:
                sections.append(f"\n  *...and {len(issues) - 10} more bugs*")

        return "\n\n".join(sections)

    def _generate_footer(self) -> str:
        """Generate report footer with repository listing and workflow filter config."""
        categorized = self.config.get_categorized_repositories()
        all_repos = self.config.get_all_repositories()

        lines = ["## Report Configuration\n"]

        # Repository coverage
        lines.append(f"### Repositories ({len(all_repos)} total)\n")

        if categorized['core']:
            lines.append(f"**Core** ({len(categorized['core'])})")
            for repo in categorized['core']:
                lines.append(f"- {repo}")

        if categorized['domains']:
            lines.append(f"\n**Domains.json — owned by {self.config.domains_user_name}** ({len(categorized['domains'])})")
            for repo in categorized['domains']:
                lines.append(f"- {repo}")

        if categorized['custom']:
            lines.append(f"\n**Custom** ({len(categorized['custom'])})")
            for repo in categorized['custom']:
                lines.append(f"- {repo}")

        # Workflow filters
        lines.append("\n### Workflow Filters\n")
        lines.append(f"- **Overnight window**: {self._get_overnight_window_str()}")
        lines.append(f"- **Include pattern**: workflows matching `{self.config.get_workflow_default_name_pattern()}` (case-insensitive)")

        exclusions = self.config.get_workflow_exclusions()
        if exclusions:
            lines.append(f"- **Excluded**: {', '.join(f'`{e}`' for e in exclusions)}")

        overrides = self.config.get_workflow_repo_overrides()
        if overrides:
            lines.append("\n**Additional per-repo workflows** (on top of default pattern):")
            for repo, workflows in sorted(overrides.items()):
                lines.append(f"- `{repo}`: {', '.join(f'`{w}`' for w in workflows)}")

        lines.append("\n---\n")
        lines.append("*Generated by QE On-Duty automation script*")

        return "\n".join(lines)
