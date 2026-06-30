#!/bin/bash
set -e

echo "Installing Docker Engine on RHEL..."

echo "Installing dnf-plugins-core..."
sudo dnf -y install dnf-plugins-core

echo "Adding Docker CE repository..."
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

echo "Installing Docker Engine packages..."
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Starting and enabling Docker service..."
sudo systemctl enable --now docker

echo "Adding current user to docker group..."
sudo usermod -aG docker "$(whoami)"

docker --version
echo "Docker Engine installation complete."
