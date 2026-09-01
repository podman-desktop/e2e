"""Collector for issues and bug reports."""

from typing import List
from datetime import datetime, timedelta, timezone
from dateutil import parser as date_parser
from qe_on_duty.gh_client import GHClient
from qe_on_duty.config import Config
from qe_on_duty.models.snapshot import IssueData


class IssueCollector:
    """Collect issues and bug reports."""

    def __init__(self, gh_client: GHClient, config: Config):
        """
        Initialize issue collector.

        Args:
            gh_client: GitHub CLI client
            config: Configuration object
        """
        self.gh_client = gh_client
        self.config = config
        self.labels = config.get_issue_labels()
        self.states = config.get_issue_states()
        self.max_age_days = config.get_issue_max_age_days()
        self.max_results = config.get_issue_max_results()

    def collect(self, repositories: List[str]) -> List[IssueData]:
        """
        Collect issues from all repositories.

        Args:
            repositories: List of repository names in owner/repo format

        Returns:
            List of IssueData objects
        """
        all_issues = []
        for repo in repositories:
            try:
                issues = self._collect_from_repo(repo)
                all_issues.extend(issues)
            except Exception as e:
                print(f"⚠️  Failed to collect issues from {repo}: {e}")

        return all_issues

    def _collect_from_repo(self, repo: str) -> List[IssueData]:
        """
        Collect issues from a single repository.

        Args:
            repo: Repository name in owner/repo format

        Returns:
            List of IssueData objects
        """
        # gh's --state flag only accepts a single value; when multiple states
        # are configured, fetch "all" and filter locally to the allowed set.
        gh_state = self.states[0] if len(self.states) == 1 else ("all" if self.states else "open")
        issues = self.gh_client.issue_list(
            repo,
            labels=self.labels,
            state=gh_state,
            limit=self.max_results
        )

        if len(self.states) > 1:
            allowed_states = {s.lower() for s in self.states}
            issues = [i for i in issues if i.get('state', '').lower() in allowed_states]

        # Filter by age if needed
        if self.max_age_days > 0:
            cutoff_date = datetime.now(timezone.utc) - timedelta(days=self.max_age_days)
            filtered_issues = []
            for issue in issues:
                created_at = date_parser.parse(issue['createdAt'])
                if created_at >= cutoff_date:
                    filtered_issues.append(self._parse_issue(issue, repo))
            return filtered_issues
        else:
            return [self._parse_issue(issue, repo) for issue in issues]

    def _parse_issue(self, issue: dict, repo: str) -> IssueData:
        """
        Parse issue data from gh CLI output to IssueData model.

        Args:
            issue: Issue data dictionary from gh CLI
            repo: Repository name

        Returns:
            IssueData object
        """
        return IssueData(
            repository=repo,
            number=issue['number'],
            title=issue['title'],
            url=issue['url'],
            author=issue['author']['login'] if issue.get('author') else 'unknown',
            labels=[label['name'] for label in issue.get('labels', [])],
            assignees=[assignee['login'] for assignee in issue.get('assignees', [])],
            state=issue['state'],
            created_at=issue['createdAt'],
            updated_at=issue['updatedAt'],
            comments_count=len(issue.get('comments') or [])
        )
