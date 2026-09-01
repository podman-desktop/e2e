"""Collector for pull requests requiring QE review."""

from typing import List
from datetime import datetime
from qe_on_duty.gh_client import GHClient
from qe_on_duty.config import Config
from qe_on_duty.models.snapshot import PRData


class PRCollector:
    """Collect pull requests requiring QE review."""

    def __init__(self, gh_client: GHClient, config: Config, current_user: str = ""):
        """
        Initialize PR collector.

        Args:
            gh_client: GitHub CLI client
            config: Configuration object
            current_user: GitHub username of the person running the script
        """
        self.gh_client = gh_client
        self.config = config
        self.qe_labels = config.get_pr_labels()
        self.qe_teams = config.get_pr_assignee_teams()
        self.qe_reviewers = set(config.get_qe_reviewers())
        if current_user:
            self.qe_reviewers.add(current_user)
        self.current_user = current_user
        self.max_results = config.get_pr_max_results()

    def collect(self, repositories: List[str]) -> List[PRData]:
        """
        Collect PRs needing QE review from all repositories.

        Args:
            repositories: List of repository names in owner/repo format

        Returns:
            List of PRData objects
        """
        all_prs = []
        for repo in repositories:
            try:
                prs = self._collect_from_repo(repo)
                all_prs.extend(prs)
            except Exception as e:
                print(f"⚠️  Failed to collect PRs from {repo}: {e}")

        return all_prs

    def _collect_from_repo(self, repo: str) -> List[PRData]:
        """
        Collect PRs from a single repository.

        Args:
            repo: Repository name in owner/repo format

        Returns:
            List of PRData objects
        """
        # Get all open PRs (up to the configured cap, before local QE filtering)
        prs = self.gh_client.pr_list(repo, state="open", limit=self.max_results)

        # Filter PRs matching QE criteria
        qe_prs = []
        for pr in prs:
            if self._matches_qe_criteria(pr):
                qe_prs.append(self._parse_pr(pr, repo))

        return qe_prs

    def _matches_qe_criteria(self, pr: dict) -> bool:
        """
        Check if PR matches QE review criteria.

        A PR matches if it has a QE label, has a QE team requested as reviewer,
        or is assigned/requested for review by any known QE reviewer or the
        current user.

        Args:
            pr: PR data dictionary from gh CLI

        Returns:
            True if PR needs QE review
        """
        pr_labels = [label['name'] for label in pr.get('labels', [])]
        has_qe_label = any(label in self.qe_labels for label in pr_labels)

        assignees = [assignee['login'] for assignee in pr.get('assignees', [])]
        requested_users, requested_teams = self._parse_review_requests(pr)

        # Config may list a team as either "qe-reviewers" or the slug form
        # "org/qe-reviewers"; GitHub always reports the requested team's plain
        # name (no org prefix), so compare on the short name either way.
        has_qe_team = any(
            team.rsplit('/', 1)[-1] == req_team
            for team in self.qe_teams
            for req_team in requested_teams
        )
        has_qe_reviewer = any(a in self.qe_reviewers for a in assignees) or \
            any(u in self.qe_reviewers for u in requested_users)

        return has_qe_label or has_qe_team or has_qe_reviewer

    def _parse_review_requests(self, pr: dict) -> tuple:
        """
        Split a PR's requested reviewers into individual users and teams.

        GitHub reports requested reviewers as a mix of User and Team objects;
        assignees cannot hold teams, so team-based requests only ever show up
        here (e.g. requesting the "qe-reviewers" team).

        Args:
            pr: PR data dictionary from gh CLI

        Returns:
            Tuple of (list of user logins, list of team names)
        """
        users = []
        teams = []
        for reviewer in pr.get('reviewRequests', []) or []:
            if reviewer.get('__typename') == 'Team':
                teams.append(reviewer.get('name', ''))
            else:
                users.append(reviewer.get('login', ''))
        return users, teams

    def _parse_pr(self, pr: dict, repo: str) -> PRData:
        """
        Parse PR data from gh CLI output to PRData model.

        Args:
            pr: PR data dictionary from gh CLI
            repo: Repository name

        Returns:
            PRData object
        """
        requested_users, requested_teams = self._parse_review_requests(pr)

        return PRData(
            repository=repo,
            number=pr['number'],
            title=pr['title'],
            url=pr['url'],
            author=pr['author']['login'] if pr.get('author') else 'unknown',
            labels=[label['name'] for label in pr.get('labels', [])],
            assignees=[assignee['login'] for assignee in pr.get('assignees', [])],
            created_at=pr['createdAt'],
            updated_at=pr['updatedAt'],
            state=pr['state'],
            draft=pr.get('isDraft', False),
            requested_reviewers=requested_users + [f"team:{t}" for t in requested_teams]
        )
