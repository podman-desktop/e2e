#!/bin/bash
echo "Installing kind..."

KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)


# Install kind based on the arch
if [ $(uname -m) = arm64 ]; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-darwin-arm64
elif [ $(uname -m) = x86_64 ]; then
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-darwin-amd64
fi


chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

kind version
echo "kind installation complete."
