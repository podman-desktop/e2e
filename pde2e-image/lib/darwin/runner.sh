#!/bin/bash

targetFolder=""
resultsFolder="results"

while [[ $# -gt 0 ]]; do
    case $1 in
        --targetFolder) targetFolder="$2"; shift ;;
        --resultsFolder) resultsFolder="$2"; shift ;;
        *) ;;
    esac
    shift
done

if [ -z "$targetFolder" ]; then
    echo "Error: targetFolder is required"
    exit 1
fi

echo "Switching to a target $targetFolder"
cd "$targetFolder"
echo "Create a results folder in target..."
mkdir -p "$resultsFolder"
workingDir=$(pwd)

source ${workingDir}/common.sh

echo "Hello from Darwin runner script"

hello
