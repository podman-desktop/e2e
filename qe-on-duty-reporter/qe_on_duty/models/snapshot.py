"""Data models for QE on-duty snapshots and reports."""

from dataclasses import dataclass, asdict, field, fields
from typing import List, Optional
from datetime import datetime
import json


def _known_fields(dataclass_cls, data: dict) -> dict:
    """Drop any keys not declared on dataclass_cls, so loading stays forward/backward compatible."""
    field_names = {f.name for f in fields(dataclass_cls)}
    return {k: v for k, v in data.items() if k in field_names}


@dataclass
class PRData:
    """Pull request data model."""
    repository: str
    number: int
    title: str
    url: str
    author: str
    labels: List[str]
    assignees: List[str]
    created_at: str
    updated_at: str
    state: str
    draft: bool
    requested_reviewers: List[str] = field(default_factory=list)


@dataclass
class WorkflowData:
    """Workflow run data model."""
    repository: str
    workflow_name: str
    workflow_id: int
    run_number: int
    run_id: int
    status: str  # completed, in_progress, queued
    conclusion: str  # success, failure, cancelled, skipped
    branch: str
    commit_sha: str
    url: str
    started_at: str
    completed_at: str
    is_fallback: bool = False  # True when outside the overnight window (latest run used as fallback)


@dataclass
class CVEData:
    """CVE/Dependabot alert data model."""
    repository: str
    alert_number: int
    state: str  # open, dismissed, fixed
    severity: str  # critical, high, medium, low
    cve_id: str
    package_name: str
    vulnerable_version: str
    patched_version: str
    url: str
    created_at: str
    updated_at: str


@dataclass
class IssueData:
    """Issue data model."""
    repository: str
    number: int
    title: str
    url: str
    author: str
    labels: List[str]
    assignees: List[str]
    state: str
    created_at: str
    updated_at: str
    comments_count: int


@dataclass
class SummaryData:
    """Summary statistics for a snapshot."""
    total_prs_needing_qe: int
    total_workflow_runs: int
    failed_workflow_runs: int
    critical_cves: int
    high_cves: int
    total_open_bugs: int


@dataclass
class DailySnapshot:
    """Complete snapshot of QE on-duty data at a specific point in time."""
    date: str  # ISO format: YYYY-MM-DD
    time: str  # HH:MM format
    timestamp: str  # ISO format with timezone
    prs: List[PRData] = field(default_factory=list)
    workflows: List[WorkflowData] = field(default_factory=list)
    cves: List[CVEData] = field(default_factory=list)
    issues: List[IssueData] = field(default_factory=list)
    summary: Optional[SummaryData] = None
    overnight_cutoff: str = ''  # ISO timestamp: start of the overnight window used to collect workflows
    overnight_window_end: str = ''  # ISO timestamp: end of the overnight window (collection time)

    def to_json(self) -> str:
        """Serialize to JSON string."""
        return json.dumps(asdict(self), indent=2)

    def save(self, filepath: str):
        """Save snapshot to JSON file."""
        with open(filepath, 'w') as f:
            f.write(self.to_json())

    @classmethod
    def load(cls, filepath: str) -> 'DailySnapshot':
        """Load snapshot from JSON file."""
        with open(filepath, 'r') as f:
            data = json.load(f)
            # Convert nested dicts back to dataclasses, ignoring any unknown
            # keys so snapshots from older/newer script versions still load.
            data['prs'] = [PRData(**_known_fields(PRData, pr)) for pr in data.get('prs') or []]
            data['workflows'] = [WorkflowData(**_known_fields(WorkflowData, wf)) for wf in data.get('workflows') or []]
            data['cves'] = [CVEData(**_known_fields(CVEData, cve)) for cve in data.get('cves') or []]
            data['issues'] = [IssueData(**_known_fields(IssueData, issue)) for issue in data.get('issues') or []]
            if data.get('summary'):
                data['summary'] = SummaryData(**_known_fields(SummaryData, data['summary']))
            return cls(**_known_fields(cls, data))
