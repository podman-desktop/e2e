# pde2e-runner
Podman Desktop E2E playwright test execution image

## Usage, building and pushing the image
The repository structure:
* `lib` folder contains platform specific (`windows/runner.ps1`, `darwin/runner.sh`) execution scripts that are shipped using `deliverest` image into a target host machine
* `Containerfile` is a build image configuration file that accepts `--build-args`: `OS` to determine the platform for which the particulat image is being built
* `Makefile` build instructions for building the image using `Containerfile` and pushing it into image registry
* `builder.sh` script that executes makefile for Windows and Mac OS platforms

In order to push an image, user needs to be logged in before executing building scipts.

## Running the image

```sh
# Running the image on windows
podman run --rm -d --name pde2e-runner-run \
          -e TARGET_HOST=$(cat host) \
          -e TARGET_HOST_USERNAME=$(cat username) \
          -e TARGET_HOST_KEY_PATH=/data/id_rsa \
          -e TARGET_FOLDER=pd-e2e-runner \
          -e TARGET_RESULTS=results \
          -e OUTPUT_FOLDER=/data \
          -e DEBUG=true \
          -v $PWD:/data:z \
          -v $PWD/secrets.txt:/opt/pde2e-runner/secrets.txt:z \
          quay.io/odockal/pde2e-runner:v0.0.3-windows  \
            pd-e2e-runner/runner.ps1 \
            -targetFolder pd-e2e-runner \
            -resultsFolder results \
            -fork containers \
            -branch main
            -npmTarget "test:e2e:smoke" \ 
            -podmanPath "C:\tools\podman\podman-4.9.0\bin" \
            -initialize 0 \
            -rootful 1 \
            -start 1 \
            -envVars 'TEST_MACHINE=true,MY_ENV_VAR="some string",ENV_NUMBER=3' \
            -secretFile secrets.txt \
            -scriptPaths 'podman_rootless.ps1,setup_compose.ps1' \
            -runAsAdmin 1

# Running the image on Mac OS
podman run --rm -d --name pde2e-runner-run \
          -e TARGET_HOST=$(cat host) \
          -e TARGET_HOST_USERNAME=$(cat username) \
          -e TARGET_HOST_KEY_PATH=/data/id_rsa \
          -e TARGET_FOLDER=pd-e2e \
          -e TARGET_RESULTS=results \
          -e OUTPUT_FOLDER=/data \
          -e DEBUG=true \
          -v $PWD:/data:z \
          -v $PWD/secrets.txt:/opt/pde2e-runner/secrets.txt:z \
          quay.io/odockal/pde2e-runner:v0.0.3-darwin  \
            pd-e2e/runner.sh \
            --targetFolder pd-e2e \
            --resultsFolder results \
            --fork podman-desktop \
            --branch main \
            --secretFile secrets.txt \
            --npmTarget "test:e2e:extension" \
            --initialize 1 \
            --rootful 1 \
            --start 0 \
            --extTests 0 \
            --extRepo podman-desktop-sandbox-ext \
            --extFork redhat-developer \
            --extBranch main
            #--pdUrl "https://github.com/podman-desktop/testing-prereleases/releases/download/v1.20.0-202506060133-deec1eda430/podman-desktop-1.20.0-202506060133-deec1eda430-arm64.dmg"

podman logs -f pde2e-runner-run
```

## Get the image logs
```sh
podman logs -f pde2e-podman-run
```