#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/common.sh"

[[ $# -eq 1 ]] || die "usage: ./setup.sh <cluster.env>"

load_env "$1"

releaseImage=$(resolve_release_image "$VERSION")
memoryMB=$(( MEMORY_GB * 1024 ))

info "Installing cluster '${NAME}' using ${releaseImage}"
create_cluster "$NAME" "$releaseImage" "$memoryMB" "$PULL_SECRET"
