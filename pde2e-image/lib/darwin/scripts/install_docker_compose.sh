#!/bin/bash
set -e

echo "Installing docker-compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)

# Install docker-compose based on the arch
if [ $(uname -m) = arm64 ]; then
    URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-darwin-aarch64"
elif [ $(uname -m) = x86_64 ]; then
    URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-darwin-x86_64"
else
    echo "Unsupported architecture: $(uname -m)"
    exit 1
fi

echo "Downloading docker-compose from $URL"
if [ -n "$GITHUB_TOKEN" ]; then
    curl -H "Authorization: Bearer $GITHUB_TOKEN" -L -o ./docker-compose "$URL"
else
    echo "Warning: GITHUB_TOKEN is not set."
    curl -L -o ./docker-compose "$URL"
fi

chmod +x ./docker-compose
sudo mv ./docker-compose /usr/local/bin/docker-compose

docker-compose --version
echo "docker-compose installation complete."
