VERSION ?= 0.1.0
CONTAINER_MANAGER ?= podman
IMG ?= ghcr.io/podman-desktop/evaluation-agent:v$(VERSION)
TKN_IMG ?= ghcr.io/podman-desktop/evaluation-agent-tkn:v$(VERSION)

TOOLS_DIR := ../e2e-runner/tools
include $(TOOLS_DIR)/tools.mk

.PHONY: oci-build
oci-build:
	$(info    Building the image: $(IMG))
	${CONTAINER_MANAGER} build -t ${IMG} -f Containerfile .

.PHONY: oci-push
oci-push:
	$(info    Pushing the image: $(IMG))
	${CONTAINER_MANAGER} push ${IMG}

.PHONY: tkn-push
tkn-push: install-out-of-tree-tools
	$(info    Pushing the tekton task bundle: $(TKN_IMG))
	$(TOOLS_BINDIR)/tkn bundle push $(TKN_IMG) -f tkn/task.yaml
