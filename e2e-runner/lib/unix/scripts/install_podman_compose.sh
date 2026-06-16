#!/bin/bash
set -e

echo "Installing podman-compose..."

if sudo dnf install -y podman-compose 2>/dev/null; then
    echo "podman-compose installed via dnf."
else
    echo "dnf package not available, installing manually..."
    sudo curl -o /usr/local/bin/podman-compose \
        https://raw.githubusercontent.com/containers/podman-compose/main/podman_compose.py
    sudo chmod +x /usr/local/bin/podman-compose
fi

podman-compose --version
echo "podman-compose installation complete."
