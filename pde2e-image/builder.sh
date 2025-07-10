#!/bin/bash

# Build Linux image
OS=linux make oci-build
# OS=linux make oci-push

# Build Mac OS image
OS=darwin make oci-build
# OS=darwin make oci-push

# Build Windows image
OS=windows make oci-build
# OS=windows make oci-push

# Build and push Tekton Task image
# make tkn-push
