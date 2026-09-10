VERSION ?= 0.1.0
CONTAINER_MANAGER ?= podman
CLAUDE_CODE_VERSION ?= 2.1.263

IMG ?= ghcr.io/podman-desktop/evaluation-agent:v${VERSION}
TKN_IMG ?= ghcr.io/podman-desktop/evaluation-agent-tkn:v${VERSION}

TOOLS_DIR := tools
include tools/tools.mk

# Build the container image.
# NOTE: the build context is the repository root (..) so the Containerfile can
# COPY the skill from ai-eval/skills/.
.PHONY: oci-build
oci-build:
	$(info    Building the image: $(IMG))
	${CONTAINER_MANAGER} build -t ${IMG} -f Containerfile \
		--build-arg CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} ..

# Push the container image (requires being logged into the registry).
.PHONY: oci-push
oci-push:
	$(info    Pushing the image: $(IMG))
	${CONTAINER_MANAGER} push ${IMG}

# Create the tekton task bundle.
.PHONY: tkn-push
tkn-push: install-out-of-tree-tools
	$(info    Pushing the tekton task image: $(TKN_IMG))
	$(TOOLS_BINDIR)/tkn bundle push $(TKN_IMG) -f tkn/task.yaml
