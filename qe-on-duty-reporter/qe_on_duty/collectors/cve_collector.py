"""Collector for CVE and Dependabot alerts."""

from typing import List
from qe_on_duty.gh_client import GHClient
from qe_on_duty.config import Config
from qe_on_duty.models.snapshot import CVEData


class CVECollector:
    """Collect CVE and Dependabot alerts."""

    def __init__(self, gh_client: GHClient, config: Config):
        """
        Initialize CVE collector.

        Args:
            gh_client: GitHub CLI client
            config: Configuration object
        """
        self.gh_client = gh_client
        self.config = config
        self.allowed_states = config.get_cve_states()
        self.allowed_severities = config.get_cve_severities()

    def collect(self, repositories: List[str]) -> List[CVEData]:
        """
        Collect CVE alerts from all repositories.

        Args:
            repositories: List of repository names in owner/repo format

        Returns:
            List of CVEData objects
        """
        all_cves = []
        for repo in repositories:
            try:
                cves = self._collect_from_repo(repo)
                all_cves.extend(cves)
            except Exception as e:
                # Don't print warning for common "no access" errors
                if "forbidden" not in str(e).lower() and "404" not in str(e).lower():
                    print(f"⚠️  Failed to collect CVEs from {repo}: {e}")

        return all_cves

    def _collect_from_repo(self, repo: str) -> List[CVEData]:
        """
        Collect CVE alerts from a single repository.

        Args:
            repo: Repository name in owner/repo format

        Returns:
            List of CVEData objects
        """
        # Use gh api to get Dependabot alerts (paginated - repos can have 100+ alerts)
        endpoint = f"/repos/{repo}/dependabot/alerts"
        pages = self.gh_client.api(endpoint, paginate=True)

        # On success, --paginate --slurp wraps each page's alerts in an outer
        # list; on handled errors (no access, disabled, etc.) a flat empty
        # list is returned instead. Merge all pages into one alert list.
        if pages and isinstance(pages[0], list):
            alerts = [alert for page in pages for alert in page]
        else:
            alerts = pages or []

        # gh api returns empty list if no access or no alerts
        if not alerts:
            return []

        # Filter and parse alerts
        filtered_cves = []
        for alert in alerts:
            # Filter by state
            if alert.get('state') not in self.allowed_states:
                continue

            # Filter by severity
            severity = (alert.get('security_advisory') or {}).get('severity', 'unknown')
            if severity not in self.allowed_severities:
                continue

            filtered_cves.append(self._parse_cve(alert, repo))

        return filtered_cves

    def _parse_cve(self, alert: dict, repo: str) -> CVEData:
        """
        Parse CVE alert data from gh API output to CVEData model.

        Args:
            alert: CVE alert data dictionary from gh API
            repo: Repository name

        Returns:
            CVEData object
        """
        security_advisory = alert.get('security_advisory') or {}
        vulnerability = alert.get('security_vulnerability') or {}
        package = vulnerability.get('package') or {}
        first_patched_version = vulnerability.get('first_patched_version') or {}

        return CVEData(
            repository=repo,
            alert_number=alert.get('number', 0),
            state=alert.get('state', 'unknown'),
            severity=security_advisory.get('severity', 'unknown'),
            cve_id=security_advisory.get('cve_id', security_advisory.get('ghsa_id', 'unknown')),
            package_name=package.get('name', 'unknown'),
            vulnerable_version=vulnerability.get('vulnerable_version_range', 'unknown'),
            patched_version=first_patched_version.get('identifier', 'none'),
            url=alert.get('html_url', ''),
            created_at=alert.get('created_at', ''),
            updated_at=alert.get('updated_at', '')
        )
