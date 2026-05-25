#!/bin/bash
set -e

echo "Cleaning up managed configuration files for Podman Desktop on macOS..."

MANAGED_CONFIG_DIR="/Library/Application Support/io.podman_desktop.PodmanDesktop"
MANAGED_FILES=("default-settings.json" "locked.json")

if [ -d "$MANAGED_CONFIG_DIR" ]; then
    for file in "${MANAGED_FILES[@]}"; do
        file_path="$MANAGED_CONFIG_DIR/$file"
        if [ -f "$file_path" ]; then
            echo "Removing $file_path"
            sudo rm -f "$file_path"
        fi
    done
    if [ -z "$(ls -A "$MANAGED_CONFIG_DIR" 2>/dev/null)" ]; then
        echo "Removing empty directory $MANAGED_CONFIG_DIR"
        sudo rmdir "$MANAGED_CONFIG_DIR"
    fi
else
    echo "Managed configuration directory does not exist, skipping"
fi

REGISTRIES_CONF="$HOME/.config/containers/registries.conf"
if [ -f "$REGISTRIES_CONF" ]; then
    echo "Removing generated registries.conf at $REGISTRIES_CONF"
    rm -f "$REGISTRIES_CONF"
else
    echo "No registries.conf found, skipping"
fi

echo "Managed configuration cleanup complete."
