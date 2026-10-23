VERSION ?= 0.1.0
CONTAINER_MANAGER ?= podman
CODEX_CLI_VERSION ?= 0.164.0

# IMAGE_TAG is the agent image tag the *bundled task* defaults to; TKN_TAG is
# the tag of the bundle itself. They move together for a release. The nightly
# job overrides both to `nightly` so it never overwrites a released bundle and
# never ships a bundle that points at a floating image.
IMAGE_TAG ?= v${VERSION}
TKN_TAG ?= v${VERSION}

IMG ?= ghcr.io/podman-desktop/evaluation-agent:${IMAGE_TAG}
TKN_IMG ?= ghcr.io/podman-desktop/evaluation-agent-tkn:${TKN_TAG}
RUNNER_IMG ?= localhost/codex-runner:${IMAGE_TAG}

# The task runs on an amd64 cluster, so pin the build arch: CI builds on
# ubuntu-latest and gets it for free, while a build from an Apple Silicon
# laptop would otherwise push an arm64 image that the cluster cannot run.
PLATFORM ?= linux/amd64

# Escape hatch for build-time flags the environment needs, e.g.
# EXTRA_BUILD_ARGS="--dns 1.1.1.1" when the default resolver cannot reach
# registry.npmjs.org.
EXTRA_BUILD_ARGS ?=

TOOLS_DIR := tools
include tools/tools.mk

# Build the container image.
# NOTE: the build context is the repository root (..) so the Containerfile can
# COPY the skill from .skills/.
.PHONY: oci-build
oci-build:
	$(info    Building the image: $(IMG))
	$(MAKE) -C ../codex-runner oci-build IMG=$(RUNNER_IMG) \
		CONTAINER_MANAGER=$(CONTAINER_MANAGER) PLATFORM=$(PLATFORM) \
		CODEX_CLI_VERSION=$(CODEX_CLI_VERSION) EXTRA_BUILD_ARGS="$(EXTRA_BUILD_ARGS)"
	${CONTAINER_MANAGER} build -t ${IMG} -f Containerfile --ignorefile .containerignore \
		--platform ${PLATFORM} ${EXTRA_BUILD_ARGS} \
		--build-arg CODEX_RUNNER_IMAGE=${RUNNER_IMG} ..

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
