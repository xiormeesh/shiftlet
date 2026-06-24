# shiftlet

Local Single Node OpenShift (SNO) clusters for development and testing. Wraps the [agent-based installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) and libvirt/KVM into simple scripts with a clean lifecycle.

Supports multiple clusters on the same host and cross-host cluster connectivity via port forwarding.

## Prerequisites

- Linux host with libvirt/KVM (`virsh`, `virt-install`, `qemu-kvm`)
  - Fedora: `sudo dnf install @virtualization virt-install`
- `sudo` access (for virsh, /etc/hosts, iptables, /var/lib/shiftlet)
- A valid [OpenShift pull secret](https://console.redhat.com/openshift/install/pull-secret)
- `oc` client (auto-installed if missing)
- `gh` CLI (only for version resolution) — [install](https://cli.github.com)

## Quick start

1. Edit an env file and set your pull secret path:

```bash
vim dev.env
```

2. Create a cluster:

```bash
./create.sh dev.env
```

This takes ~40 minutes. The cluster is only accessible from the host machine by default.

3. Access the cluster:

```bash
export KUBECONFIG=/var/lib/shiftlet/dev/kubeconfig
oc get nodes
```

The kubeadmin password is saved at `/var/lib/shiftlet/<name>/kubeadmin-password` and printed at the end of the install.

## Commands

| Script | Usage | Description |
|--------|-------|-------------|
| `create.sh` | `./create.sh <cluster.env>` | Create a cluster from an env file |
| `delete.sh` | `./delete.sh <name\|cluster.env>` | Delete a cluster and all its resources |
| `expose.sh` | `./expose.sh <name\|cluster.env>` | Set up LAN port forwarding and inter-cluster connectivity |
| `list.sh` | `./list.sh` | List all clusters with connection info |
| `get_latest.sh` | `./get_latest.sh [X.Y\|latest]` | Print the latest stable OCP version |
| `get_capabilities.sh` | `./get_capabilities.sh` | Print known OCP capabilities for env files |

## Env file format

```bash
NAME=dev
VERSION=4.21.5
MEMORY_GB=12
PULL_SECRET=~/.config/openshift/pull-secret
CAPABILITIES="Ingress Console"
```

See [hub.env.example](hub.env.example) for all available capabilities with descriptions. Run `./get_capabilities.sh` for a quick list. Capabilities can be [enabled post-install](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installation_overview/cluster-capabilities) but not disabled.

Three profiles are included:

- **dev.env** — Ingress + Console, 12 GB RAM
- **spoke.env** — adds OLM, 12 GB RAM
- **hub.env** — adds marketplace + MachineAPI (for MCE/ACM), 20 GB RAM

Run `./get_capabilities.sh` to see all available capabilities.

## Exposing clusters

By default, clusters are only accessible from the host machine. To make a cluster reachable from other machines on the LAN or enable connectivity between clusters on the same host, run:

```bash
./expose.sh <name>
```

This sets up:
- **iptables DNAT rules** forwarding ports 80, 443, 6443 from your LAN IP to the cluster VM
- **Inter-bridge routing** if multiple clusters exist on the same host (so VMs on different libvirt networks can reach each other)

Port forwarding and inter-bridge rules **do not survive reboots**. Re-run `./expose.sh <name>` for each cluster after a reboot.

## Cross-host multi-cluster setup

For multicluster testing with clusters on different machines (e.g., hub on laptop A, spoke on laptop B connected via ethernet):

1. Create and expose on each machine:

```bash
# Laptop A:
./create.sh hub.env && ./expose.sh hub

# Laptop B:
./create.sh spoke.env && ./expose.sh spoke
```

2. Add `/etc/hosts` entries on each machine to reach the other's cluster (`expose.sh` prints the exact lines). For example, on laptop A add:

```
<laptop-B-IP>  api.spoke.shiftlet.local
<laptop-B-IP>  console-openshift-console.apps.spoke.shiftlet.local
<laptop-B-IP>  oauth-openshift.apps.spoke.shiftlet.local
```

And vice versa on laptop B for the hub cluster.

## Same-host multi-cluster

```bash
./create.sh hub.env
./create.sh spoke.env
./expose.sh hub
./expose.sh spoke
```

After exposing, both VMs can reach each other through the host via inter-bridge forwarding rules.
