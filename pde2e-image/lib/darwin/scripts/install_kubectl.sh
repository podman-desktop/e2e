#!/bin/bash
echo "Installing kubectl..."

KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)

# Install kubectl based on the arch
if [ $(uname -m) = arm64 ]; then
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl"
elif [ $(uname -m) = x86_64 ]; then
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/amd64/kubectl"
fi

chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl

kubectl version --client
echo "kubectl installation complete."
