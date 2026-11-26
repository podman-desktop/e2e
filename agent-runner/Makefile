VERSION ?= 0.1.0
CONTAINER_MANAGER ?= podman
IMG ?= ghcr.io/podman-desktop/agent-runner:v${VERSION}
TKN_IMG ?= ghcr.io/podman-desktop/agent-runner-tkn:v${VERSION}
CODEX_CLI_VERSION ?= 0.164.0

# The cluster runs amd64. Pin it so a build on Apple Silicon does not push an
# arm64 image; override with PLATFORM=linux/arm64 for local testing.
PLATFORM ?= linux/amd64

# Escape hatch for build-time flags, e.g. EXTRA_BUILD_ARGS="--dns 1.1.1.1".
EXTRA_BUILD_ARGS ?=

TOOLS_DIR := ../tools
include ../tools/tools.mk

# Build the container image
.PHONY: oci-build
oci-build:
	$(info    Building the image: $(IMG))
	${CONTAINER_MANAGER} build -t ${IMG} -f Containerfile --platform ${PLATFORM} \
		--build-arg CODEX_CLI_VERSION=${CODEX_CLI_VERSION} ${EXTRA_BUILD_ARGS} .

# Push the container image # requires user to be logged into a registry
.PHONY: oci-push
oci-push:
	$(info    Pushing the image: $(IMG))
	${CONTAINER_MANAGER} push ${IMG}

# Create tekton task bundle
.PHONY: tkn-push
tkn-push: install-out-of-tree-tools
	$(info    Pushing the tekton task image: $(TKN_IMG))
	$(TOOLS_BINDIR)/tkn bundle push $(TKN_IMG) -f tkn/task.yaml
