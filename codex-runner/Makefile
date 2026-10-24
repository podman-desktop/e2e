VERSION ?= 0.1.0
CONTAINER_MANAGER ?= podman
IMG ?= ghcr.io/podman-desktop/codex-runner:v$(VERSION)
PLATFORM ?= linux/amd64
CODEX_CLI_VERSION ?= 0.164.0
EXTRA_BUILD_ARGS ?=

.PHONY: oci-build oci-push
oci-build:
	$(CONTAINER_MANAGER) build --platform $(PLATFORM) \
		--build-arg CODEX_CLI_VERSION=$(CODEX_CLI_VERSION) $(EXTRA_BUILD_ARGS) \
		-t $(IMG) -f Containerfile .

# Explicitly invoked only; building never pushes an image.
oci-push:
	$(CONTAINER_MANAGER) push $(IMG)
