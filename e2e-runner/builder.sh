#!/bin/bash

set -euo pipefail

# A builder script for local development.

# Build Mac OS image
OS=darwin make oci-build
# OS=darwin make oci-push

# Build Windows image
OS=windows make oci-build
# OS=windows make oci-push

# Build RHEL image
OS=rhel make oci-build
# OS=rhel make oci-push

# Build and push Tekton Task image
# make tkn-push


