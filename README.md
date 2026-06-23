# shiftlet

Local Single Node OpenShift (SNO) clusters for development and testing. Wraps the [agent-based installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) and libvirt/KVM into simple scripts with a clean lifecycle.

Supports multiple clusters on the same host and cross-host cluster connectivity via port forwarding.

## Prerequisites

- Linux host with libvirt/KVM
  - Fedora: `sudo dnf install @virtualization`
- `sudo` access
- A valid [OpenShift pull secret](https://console.redhat.com/openshift/install/pull-secret)
- `oc` client (auto-installed if missing)
- `gh` CLI (only for version resolution) — [install](https://cli.github.com)

## Quick start

1. Copy one of the example env files and set your pull secret path:

```bash
cp hub.env.example hub.env
vim hub.env
```

2. Create a cluster:

```bash
./create.sh hub.env
```

This takes ~40 minutes. The cluster is automatically exposed on your LAN IP when done.

3. Access the cluster:

```bash
export KUBECONFIG=/var/lib/shiftlet/hub/kubeconfig
oc get nodes
```

The kubeadmin password is saved at `/var/lib/shiftlet/<name>/kubeadmin-password` and printed at the end of the install.

## Commands

| Script | Usage | Description |
|--------|-------|-------------|
| `create.sh` | `./create.sh <cluster.env>` | Create a cluster from an env file |
| `delete.sh` | `./delete.sh <name\|cluster.env>` | Delete a cluster and all its resources |
| `expose.sh` | `./expose.sh <name\|cluster.env>` | Re-apply port forwarding after a reboot |
| `list.sh` | `./list.sh` | List all clusters with connection info |
| `get_latest.sh` | `./get_latest.sh [X.Y\|latest]` | Print the latest stable OCP version |
| `get_capabilities.sh` | `./get_capabilities.sh` | Print known OCP capabilities for env files |

## Env file format

```bash
NAME=hub
VERSION=4.21.5
MEMORY_GB=20
PULL_SECRET=~/.config/openshift/pull-secret
CAPABILITIES="Ingress OperatorLifecycleManager marketplace Console MachineAPI Storage"
```

Three example profiles are included:

- **hub.env** — full capabilities, 20 GB RAM (for MCE/ACM, OLS hub)
- **spoke.env** — minimal capabilities, 12 GB RAM
- **dev.env** — barebones, no additional capabilities

## Cross-host setup

To make a cluster reachable from another machine (e.g., for multicluster testing):

1. Create the cluster — port forwarding is applied automatically
2. On the remote machine, add `/etc/hosts` entries (printed after create):

```
192.168.1.100  api.hub.shiftlet.local
192.168.1.100  console-openshift-console.apps.hub.shiftlet.local
192.168.1.100  oauth-openshift.apps.hub.shiftlet.local
```

3. Copy the kubeconfig to the remote machine

Port forwarding rules do not survive reboots. Re-apply with `./expose.sh <name>`.

## Same-host multi-cluster

When you create a second cluster on the same host, inter-bridge forwarding rules are added automatically so both VMs can reach each other through the host.

```bash
./create.sh hub.env      # slot 0, subnet 192.168.133.0/24
./create.sh spoke.env    # slot 1, subnet 192.168.134.0/24
```
