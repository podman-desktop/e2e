#!/bin/bash
set -e

echo "Installing minikube..."
if [ "$(uname -m)" = "arm64" ]; then
    URL="https://github.com/kubernetes/minikube/releases/latest/download/minikube-darwin-arm64"
elif [ "$(uname -m)" = "x86_64" ]; then
    URL="https://github.com/kubernetes/minikube/releases/latest/download/minikube-darwin-amd64"
else
    echo "Unsupported architecture: $(uname -m)"
    exit 1
fi

echo "Downloading minikube from $URL"
if [ -n "$GITHUB_TOKEN" ]; then
    curl -H "Authorization: Bearer $GITHUB_TOKEN" -L -o ./minikube "$URL"
else
    echo "Warning: GITHUB_TOKEN is not set."
    curl -L -o ./minikube "$URL"
fi

sudo install minikube /usr/local/bin/minikube
minikube version
echo "minikube installation complete."
