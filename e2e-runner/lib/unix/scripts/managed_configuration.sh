#!/bin/bash
set -e

echo "Setting up managed configuration files for Podman Desktop (or build) on Unix..."

MANAGED_CONFIG_DIR="/Library/Application Support/io.podman_desktop.PodmanDesktop"
MANAGED_FILES=("default-settings.json" "locked.json")

if [[ "$PRODUCT_TESTS" == "true" || "$PRODUCT_TESTS" == "1" ]]; then
    if [ "$(uname)" == "Linux" ]; then
        MANAGED_CONFIG_DIR="/usr/share/rh-podman-desktop"
    else
        MANAGED_CONFIG_DIR="/Library/Application Support/com.redhat.PodmanDesktop"
    fi
else
    if [ "$(uname)" == "Linux" ]; then
        MANAGED_CONFIG_DIR="/usr/share/podman-desktop"
    fi
fi

echo "Working with '$MANAGED_CONFIG_DIR' managed directory"

if [ -d "podman-desktop" ]; then
    echo "checkout to podman-desktop repo..."
    cd podman-desktop
    echo "Setting up managed configuration for Linux and Mac OS"
    sudo mkdir -p "$MANAGED_CONFIG_DIR"
    test_default="tests/playwright/resources/managed-configuration/default-settings.json"
    test_locked="tests/playwright/resources/managed-configuration/locked.json"
    if [ -f "$test_default" ]; then
       sudo cp "$test_default" "$MANAGED_CONFIG_DIR/default-settings.json"
    else
        echo "$test_default does not exist..."
    fi
    if [ -f "$test_locked" ]; then
       sudo cp "$test_locked" "$MANAGED_CONFIG_DIR/locked.json"
    else
        echo "$test_locked does not exist..."
    fi
    echo "Default settings:" && cat "$MANAGED_CONFIG_DIR/default-settings.json"
    echo "Locked settings:" && cat "$MANAGED_CONFIG_DIR/locked.json"
else
    echo "podman-desktop repository not found, could not set managed config..."
    exit 1
fi

