VERSION ?= 0.1.0
CONTAINER_MANAGER ?= podman
CLAUDE_CODE_VERSION ?= 2.1.263

# IMAGE_TAG is the agent image tag the *bundled task* defaults to; TKN_TAG is
# the tag of the bundle itself. They move together for a release. The nightly
# job overrides both to `nightly` so it never overwrites a released bundle and
# never ships a bundle that points at a floating image.
IMAGE_TAG ?= v${VERSION}
TKN_TAG ?= v${VERSION}

IMG ?= ghcr.io/podman-desktop/evaluation-agent:${IMAGE_TAG}
TKN_IMG ?= ghcr.io/podman-desktop/evaluation-agent-tkn:${TKN_TAG}

TOOLS_DIR := tools
include tools/tools.mk

# Build the container image.
# NOTE: the build context is the repository root (..) so the Containerfile can
# COPY the skill from .skills/.
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
# The task's `image-version` default is rewritten to IMAGE_TAG so a versioned
# bundle pins the matching agent image instead of floating on `nightly`.
.PHONY: tkn-push
tkn-push: install-out-of-tree-tools
	$(info    Pushing the tekton task image: $(TKN_IMG) (image-version=$(IMAGE_TAG)))
	@mkdir -p out
	@sed -e "s|^\( *default: *\)'nightly'|\1'$(IMAGE_TAG)'|" tkn/task.yaml >out/task.yaml
	@grep -q "default: '$(IMAGE_TAG)'" out/task.yaml \
		|| { echo "ERROR: failed to pin image-version in tkn/task.yaml" >&2; exit 1; }
	$(TOOLS_BINDIR)/tkn bundle push $(TKN_IMG) -f out/task.yaml
