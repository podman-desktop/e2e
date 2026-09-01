# Podman Desktop QE on-duty rotation responsibilities

Why? Having a rotating schedule for these responsibilities ensures a balanced distribution of tasks among the QE team, promoting skill development, team collaboration and team member exposure to a broader engineering team.

## Possible actions to take
* Monitor PRs incoming and outstanding that could require our review
* Verification of the PRs
* Look for changes that could break tests, can apply qe/review label
* Especially monitor qe/testing-required label on PRs
* Monitor also PRs with assignee group: qe-reviewers
* Issues Management and creation
* Help reproducing bugs
* Verification of the patches
* Filling issues for extending tests related to changes in application, for example these with qe/review label

## Podman Desktop QE Infrastructure Stability:
Monitor test results and maintain CI/CD systems and infrastructure

Main repositories to look at for the GH actions workflow run results
* https://github.com/podman-desktop/podman-desktop
* https://github.com/podman-desktop/e2e

Gathering the test results from the extensions GH Actions CI:
* go through the list of extensions on domains.json file: https://github.com/containers/podman-desktop-internal/blob/main/domains.json 

Github available and required items for the summary:

* Test results from podman-desktop repo
* test results from e2e repository
* possibly monitor e2e test results from the extensions
* PR reviews with qe/testing-required
* PR reviews with assignee: qe-reviewers
* CVEs opened on every repository we maintain (see domains)
