#!/bin/bash
set -e

echo "Installing podman-compose..."

if sudo dnf install -y podman-compose 2>/dev/null; then
    echo "podman-compose installed via dnf."
else
    echo "dnf installation failed, falling back to pip..."
    sudo dnf install -y python3-pip
    pip3 install --user podman-compose
    export PATH="$HOME/.local/bin:$PATH"
fi

podman-compose --version
echo "podman-compose installation complete."
