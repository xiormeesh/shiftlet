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

cid=$(get_cluster_id "$NAME")
[[ -n "$cid" ]] || die "cluster '${NAME}' not found"

remove_fw_rules "$NAME"
apply_fw_rules "$NAME" "$(vm_ip_for "$cid")"
sync_inter_bridge_rules
print_connection_info "$NAME"
