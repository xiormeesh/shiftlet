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
- **For bridge mode only**: Linux bridge device (br0) — see [Bridge Setup](#bridge-setup-for-bridge-mode) below

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

- **dev.env** — Ingress + Console, 16 GB RAM
- **spoke.env** — adds OLM, 16 GB RAM
- **hub.env** — adds marketplace + MachineAPI + Build + ImageRegistry (for MCE/ACM), 25 GB RAM

Minimum 16 GB RAM per cluster — the installer enforces this for master/control-plane nodes.

Run `./get_capabilities.sh` to see all available capabilities.

## Network Modes

Shiftlet supports two network modes via the `NETWORK_MODE` env variable:

### NAT Mode (Default)

Creates isolated virtual networks per cluster. Works on WiFi or wired ethernet.

- VM gets private IP on isolated subnet (192.168.133.x, 192.168.134.x, etc.)
- Host can reach VM, LAN cannot
- Multiple clusters on same host work fine (each gets isolated network)
- Cross-host multi-cluster requires port forwarding (see firewalld-expose.sh)

Use NAT for:
- Single cluster development
- WiFi-based setups
- Isolated testing

### Bridge Mode (Experimental)

Connects VMs directly to your LAN via a Linux bridge. Requires wired ethernet and bridge setup.

- VM gets real LAN IP (192.168.1.80, 192.168.1.81, etc.)
- VM reachable from any device on LAN, including the host
- Cross-host multi-cluster works without port forwarding
- Assumes /24 subnet, IPs .80-.89 available

Use bridge for:
- Multi-cluster across physical hosts
- Hub-spoke testing with hub on host A, spoke on host B

**Requirements:**
- Wired ethernet connection (eth*, enp*, ens*, eno*)
- Linux bridge device (br0) — see [Bridge Setup](#bridge-setup-for-bridge-mode) below
- /24 LAN subnet (e.g., 192.168.1.0/24)
- IPs .80-.89 reserved/available (not in DHCP pool)

**Setup:**
```bash
# 1. Set up bridge (one-time, see Bridge Setup section below)
# 2. Reserve IPs .80-.89 in your router's DHCP settings
# 3. Create cluster with bridge mode
NETWORK_MODE=bridge ./create.sh hub.env
```

## Bridge Setup (for Bridge Mode)

Bridge mode requires a Linux bridge device (br0) that connects VMs to your physical LAN. This is a **one-time setup per host**.

### Creating the Bridge with NetworkManager

Most modern Linux systems use NetworkManager. Create the bridge using `nmcli`:

```bash
# 1. Identify your wired interface name
ip link show

# Example output shows: eth0, enp0s31f6, etc.
# Use your actual interface name in the commands below (replace eth0)

# 2. Create bridge device
sudo nmcli connection add type bridge ifname br0 con-name br0

# 3. Add your wired interface to the bridge
# This will briefly interrupt network connectivity (~5-10 seconds)
sudo nmcli connection add type ethernet slave-type bridge \
    master br0 ifname eth0 con-name bridge-slave-eth0

# 4. Bring up the bridge
sudo nmcli connection up br0

# 5. Verify bridge is active
ip link show br0
nmcli connection show
```

**What this does:**
- Creates a bridge device named `br0`
- Enslaves your physical ethernet interface (eth0) to the bridge
- Transfers IP configuration from eth0 to br0
- Your host's LAN connectivity now goes through the bridge
- VMs attached to br0 will appear as separate devices on your LAN

**Important notes:**
- Run this on a **wired connection only** (WiFi cannot be bridged)
- Brief network interruption during setup (5-10 seconds)
- If connected via SSH, your session may drop
- Configuration persists across reboots
- Bridge must be created **before** running shiftlet in bridge mode

### Verifying the Bridge

After creating the bridge, verify it's working:

```bash
# Check bridge exists and is UP
ip link show br0

# Check your host still has network connectivity
ping -c 3 8.8.8.8

# Verify bridge connection is active
nmcli connection show --active | grep br0
```

### Removing the Bridge

If you need to remove the bridge and restore direct ethernet:

```bash
# Delete bridge connections
sudo nmcli connection delete br0
sudo nmcli connection delete bridge-slave-eth0

# Bring up original ethernet connection
sudo nmcli connection up "Wired connection 1"
```

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

**With bridge mode (recommended):**

1. Ensure both hosts on wired ethernet, same LAN
2. Reserve IPs .80-.89 in router DHCP settings
3. Create clusters with `NETWORK_MODE=bridge`:

```bash
# Host A:
NETWORK_MODE=bridge ./create.sh hub.env

# Host B:
NETWORK_MODE=bridge ./create.sh spoke.env
```

4. Clusters accessible from both hosts via LAN IPs (no /etc/hosts needed):
   - Hub: 192.168.1.80
   - Spoke: 192.168.1.81

**With NAT mode (complex, requires firewalld):**

For NAT mode cross-host setup, see firewalld-expose.sh script. Requires iptables/firewalld port forwarding rules and /etc/hosts entries. Bridge mode is simpler.

## Same-host multi-cluster

```bash
./create.sh hub.env
./create.sh spoke.env
./expose.sh hub
./expose.sh spoke
```

After exposing, both VMs can reach each other through the host via inter-bridge forwarding rules.
