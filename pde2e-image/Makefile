VERSION ?= 0.0.1
CONTAINER_MANAGER ?= podman
IMG ?= quay.io/odockal/pde2e-test:v${VERSION} # temporary image location
# TKN_IMG ?= quay.io/odockal/pde2e-test-tkn:v${VERSION}

# TOOLS_DIR := tools
# include tools/tools.mk

# Build the container image
.PHONY: oci-build
oci-build:
	$(info    Building the image: $(IMG)-$(OS))
	${CONTAINER_MANAGER} build -t ${IMG}-${OS} -f Containerfile --build-arg=OS=${OS} .

# Build the container image # requires user to be logged into a registry
.PHONY: oci-push
oci-push: 
	$(info    Pushing the image: $(IMG)-$(OS))
	${CONTAINER_MANAGER} push ${IMG}-${OS}

# Create tekton task bundle
# .PHONY: tkn-push
# tkn-push: install-out-of-tree-tools
# 	$(info    Pushing the tekton task image: $(TKN_IMG))
# 	$(TOOLS_BINDIR)/tkn bundle push $(TKN_IMG) -f tkn/task.yaml
