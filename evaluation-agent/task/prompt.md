Use the $evaluate-e2e-results skill to evaluate the Playwright results in the read-only directory {{INPUT_DIR}}.

Set `export RESULTS_DIR={{INPUT_DIR}}` before running the skill's commands. Do not modify that directory; use /tmp for scratch files.

Return the complete evaluation as JSON matching the supplied output schema:
- use null for platform fields the artifacts do not support;
- use null for skipped_analysis when no tests were skipped;
- use false and 0 for truncated and truncated_count when there are 20 failures or fewer.

Reporting is handled by the caller; do not send notifications.
