#!/bin/bash
echo "Installing minikube..."

if [ $(uname -m) = arm64 ]; then
    curl -Lo ./minikube https://github.com/kubernetes/minikube/releases/latest/download/minikube-darwin-arm64
elif [ $(uname -m) = x86_64 ]; then
    curl -Lo ./minikube https://github.com/kubernetes/minikube/releases/latest/download/minikube-darwin-amd64
fi

sudo install minikube /usr/local/bin/minikube

minikube version
echo "minikube installation complete."
