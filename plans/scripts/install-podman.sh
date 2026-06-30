#!/bin/bash
set -eu

# Uninstall a preinstalled Podman version to ensure the desired version will be installed.
sudo dnf remove -y podman

# Construct the download URL for the specific Podman version.
COMPOSE_VERSION="fc$(echo "$COMPOSE" | cut -d'-' -f2)"

# Install Podman based on the requested version:
#   - "nightly": latest nightly build from rhcontainerbot/podman-next COPR repository
#   - "latest": latest stable release from official Fedora repositories
#   - other: install the exact RPM from Fedora Koji
if [[ "$PODMAN_VERSION" == "nightly" ]]; then
    sudo dnf copr enable -y rhcontainerbot/podman-next
    sudo dnf install -y podman --disablerepo=testing-farm-tag-repository 
    PODMAN_VERSION="$(dnf --quiet \
        --repofrompath=podman-next,https://download.copr.fedorainfracloud.org/results/rhcontainerbot/podman-next/fedora-$(rpm -E %fedora)/${ARCH}/ \
        list --showduplicates podman 2>/dev/null | grep dev | tail -n1 | cut -d':' -f2 | cut -d'-' -f1 )"
else
    # For "latest" or specific version, fetch version if needed and install from RPM
    REQUESTED_PODMAN_VERSION="$PODMAN_VERSION"
    if [[ "$PODMAN_VERSION" == "latest" ]]; then
        PODMAN_VERSION="$(curl -sL https://api.github.com/repos/podman-container-tools/podman/releases | jq -r '.[] | select(.prerelease == false) | .tag_name' | head -n1 | sed 's/^v//')"
    fi
    CUSTOM_PODMAN_URL="https://kojipkgs.fedoraproject.org//packages/podman/${PODMAN_VERSION}/1.${COMPOSE_VERSION}/${ARCH}/podman-${PODMAN_VERSION}-1.${COMPOSE_VERSION}.${ARCH}.rpm"
    if curl -fLo podman.rpm "$CUSTOM_PODMAN_URL"; then
        sudo dnf install -y ./podman.rpm
        rm -f podman.rpm
    else
        rm -f podman.rpm
        if [[ "$REQUESTED_PODMAN_VERSION" != "latest" ]]; then
            echo "ERROR: Requested Podman ${PODMAN_VERSION} RPM is unavailable on Koji for ${COMPOSE_VERSION}"
            exit 1
        fi
        echo "WARNING: Podman ${PODMAN_VERSION} RPM not available on Koji for ${COMPOSE_VERSION}, falling back to dnf repos"
        sudo dnf install -y podman --disablerepo=testing-farm-tag-repository
        PODMAN_VERSION="$(podman --version | cut -d' ' -f3)"
    fi
fi

# Verify that the installed Podman version matches the expected version. 
INSTALLED_PODMAN_VERSION="$(podman --version | cut -d' ' -f3)"
NORMALIZED_PODMAN_VERSION="${PODMAN_VERSION//\~/-}"

if [[ "$INSTALLED_PODMAN_VERSION" != "$NORMALIZED_PODMAN_VERSION" ]]; then
    echo "Podman version mismatch: expected $NORMALIZED_PODMAN_VERSION but got $INSTALLED_PODMAN_VERSION"
    exit 1
fi

echo "Podman installed successfully: $INSTALLED_PODMAN_VERSION"
