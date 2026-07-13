#!/usr/bin/env bash
set -eu

# Auto-logging: write to both stdout and log file
LOG_FILE="/tmp/shiftlet-create-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to: ${LOG_FILE}"
echo ""

source "$(dirname "$0")/common.sh"

[[ $# -eq 1 ]] || die "usage: ./create.sh <cluster.env>"

load_env "$1"

releaseImage=$(resolve_release_image "$VERSION")
memoryMB=$(( MEMORY_GB * 1024 ))

info "Installing cluster '${NAME}' using ${releaseImage}"
create_cluster "$NAME" "$releaseImage" "$memoryMB" "$PULL_SECRET"
