# Shiftlet

Local SNO (Single Node OpenShift) cluster lifecycle tool using libvirt/KVM and the agent-based installer.

Read `README.md` for usage, env file format, and networking setup. Read `ARCHITECTURE.md` for design details.

## Project structure

- `common.sh` — all logic: cluster registry, networking, lifecycle, version resolution
- `create.sh`, `delete.sh`, `expose.sh`, `list.sh` — thin wrappers that source common.sh
- `get_latest.sh`, `get_capabilities.sh` — info-retrieval scripts
- `hub.env.example` — example env file with capabilities reference
- `*.env` — user's cluster profiles (gitignored)
- `ARCHITECTURE.md` — detailed design: networking, state layout, install flow

## Key constraints

- Scripts require `sudo` for virsh, iptables, /etc/hosts. The user must run them from their terminal — never run create.sh or delete.sh from an AI assistant session.
- Minimum 16 GB RAM per cluster (installer-enforced for master nodes).
- State lives at `/var/lib/shiftlet/` (persistent) and `/tmp/shiftlet-<name>/` (install-time assets).
- Cluster registry file: `/var/lib/shiftlet/clusters` (one `id=name` line per cluster).
- iptables rules do not survive reboots — re-run `expose.sh` after reboot.

## Common tasks

- **Check install progress**: `tail -f /tmp/shiftlet-install.log`
- **SSH into a cluster VM**: `ssh core@192.168.(133+id).80`
- **Check cluster health**: `KUBECONFIG=/var/lib/shiftlet/<name>/kubeconfig oc get co`
- **Debug stuck install**: SSH into VM, check `journalctl -b --no-pager | tail -40`

## Testing changes

Since these scripts manage VMs and system resources, there are no unit tests. Verify changes by:
1. Running `bash -n common.sh` to check syntax
2. Running a full create/delete cycle
3. Checking the log output for correct behavior
