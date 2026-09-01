"""Parse domains.json to extract repository information."""

import json
import re
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class Repository:
    """Repository information."""
    name: str  # owner/repo format
    domain: str
    owners: List[str]
    qe_owners: List[str]


class RepositoryParser:
    """Parse domains.json file to extract repository information."""

    def __init__(self, domains_path: str):
        """
        Initialize repository parser.

        Args:
            domains_path: Path to domains.json file
        """
        self.domains_path = domains_path

    def parse(self) -> List[Repository]:
        """
        Parse domains.json and extract all repositories.

        Returns:
            List of Repository objects
        """
        with open(self.domains_path, 'r') as f:
            domains = json.load(f)

        repositories = []
        for entry in domains:
            if 'repository' in entry and entry['repository']:
                repo_name = self._parse_github_url(entry['repository'])
                if repo_name:
                    repositories.append(Repository(
                        name=repo_name,
                        domain=entry.get('domain') or '',
                        owners=entry.get('owners') or [],
                        qe_owners=entry.get('qe_owners') or []
                    ))

        return repositories

    def _parse_github_url(self, url: str) -> Optional[str]:
        """
        Convert GitHub URL to owner/repo format.

        Args:
            url: GitHub repository URL (e.g., https://github.com/owner/repo)

        Returns:
            Repository in owner/repo format, or None if parsing fails
        """
        if not url:
            return None

        # Extract owner/repo from various GitHub URL formats
        # https://github.com/owner/repo
        # https://github.com/owner/repo.git
        # git@github.com:owner/repo.git
        patterns = [
            r'https://github\.com/([^/?#\s]+/[^/?#\s]+)',
            r'git@github\.com:([^/?#\s]+/[^/?#\s]+)',
        ]

        for pattern in patterns:
            match = re.match(pattern, url)
            if match:
                repo = match.group(1)
                if repo.endswith('.git'):
                    repo = repo[:-4]
                return repo

        return None
