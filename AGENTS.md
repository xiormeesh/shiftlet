# Shiftlet

Local SNO (Single Node OpenShift) cluster lifecycle tool using libvirt/KVM and the agent-based installer.

Read `README.md` for usage, env file format, and networking setup. Read `ARCHITECTURE.md` for design details.

## Project structure

- `common.sh` — all logic: cluster registry, networking, lifecycle, version resolution
- `create.sh`, `delete.sh`, `list.sh` — thin entry points that source common.sh
- `get_latest.sh`, `get_capabilities.sh` — info-retrieval scripts
- `hub.env.example` — example env file with capabilities reference
- `*.env` — user's cluster profiles (gitignored)
- `ARCHITECTURE.md` — detailed design: networking, state layout, install flow

## Key constraints

- Scripts require `sudo` for virsh, iptables, /etc/hosts. The user must run them from their terminal — never run create.sh or delete.sh from an AI assistant session.
- Minimum 16 GB RAM per cluster (installer-enforced for master nodes).
- State lives at `/var/lib/shiftlet/` (persistent) and `/tmp/shiftlet-<name>/` (install-time assets).
- Cluster registry file: `/var/lib/shiftlet/clusters` (one `id=name` line per cluster).
- Bridge mode: br0 and its autostart survive reboots (managed by NetworkManager).

## Common tasks

- **Check install progress**: Watch the `create.sh` output or tail `/tmp/shiftlet-create-<timestamp>.log`
- **Check cluster health**: `KUBECONFIG=/var/lib/shiftlet/<name>/kubeconfig oc get co`
- **Debug stuck install**: Open virt-viewer to see the VM console: `virt-viewer --connect qemu:///system shiftlet-<name>`

## Testing changes

Since these scripts manage VMs and system resources, there are no unit tests. Verify changes by:
1. Running `bash -n common.sh` to check syntax
2. Running a full create/delete cycle
3. Checking the log output for correct behavior
