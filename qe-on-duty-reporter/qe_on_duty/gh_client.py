"""GitHub CLI wrapper for executing gh commands."""

import subprocess
import json
from typing import List, Dict, Any, Optional


class GHClient:
    """Wrapper for GitHub CLI (gh) commands."""

    def __init__(self, gh_path: str = "gh", max_retries: int = 3):
        """
        Initialize GitHub CLI client.

        Args:
            gh_path: Path to gh CLI binary (default: "gh" in PATH)
            max_retries: Maximum number of retries for failed commands
        """
        self.gh_path = gh_path
        self.max_retries = max_retries
        self._verify_gh_auth()

    def _verify_gh_auth(self):
        """Verify gh CLI is authenticated."""
        try:
            result = subprocess.run(
                [self.gh_path, "auth", "status"],
                capture_output=True,
                text=True,
                timeout=30
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("gh auth status timed out after 30s")

        if result.returncode != 0:
            raise RuntimeError(
                "gh CLI not authenticated. Run: gh auth login\n"
                f"Error: {result.stderr}"
            )

    def run_command(self, args: List[str], retry_count: int = 0) -> Any:
        """
        Execute gh command and return parsed output.

        Args:
            args: Command arguments (e.g., ['pr', 'list', '--repo', 'owner/repo', '--json', 'number,title'])
            retry_count: Current retry attempt

        Returns:
            Parsed JSON output or empty list on error

        Raises:
            RuntimeError: If command fails after max retries
        """
        try:
            result = subprocess.run(
                [self.gh_path] + args,
                capture_output=True,
                text=True,
                timeout=60  # 60 second timeout per command
            )

            if result.returncode == 0:
                # Success - parse and return JSON
                if result.stdout.strip():
                    return json.loads(result.stdout)
                return []

            # Handle specific error cases
            stderr_lower = result.stderr.lower()

            # Repository not found or no access - return empty list (not an error)
            if any(phrase in stderr_lower for phrase in [
                "not found",
                "could not resolve to a repository",
                "no access",
                "resource protected"
            ]):
                return []

            # Dependabot alerts not available - return empty list (not an error)
            if "dependabot" in stderr_lower and (
                "forbidden" in stderr_lower
                or "404" in stderr_lower
                or "403" in stderr_lower
                or "disabled" in stderr_lower
            ):
                return []

            # No workflow runs - return empty list (valid state)
            if "no workflow runs found" in stderr_lower:
                return []

            # Rate limiting - retry
            if "rate limit" in stderr_lower or "api rate limit" in stderr_lower:
                if retry_count < self.max_retries:
                    print(f"⏱️  Rate limited. Waiting 60s before retry {retry_count + 1}/{self.max_retries}...")
                    import time
                    time.sleep(60)
                    return self.run_command(args, retry_count + 1)
                raise RuntimeError(f"Rate limited after {self.max_retries} retries")

            # Other errors - raise exception
            raise RuntimeError(
                f"gh command failed (exit code {result.returncode}): {result.stderr}"
            )

        except subprocess.TimeoutExpired:
            if retry_count < self.max_retries:
                print(f"⏱️  Command timed out. Retrying {retry_count + 1}/{self.max_retries}...")
                return self.run_command(args, retry_count + 1)
            raise RuntimeError(f"Command timed out after {self.max_retries} retries")

        except json.JSONDecodeError as e:
            raise RuntimeError(f"Failed to parse gh command output as JSON: {e}")

    def get_current_user(self) -> str:
        """Get the GitHub username of the currently authenticated user."""
        result = subprocess.run(
            [self.gh_path, "api", "user", "--jq", ".login"],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(f"Failed to get current user: {result.stderr}")
        return result.stdout.strip()

    def pr_list(self, repo: str, state: str = "open", limit: int = 100) -> List[Dict[str, Any]]:
        """
        List pull requests for a repository.

        Args:
            repo: Repository in owner/repo format
            state: PR state (open, closed, all)
            limit: Maximum number of PRs to fetch

        Returns:
            List of PR data dictionaries
        """
        return self.run_command([
            "pr", "list",
            "--repo", repo,
            "--state", state,
            "--limit", str(limit),
            "--json", "number,title,url,author,labels,assignees,reviewRequests,createdAt,updatedAt,state,isDraft"
        ])

    def run_list(self, repo: str, limit: int = 100, status: Optional[str] = None,
                 created: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        List workflow runs for a repository.

        Args:
            repo: Repository in owner/repo format
            limit: Maximum number of runs to fetch
            status: Filter by status/conclusion (e.g., 'failure', 'success', 'completed')
            created: Date filter (e.g., '>=2026-07-12')

        Returns:
            List of workflow run data dictionaries
        """
        args = [
            "run", "list",
            "--repo", repo,
            "--limit", str(limit),
            "--json", "databaseId,number,workflowDatabaseId,name,status,conclusion,workflowName,headBranch,headSha,createdAt,updatedAt,url"
        ]
        if status:
            args.extend(["--status", status])
        if created:
            args.extend(["--created", created])
        return self.run_command(args)

    def issue_list(self, repo: str, labels: Optional[List[str]] = None, state: str = "open", limit: int = 100) -> List[Dict[str, Any]]:
        """
        List issues for a repository.

        Args:
            repo: Repository in owner/repo format
            labels: Filter by labels
            state: Issue state (open, closed, all)
            limit: Maximum number of issues to fetch

        Returns:
            List of issue data dictionaries
        """
        args = [
            "issue", "list",
            "--repo", repo,
            "--state", state,
            "--limit", str(limit),
            "--json", "number,title,url,author,labels,assignees,state,createdAt,updatedAt,comments"
        ]

        if labels:
            for label in labels:
                args.extend(["--label", label])

        return self.run_command(args)

    def api(self, endpoint: str, paginate: bool = False) -> Any:
        """
        Execute raw GitHub API request using gh api.

        Args:
            endpoint: API endpoint (e.g., /repos/owner/repo/dependabot/alerts)
            paginate: If True, fetch all pages and return them as a list of
                per-page results (each page's JSON body as one list element).
                GitHub's REST list endpoints default to a small page size, so
                this is required to get complete results for repos with many
                items (e.g. 100+ Dependabot alerts).

        Returns:
            Parsed JSON response. When paginate=True on success, a list of
            pages (each page itself a list); on handled errors (no access,
            disabled, etc.) a flat empty list is returned instead.
        """
        args = ["api", endpoint]
        if paginate:
            args.extend(["--paginate", "--slurp"])
        return self.run_command(args)
