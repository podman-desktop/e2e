"""Configuration management for QE on-duty script."""

import yaml
import os
from typing import List, Dict, Any
from qe_on_duty.utils.repository_parser import RepositoryParser, Repository


class Config:
    """Configuration loader and manager."""

    def __init__(self, config_path: str = "config.yaml"):
        """
        Load configuration from YAML file.

        Args:
            config_path: Path to config.yaml file
        """
        self.config_path = config_path
        self._load_config()

    def _load_config(self):
        """Load and parse configuration file."""
        with open(self.config_path, 'r') as f:
            config = yaml.safe_load(f) or {}

        # GitHub settings
        github_config = config.get('github') or {}
        self.gh_cli_path = github_config.get('cli_path') or 'gh'
        max_retries = github_config.get('max_retries')
        self.max_retries = max_retries if max_retries is not None else 3

        # Repository settings
        repo_config = config.get('repositories') or {}
        self.core_repositories = repo_config.get('core') or []
        self.custom_repositories = repo_config.get('custom') or []
        self.domains_json_path = repo_config.get('domains_json') or ''
        self.domains_user_name = repo_config.get('domains_user_name') or ''

        if self.domains_json_path and not os.path.exists(self.domains_json_path):
            print(
                f"⚠️  repositories.domains_json is set to '{self.domains_json_path}' "
                "but that file does not exist - domain-owned repositories will be skipped"
            )

        # Output settings
        output_config = config.get('output') or {}
        self.output_base_dir = output_config.get('base_dir') or 'output'
        self.snapshots_dir = os.path.join(self.output_base_dir, 'snapshots')
        self.reports_dir = os.path.join(self.output_base_dir, 'reports')

        # Filter settings
        self.pr_filters = config.get('pr_filters') or {}
        self.workflow_filters = config.get('workflow_filters') or {}
        self.cve_filters = config.get('cve_filters') or {}
        self.issue_filters = config.get('issue_filters') or {}

    def get_all_repositories(self) -> List[str]:
        """
        Get deduplicated list of all repositories to scan.

        Includes: core + owned domains.json repos + custom.

        Returns:
            Sorted list of repository names in owner/repo format
        """
        categorized = self.get_categorized_repositories()
        repos = set()
        for source_repos in categorized.values():
            repos.update(source_repos)
        return sorted(repos)

    def get_categorized_repositories(self) -> Dict[str, List[str]]:
        """
        Get repositories grouped by source.

        Returns:
            Dict with keys 'core', 'domains', 'custom' mapping to repo lists.
            'domains' only includes repos where domains_user_name is a qe_owner.
        """
        result: Dict[str, List[str]] = {
            'core': list(self.core_repositories),
            'domains': [],
            'custom': list(self.custom_repositories),
        }

        if self.domains_json_path and os.path.exists(self.domains_json_path) and self.domains_user_name:
            parser = RepositoryParser(self.domains_json_path)
            for repo in parser.parse():
                if self.domains_user_name in repo.qe_owners:
                    result['domains'].append(repo.name)

        result['domains'].sort()
        return result

    def get_extension_repositories(self) -> List[Repository]:
        """
        Get all extension repositories from domains.json with metadata.

        Returns:
            List of Repository objects
        """
        if self.domains_json_path and os.path.exists(self.domains_json_path):
            parser = RepositoryParser(self.domains_json_path)
            return parser.parse()
        return []

    def get_pr_labels(self) -> List[str]:
        """Get PR filter labels."""
        return self.pr_filters.get('labels') or []

    def get_pr_assignee_teams(self) -> List[str]:
        """Get PR assignee teams."""
        return self.pr_filters.get('assignee_teams') or []

    def get_qe_reviewers(self) -> List[str]:
        """Get individual QE reviewer GitHub usernames."""
        return self.pr_filters.get('qe_reviewers') or []

    def get_pr_max_results(self) -> int:
        """Get the maximum number of open PRs to fetch per repo before local filtering."""
        return self.pr_filters.get('max_results') or 500

    def get_workflow_max_age_days(self) -> int:
        """Get maximum age for workflow runs in days."""
        max_age_days = self.workflow_filters.get('max_age_days')
        return max_age_days if max_age_days is not None else 7

    def get_workflow_overnight_start_hour(self) -> int:
        """Get the start hour for the overnight window (yesterday at this hour)."""
        overnight_start_hour = self.workflow_filters.get('overnight_start_hour')
        return overnight_start_hour if overnight_start_hour is not None else 18

    def get_workflow_default_name_pattern(self) -> str:
        """Get the default substring pattern for matching workflow names."""
        return self.workflow_filters.get('default_name_pattern') or 'e2e'

    def get_workflow_repo_overrides(self) -> Dict[str, List[str]]:
        """Get per-repo workflow name overrides."""
        return self.workflow_filters.get('repo_workflows') or {}

    def get_workflow_exclusions(self) -> List[str]:
        """Get workflow names to always exclude (case-insensitive substring match)."""
        return self.workflow_filters.get('exclude_workflows') or []

    def get_cve_states(self) -> List[str]:
        """Get CVE filter states."""
        return self.cve_filters.get('states') or ['open']

    def get_cve_severities(self) -> List[str]:
        """Get CVE filter severities."""
        return self.cve_filters.get('severities') or ['critical', 'high', 'medium', 'low']

    def get_issue_labels(self) -> List[str]:
        """Get issue filter labels."""
        return self.issue_filters.get('labels') or ['kind/bug']

    def get_issue_states(self) -> List[str]:
        """Get issue filter states."""
        return self.issue_filters.get('states') or ['open']

    def get_issue_max_age_days(self) -> int:
        """Get maximum age for issues in days."""
        max_age_days = self.issue_filters.get('max_age_days')
        return max_age_days if max_age_days is not None else 30

    def get_issue_max_results(self) -> int:
        """Get the maximum number of issues to fetch per repo before local filtering."""
        return self.issue_filters.get('max_results') or 500
