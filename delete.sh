#!/usr/bin/env bash
set -eu

source "$(dirname "$0")/common.sh"

[[ $# -eq 1 ]] || die "usage: ./cleanup.sh <cluster.env|name>"

if [[ -f "$1" ]]; then
    load_env "$1"
else
    NAME="$1"
fi

delete_cluster "$NAME"
