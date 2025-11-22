# pde2e-test
Podman Desktop E2E playwright test execution image

## Usage, building and pushing the image
The repository structure:
* `lib` folder contains platform specific (`windows/runner.ps1`, `darwin/runner.sh`) execution scripts that are shipped using `deliverest` image into a target host machine
* `common` folder contains platform specific (`common/windows/common.ps1`, `common/linux/common.sh`, `common/darwin/common.sh -> ../linux/common.sh`) libraries and functions shared withing execution scripts for better maintainability and readability
* `Containerfile` is a build image configuration file that accepts `--build-args`: `OS` to determine the platform for which the particulat image is being built
* `Makefile` build instructions for building the image using `Containerfile` and pushing it into image registry
* `builder.sh` script that executes makefile for Windows and Mac OS platforms

In order to push an image, user needs to be logged in before executing building scipts.

## Running the image

### On Windows

```sh
podman run --rm -d --name pde2e-test-run \
          -e TARGET_HOST=$(cat host) \
          -e TARGET_HOST_USERNAME=$(cat username) \
          -e TARGET_HOST_KEY_PATH=/data/id_rsa \
          -e TARGET_FOLDER=pd-e2e \
          -e TARGET_RESULTS=results \
          -e OUTPUT_FOLDER=/data \
          -e DEBUG=true \
          -v $PWD:/data:z \
          quay.io/odockal/pde2e-test:v0.0.1-windows  \
            pd-e2e/runner.ps1 \
            -targetFolder pd-e2e \
            -resultsFolder results
podman logs -f pde2e-test-run
```

### On Mac OS

```sh
podman run --rm -d --name pde2e-test-run \
          -e TARGET_HOST=$(cat host) \
          -e TARGET_HOST_USERNAME=$(cat username) \
          -e TARGET_HOST_KEY_PATH=/data/id_rsa \
          -e TARGET_FOLDER=pd-e2e \
          -e TARGET_RESULTS=results \
          -e OUTPUT_FOLDER=/data \
          -e DEBUG=true \
          -v $PWD:/data:z \
          quay.io/odockal/pde2e-test:v0.0.1-darwin  \
            pd-e2e/runner.sh \
            --targetFolder pd-e2e \
            --resultsFolder results

podman logs -f pde2e-test-run
```

### On Linux

```sh
podman run --rm -d --name pde2e-test-run \
          -e TARGET_HOST=$(cat host) \
          -e TARGET_HOST_USERNAME=$(cat username) \
          -e TARGET_HOST_KEY_PATH=/data/id_rsa \
          -e TARGET_FOLDER=pd-e2e \
          -e TARGET_RESULTS=results \
          -e OUTPUT_FOLDER=/data \
          -e DEBUG=true \
          -v $PWD:/data:z \
          quay.io/odockal/pde2e-test:v0.0.1-linux  \
            pd-e2e/runner.sh \
            --targetFolder pd-e2e \
            --resultsFolder results

podman logs -f pde2e-test-run
```