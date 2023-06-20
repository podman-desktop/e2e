
BUILD_DIR ?= out

# https://golang.org/cmd/link/
LDFLAGS := $(VERSION_VARIABLES) -extldflags='-static' ${GO_EXTRA_LDFLAGS}

.PHONY: clean 
clean: 
	rm -rf $(BUILD_DIR)

.PHONY: build
build:
	go test -v test/e2e/e2e_podman/suite_test.go test/e2e/e2e_podman/podman-extension_test.go -c -o $(BUILD_DIR)/linux-amd64/pd-e2e

.PHONY: cross
cross: clean $(BUILD_DIR)/windows-amd64/pd-e2e.exe

$(BUILD_DIR)/windows-amd64/pd-e2e.exe: $(SOURCES)
	CC=clang GOARCH=amd64 GOOS=windows go test -v test/e2e/e2e_podman/suite_test.go test/e2e/e2e_podman/podman-extension_test.go \
		-c -o $(BUILD_DIR)/windows-amd64//pd-e2e.exe ./cmd
    
.PHONY: vendor
vendor:
	go mod tidy
	go mod vendor