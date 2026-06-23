#!/usr/bin/env bash
# Print the latest stable OCP release image for this architecture.
# Usage: ./latest.sh [X.Y|latest]
set -eu

source "$(dirname "$0")/common.sh"

resolve_version "${1:-latest}"
