VERSION ?= 0.2.0
CONTAINER_MANAGER ?= podman
IMG ?= ghcr.io/podman-desktop/evaluation-agent:v${VERSION}
TKN_IMG ?= ghcr.io/podman-desktop/evaluation-agent-tkn:v${VERSION}

# The base this bundle is built on. Bump it deliberately: the base carries the
# security policy.
AGENT_RUNNER_IMAGE ?= ghcr.io/podman-desktop/agent-runner:v0.1.0

# The cluster runs amd64; override with PLATFORM=linux/arm64 for local testing.
PLATFORM ?= linux/amd64
EXTRA_BUILD_ARGS ?=

TOOLS_DIR := ../tools
include ../tools/tools.mk

# Build the container image.
# The build context is the repository root (..) so the Containerfile can COPY
# the skill from .skills/.
.PHONY: oci-build
oci-build:
	$(info    Building the image: $(IMG) on $(AGENT_RUNNER_IMAGE))
	${CONTAINER_MANAGER} build -t ${IMG} -f Containerfile --ignorefile .containerignore \
		--platform ${PLATFORM} --build-arg AGENT_RUNNER_IMAGE=${AGENT_RUNNER_IMAGE} \
		${EXTRA_BUILD_ARGS} ..

# Build the agent-runner base locally first, then this bundle on top of it.
.PHONY: oci-build-all
oci-build-all:
	$(MAKE) -C ../agent-runner oci-build IMG=$(AGENT_RUNNER_IMAGE) \
		CONTAINER_MANAGER=$(CONTAINER_MANAGER) PLATFORM=$(PLATFORM) \
		EXTRA_BUILD_ARGS="$(EXTRA_BUILD_ARGS)"
	$(MAKE) oci-build

# Push the container image # requires user to be logged into a registry
.PHONY: oci-push
oci-push:
	$(info    Pushing the image: $(IMG))
	${CONTAINER_MANAGER} push ${IMG}

# Create tekton task bundle (the agent itself runs with agent-runner's run-agent task)
.PHONY: tkn-push
tkn-push: install-out-of-tree-tools
	$(info    Pushing the tekton task image: $(TKN_IMG))
	$(TOOLS_BINDIR)/tkn bundle push $(TKN_IMG) -f tkn/slack-task.yaml
