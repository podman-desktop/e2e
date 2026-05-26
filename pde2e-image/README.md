# pde2e-image

Unified Podman Desktop E2E test execution image with integrated Podman installation support.

## Purpose

This image provides a unified workflow for Podman Desktop E2E testing:
- **Automated Podman Installation**: Downloads and installs Podman on target Windows/macOS/RHEL hosts if not already present
- **E2E Test Execution**: Runs Podman Desktop Playwright E2E tests on remote target machines
- **Multi-platform Support**: Supports macOS (darwin), Windows, and Linux (RHEL) platforms

The runner scripts automatically handle Podman installation as an integrated step, simplifying the testing pipeline into a single entry point per platform.

## Repository Structure

```
pde2e-image/
├── lib/
│   ├── darwin/
│   │   └── runner.sh              # macOS test runner with integrated Podman installation
│   ├── windows/
│   │   ├── runner.ps1             # Windows test runner with integrated Podman installation
│   │   └── scripts/               # Windows-specific utility scripts
│   ├── rhel/
│   │   ├── runner.sh              # RHEL test runner with integrated Podman installation
│   │   └── setup_display.sh       # Headless display setup for RHEL
│   └── unix/
│       └── scripts/                # Cross-platform utility scripts (darwin, rhel, linux)
│           ├── install_docker_compose.sh
│           ├── install_kind.sh
│           ├── install_kubectl.sh
│           └── install_minikube.sh
├── common/
│   ├── unix/
│   │   └── common.sh               # Shared bash utilities (darwin, rhel, linux)
│   └── windows/
│       └── common.ps1              # Shared PowerShell utilities
├── tools/
│   ├── bin/                        # Downloaded tools (gitignored)
│   └── tools.mk                    # Makefile for Tekton CLI
├── tkn/
│   ├── task.yaml                   # Unified Tekton task (all platforms)
│   └── task-rhel-display.yaml      # RHEL display setup task
├── Containerfile                   # Multi-stage build configuration
├── Makefile                        # Build and push targets
├── builder.sh                      # Build script for all platforms
├── README.md                       # This file
└── LICENSE
```

## Key Features

### Integrated Workflow

The runner scripts (`runner.sh` / `runner.ps1`) now automatically handle Podman installation:

1. **If `podmanPath` is provided**: Uses existing Podman installation
2. **If `podman` command exists**: Uses system Podman
3. **If `podmanDownloadUrl` is provided**: Downloads and installs Podman automatically
4. **Otherwise**: Proceeds with existing Podman or fails if not found

### Platform Support

- **macOS (darwin)**: Supports ZIP and PKG installers, libkrun/applehv providers
- **Windows**: Supports ZIP, EXE, and MSI installers, WSL2/HyperV providers
- **Linux (RHEL)**: Supports dnf-based installation and ZIP archives, rootful/rootless modes

## Building and Pushing

### Prerequisites

- Podman or Docker
- Logged into container registry (`podman login quay.io`)
- Tekton CLI (optional, for pushing task bundles)

### Build Commands

```bash
# Build for specific platform
OS=darwin make oci-build
OS=windows make oci-build
OS=rhel make oci-build

# Build for all platforms
OS=darwin make oci-build && OS=windows make oci-build && OS=rhel make oci-build

# Push to registry
OS=darwin make oci-push
OS=windows make oci-push
OS=rhel make oci-push

# Build and push Tekton task bundle
make tkn-push

# All-in-one: build and push everything
./builder.sh
```

## Running the Image

### macOS Example with Podman Installation

```sh
podman run --rm -d --name pde2e-image-run \
  -e TARGET_HOST=$(cat host-mac) \
  -e TARGET_HOST_USERNAME=$(cat username-mac) \
  -e TARGET_HOST_KEY_PATH=/data/id_rsa-mac \
  -e TARGET_FOLDER=pd-e2e \
  -e TARGET_RESULTS=results \
  -e OUTPUT_FOLDER=/data \
  -e DEBUG=true \
  -v $PWD:/data:z \
  -v $PWD/secrets.txt:/opt/pde2e-image/secrets.txt:z \
  quay.io/odockal/pde2e-image:v0.1.0-darwin \
    pd-e2e/runner.sh \
    --targetFolder pd-e2e \
    --resultsFolder results \
    --fork podman-desktop \
    --branch main \
    --podmanDownloadUrl "https://github.com/containers/podman/releases/download/v5.8.2/podman-remote-release-darwin_arm64.zip" \
    --initialize 1 \
    --rootful 1 \
    --start 1 \
    --npmTarget "test:e2e:smoke:run" \
    --podmanProvider "libkrun"
```

### macOS Example without Podman, with remote Podman Desktop, using CDP

```sh
podman run --rm -d --name pde2e-image-run \
  -e TARGET_HOST=$(cat host-mac) \
  -e TARGET_HOST_USERNAME=$(cat username-mac) \
  -e TARGET_HOST_KEY_PATH=/data/id_rsa-mac \
  -e TARGET_FOLDER=pd-e2e \
  -e TARGET_RESULTS=results \
  -e OUTPUT_FOLDER=/data \
  -e DEBUG=true \
  -v $PWD:/data:z \
  quay.io/odockal/pde2e-image:v0.1.0-darwin \
    pd-e2e/runner.sh \
    --targetFolder pd-e2e \
    --resultsFolder results \
    --fork odockal \
    --branch dashboard-test \
    --pdUrl https://github.com/podman-desktop/podman-desktop/releases/download/v1.27.2/podman-desktop-1.27.2-arm64.dmg \
    --envVars DEBUGGING_PORT=9222 \
    --podmanDownloadUrl "https://github.com/containers/podman/releases/download/v5.8.2/podman-remote-release-darwin_arm64.zip" \
    --initialize 1 \
    --rootful 1 \
    --start 1 \
    --npmTarget "test:e2e:smoke:run" \
    --podmanProvider "libkrun"
  podman logs -f pde2e-image-run
```

### Windows Example with Podman Installation

```sh
podman run --rm -d --name pde2e-image-run \
  -e TARGET_HOST=$(cat host-win) \
  -e TARGET_HOST_USERNAME=$(cat username-win) \
  -e TARGET_HOST_KEY_PATH=/data/id_rsa-win \
  -e TARGET_FOLDER=pd-e2e \
  -e TARGET_RESULTS=results \
  -e OUTPUT_FOLDER=/data \
  -e DEBUG=true \
  -v $PWD:/data:z \
  -v $PWD/secrets.txt:/opt/pde2e-image/secrets.txt:z \
  quay.io/odockal/pde2e-image:v0.1.0-windows \
    pd-e2e/runner.ps1 \
    -targetFolder pd-e2e \
    -resultsFolder results \
    -fork odockal \
    -branch dashboard-test \
    -pdUrl https://github.com/podman-desktop/podman-desktop/releases/download/v1.27.2/podman-desktop-1.27.2-setup-x64.exe \
    -podmanDownloadUrl "https://github.com/containers/podman/releases/download/v5.8.2/podman-installer-windows-amd64.msi" \
    -initialize 1 \
    -rootful 1 \
    -start 1 \
    -npmTarget "test:e2e:smoke:run" \
    -installWSL 0 \
    -envVars DEBUGGING_PORT=9222 \
    -podmanProvider "wsl"
```

### Windows Example without Podman Installation

```sh
podman run --rm -d --name pde2e-image-run \
  -e TARGET_HOST=$(cat host-win) \
  -e TARGET_HOST_USERNAME=$(cat username-win) \
  -e TARGET_HOST_KEY_PATH=/data/id_rsa-win \
  -e TARGET_FOLDER=pd-e2e \
  -e TARGET_RESULTS=results \
  -e OUTPUT_FOLDER=/data \
  -e DEBUG=true \
  -v $PWD:/data:z \
  quay.io/odockal/pde2e-image:v0.1.0-windows \
    pd-e2e/runner.ps1 \
    -targetFolder pd-e2e \
    -resultsFolder results \
    -fork odockal \
    -branch dashboard-test \
    -pdUrl https://github.com/podman-desktop/podman-desktop/releases/download/v1.27.2/podman-desktop-1.27.2-setup-x64.exe \
    -npmTarget "test:e2e:smoke:run" \
    -installWSL 0 \
    -envVars DEBUGGING_PORT=9222 \
    -podmanProvider "wsl"
  podman logs -f pde2e-image-run
```

### Extension Testing Example (without Podman installation)

```sh
podman run --rm -d --name pde2e-image-run \
  -e TARGET_HOST=$(cat host) \
  -e TARGET_HOST_USERNAME=$(cat username) \
  -e TARGET_HOST_KEY_PATH=/data/id_rsa \
  -e TARGET_FOLDER=pd-e2e \
  -e TARGET_RESULTS=results \
  -e OUTPUT_FOLDER=/data \
  -e DEBUG=true \
  -v $PWD:/data:z \
  quay.io/odockal/pde2e-image:v0.1.0-darwin \
    pd-e2e/runner.sh \
    --targetFolder pd-e2e \
    --resultsFolder results \
    --fork podman-desktop \
    --branch main \
    --podmanPath "/opt/podman/bin" \
    --initialize 0 \
    --rootful 1 \
    --start 0 \
    --extTests 1 \
    --extRepo podman-desktop-sandbox-ext \
    --extFork redhat-developer \
    --extBranch main \
    --pdUrl "https://github.com/podman-desktop/testing-prereleases/releases/download/v1.20.0-202506060133-deec1eda430/podman-desktop-1.20.0-202506060133-deec1eda430-arm64.dmg"
```

## Runner Script Parameters

### macOS (runner.sh)

| Parameter | Description | Default | Example |
|-----------|-------------|---------|---------|
| `--targetFolder` | Working directory on target host | - | `pd-e2e` |
| `--resultsFolder` | Results subdirectory | `results` | `results` |
| `--fork` | Podman Desktop repo fork | `podman-desktop` | `containers` |
| `--branch` | Repository branch/tag | `main` | `v1.20.0` |
| `--pdUrl` | Podman Desktop download URL | - | `https://...dmg` |
| `--pdPath` | Existing PD binary path | - | `/Applications/Podman Desktop.app` |
| `--podmanPath` | Existing Podman binary path | - | `/opt/podman/bin` |
| `--podmanDownloadUrl` | Podman installer URL | - | `https://...zip` |
| `--initialize` | Initialize podman machine | `0` | `1` |
| `--start` | Start podman machine | `0` | `1` |
| `--rootful` | Rootful podman machine | `0` | `1` |
| `--podmanProvider` | Virtualization provider | - | `libkrun`, `applehv` |
| `--npmTarget` | npm test script | `test:e2e` | `test:e2e:smoke` |
| `--extTests` | Run extension tests | `0` | `1` |
| `--extRepo` | Extension repository | - | `podman-desktop-ai-lab` |
| `--extFork` | Extension fork | - | `redhat-developer` |
| `--extBranch` | Extension branch | - | `main` |
| `--envVars` | Environment variables | - | `VAR=val,VAR2=val2` |
| `--secretFile` | Secrets file name | - | `secrets.txt` |
| `--scriptPaths` | Custom scripts to run | - | `install_kind.sh` |
| `--saveTraces` | Save Playwright traces | `1` | `0` |
| `--cleanMachine` | Reset machine after tests | `1` | `0` |

### Windows (runner.ps1)

Parameters are similar to macOS with PowerShell syntax (`-parameter` instead of `--parameter`).

Additional Windows-specific parameter:
- `-installWSL`: Install WSL2 (default: `0`)

## Tekton Task Usage

The unified Tekton task combines all parameters from both original tasks:

```yaml
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  name: pde2e-test-with-podman-setup
spec:
  taskRef:
    name: pde2e-image
  workspaces:
    - name: pipelines-data
      persistentVolumeClaim:
        claimName: my-pvc
  params:
    - name: host
      value: "192.168.1.100"
    - name: username
      value: "testuser"
    - name: key
      value: "id_rsa"
    - name: os
      value: "darwin"
    - name: podman-download-url
      value: "https://github.com/containers/podman/releases/download/v5.2.5/podman-remote-release-darwin_arm64.zip"
    - name: podman-initialize
      value: "1"
    - name: podman-rootful
      value: "1"
    - name: podman-start
      value: "1"
    - name: npm-target
      value: "test:e2e:smoke"
```

## View Logs

```sh
podman logs -f pde2e-image-run
```

## Migration Notes

### From pde2e-runner

- Image name changed: `quay.io/odockal/pde2e-runner` → `quay.io/odockal/pde2e-image`
- New parameters: `--podmanDownloadUrl`
- Podman installation now automatic when download URL provided
- Tekton task name changed: `pde2e-runner` → `pde2e-image`

### From pde2e-podman

- Image name changed: `quay.io/odockal/pde2e-podman` → `quay.io/odockal/pde2e-image`
- Podman installation is now integrated into the runner scripts
- Single entry point per platform: `runner.sh` (macOS) or `runner.ps1` (Windows)
- All test execution parameters now available

## Troubleshooting

### Podman Installation Fails

- Check `podman-location.log` in results folder for installation path
- Verify download URL is accessible and correct for target architecture
- For Windows MSI: ensure user has necessary permissions
- For macOS PKG: may require sudo password (use `userpassword` parameter)

### Tests Fail to Run

- Verify Podman machine is initialized: `podman machine ls`
- Check test output in results folder
- Review Playwright traces if `--saveTraces 1`

### HyperV Issues (Windows)

- Ensure HyperV is enabled in Windows Features
- Check Windows Defender firewall rules for Podman
- Verify user has administrator privileges if required

## Version

Current version: `0.0.1`

Based on:
- `pde2e-runner` v0.0.3
- `pde2e-podman` v0.0.3

## License

See [LICENSE](LICENSE) file.
