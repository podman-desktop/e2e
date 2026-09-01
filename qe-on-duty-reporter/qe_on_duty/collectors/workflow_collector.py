"""Collector for CI/CD workflow runs."""

from typing import List, Optional
from datetime import datetime, timedelta, timezone
from dateutil import parser as date_parser
from qe_on_duty.gh_client import GHClient
from qe_on_duty.config import Config
from qe_on_duty.models.snapshot import WorkflowData


class WorkflowCollector:
    """Collect failed CI/CD workflow runs from the overnight window."""

    def __init__(self, gh_client: GHClient, config: Config):
        self.gh_client = gh_client
        self.config = config
        self.overnight_start_hour = config.get_workflow_overnight_start_hour()
        self.default_pattern = config.get_workflow_default_name_pattern().lower()
        self.repo_overrides = config.get_workflow_repo_overrides()
        self.exclusions = [e.lower() for e in config.get_workflow_exclusions()]

    def collect(self, repositories: List[str]) -> List[WorkflowData]:
        all_workflows = []
        for repo in repositories:
            try:
                workflows = self._collect_from_repo(repo)
                all_workflows.extend(workflows)
            except Exception as e:
                print(f"⚠️  Failed to collect workflows from {repo}: {e}")

        return all_workflows

    def get_overnight_cutoff(self) -> datetime:
        """Yesterday at overnight_start_hour, expressed in the local timezone."""
        now = datetime.now().astimezone()
        yesterday = now - timedelta(days=1)
        return yesterday.replace(hour=self.overnight_start_hour, minute=0, second=0, microsecond=0)

    def _is_excluded(self, workflow_name: str) -> bool:
        """Check if a workflow name matches any exclusion pattern."""
        name_lower = workflow_name.lower()
        return any(excl in name_lower for excl in self.exclusions)

    def _matches_workflow_name(self, workflow_name: str, repo: str) -> bool:
        """Check if a workflow name matches the default pattern or repo-specific list, and is not excluded."""
        if self._is_excluded(workflow_name):
            return False
        if self.default_pattern in workflow_name.lower():
            return True
        extra = self.repo_overrides.get(repo)
        if extra and workflow_name.lower() in [e.lower() for e in extra]:
            return True
        return False

    def _collect_from_repo(self, repo: str) -> List[WorkflowData]:
        cutoff = self.get_overnight_cutoff()
        # GitHub's search qualifiers interpret an offset-less timestamp as UTC,
        # so the local cutoff must be converted before building the query.
        cutoff_utc = cutoff.astimezone(timezone.utc)
        created_filter = f">={cutoff_utc.strftime('%Y-%m-%dT%H:%M:%SZ')}"
        runs = self.gh_client.run_list(repo, limit=500, created=created_filter)

        results = []
        for run in runs:
            wf_name = run.get('workflowName', run.get('name', ''))
            if not self._matches_workflow_name(wf_name, repo):
                continue
            results.append(self._parse_workflow(run, repo))

        if results:
            return results

        return self._collect_latest_from_repo(repo)

    def _collect_latest_from_repo(self, repo: str) -> List[WorkflowData]:
        """Fallback: fetch the latest run per matching workflow when no overnight runs exist."""
        runs = self.gh_client.run_list(repo, limit=100)

        latest_per_workflow = {}
        for run in runs:
            wf_name = run.get('workflowName', run.get('name', ''))
            if not self._matches_workflow_name(wf_name, repo):
                continue
            if wf_name not in latest_per_workflow:
                latest_per_workflow[wf_name] = run

        return [self._parse_workflow(run, repo, is_fallback=True)
                for run in latest_per_workflow.values()]

    def _parse_workflow(self, run: dict, repo: str, is_fallback: bool = False) -> WorkflowData:
        return WorkflowData(
            repository=repo,
            workflow_name=run.get('workflowName', run.get('name', 'unknown')),
            workflow_id=run.get('workflowDatabaseId', 0),
            run_number=run.get('number', 0),
            run_id=run.get('databaseId', 0),
            status=run.get('status', 'unknown'),
            conclusion=run.get('conclusion', 'unknown'),
            branch=run.get('headBranch', 'unknown'),
            commit_sha=run.get('headSha', ''),
            url=run.get('url', ''),
            started_at=run.get('createdAt', ''),
            completed_at=run.get('updatedAt', ''),
            is_fallback=is_fallback,
        )
