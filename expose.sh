#!/usr/bin/env bash
# Re-apply port forwarding rules after a host reboot.
set -eu

source "$(dirname "$0")/common.sh"

[[ $# -eq 1 ]] || die "usage: ./expose.sh <cluster.env|name>"

if [[ -f "$1" ]]; then
    load_env "$1"
else
    NAME="$1"
fi

slot=$(get_slot "$NAME")
[[ -n "$slot" ]] || die "cluster '${NAME}' not found"

remove_fw_rules "$NAME"
apply_fw_rules "$NAME" "$(vm_ip_for "$slot")"
print_connection_info "$NAME"
