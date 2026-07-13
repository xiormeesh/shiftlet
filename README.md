# shiftlet

Local Single Node OpenShift (SNO) clusters for development and testing. Wraps the [agent-based installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) and libvirt/KVM into simple scripts with a clean lifecycle.

Supports multiple clusters on the same host and cross-host cluster connectivity via bridge networking.

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

This takes ~40 minutes. In NAT mode (default), the cluster is only accessible from the host machine. In bridge mode, it is accessible from any device on the LAN.

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
| `list.sh` | `./list.sh` | List all clusters with VM IP, console URL, kubeconfig, and login |
| `get_latest.sh` | `./get_latest.sh [X.Y\|latest]` | Print the latest stable OCP version |
| `get_capabilities.sh` | `./get_capabilities.sh` | Print known OCP capabilities for env files |

Example `list.sh` output:

```
------------------------------------------------------------
  Name:      hub
  VM IP:     192.168.1.80
  Console:   https://console-openshift-console.apps.hub.shiftlet.local
  Kubeconfig: export KUBECONFIG=/var/lib/shiftlet/hub/kubeconfig
  Login:     kubeadmin / sHAja-Ptx93-8HIfR-v2DtH
------------------------------------------------------------
```

## Env file format

```bash
NAME=dev
VERSION=4.21.5
MEMORY_GB=12
PULL_SECRET=~/.config/openshift/pull-secret
CAPABILITIES="Ingress Console"
```

See [hub.env.example](hub.env.example) for all available capabilities with descriptions. Run `./get_capabilities.sh` for a quick list. Capabilities can be [enabled post-install](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installation_overview/cluster-capabilities) but not disabled.

Env files are gitignored — create your own based on [hub.env.example](hub.env.example). Typical profiles:

- **dev** — `CAPABILITIES="Ingress Console"`, 16 GB RAM — minimal cluster for local testing
- **spoke** — adds `OperatorLifecycleManager`, 16 GB RAM — registers to hub via MCE/ACM
- **hub** — adds `marketplace MachineAPI Build ImageRegistry`, 25 GB RAM — runs MCE/ACM

Minimum 16 GB RAM per cluster — the installer enforces this for master/control-plane nodes.

## Network Modes

Shiftlet supports two network modes via the `NETWORK_MODE` env variable:

### NAT Mode (Default)

Creates isolated virtual networks per cluster. Works on WiFi or wired ethernet.

- VM gets private IP on isolated subnet (192.168.133.x, 192.168.134.x, etc.)
- Host can reach VM, LAN cannot
- Multiple clusters on same host work fine (each gets isolated network)
- /etc/hosts entries are added automatically on the host

Use NAT for:
- Single cluster development
- WiFi-based setups
- Isolated testing

### Bridge Mode (Experimental)

Connects VMs directly to your LAN via a Linux bridge. Requires wired ethernet and bridge setup.

- VM gets explicit LAN IP (set via `BRIDGE_VM_IP` in env file)
- VM reachable from any device on the LAN, including the host
- Cross-host multi-cluster works without port forwarding
- /etc/hosts added automatically on the install host; must be added manually on other hosts (printed at end of install)

Use bridge for:
- Multi-cluster across physical hosts
- Hub-spoke testing with hub on host A, spoke on host B

**Prerequisites (one-time per host):**
- Wired ethernet connection
- Linux bridge device (br0) — see [Bridge Setup](#bridge-setup-for-bridge-mode) below
- `nmstate` package: `sudo dnf install nmstate`
- /24 LAN subnet (e.g., 192.168.1.0/24)
- Chosen VM IPs outside your router's DHCP pool

**Env file settings:**
```bash
NETWORK_MODE=bridge
BRIDGE_VM_IP=192.168.1.80  # unique per cluster across all hosts on LAN
```

**Then:**
```bash
./create.sh hub.env
```

After install, shiftlet prints the /etc/hosts line and `scp` command needed on the other host.

## Bridge Mode Assumptions and Limitations

Bridge mode makes the following assumptions. These are documented here, not validated by shiftlet.

- **Gateway is `<first 3 octets of BRIDGE_VM_IP>.1`** — e.g. for `192.168.1.80` the gateway is `192.168.1.1`. If your router uses a different IP, the VM will have no internet access.
- **DNS server is the gateway** — same IP as the gateway. If your network uses a separate DNS server, you will need to modify the NMState config in `common.sh`.
- **Subnet is /24** — prefix length 24 is hardcoded. Networks with /16, /25, or other sizes will not work correctly.
- **VM network interface is `enp1s0`** — the NMState config targets this interface name. This is the default for KVM VMs with virtio; different virt-install configurations may use a different name.
- **Bridge device is named `br0`** — hardcoded; alternative bridge names are not supported.

## Bridge Setup (for Bridge Mode)

Bridge mode requires a Linux bridge device (br0) and the `nmstate` package. This is a **one-time setup per host**.

### Install nmstate

```bash
sudo dnf install nmstate
```

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

## Cross-host multi-cluster setup

Requires bridge mode on both hosts.

**On each host (one-time):**
1. Set up the Linux bridge (see [Bridge Setup](#bridge-setup-for-bridge-mode))
2. Install nmstate: `sudo dnf install nmstate`
3. Reserve VM IPs in your router (outside DHCP pool)

**Install clusters:**
```bash
# Host A (hub.env has NETWORK_MODE=bridge, BRIDGE_VM_IP=192.168.1.80):
./create.sh hub.env

# Host B (spoke.env has NETWORK_MODE=bridge, BRIDGE_VM_IP=192.168.1.81):
./create.sh spoke.env
```

**After each install, shiftlet prints:**
- The /etc/hosts line to add on the other host
- The `scp` command to copy the kubeconfig to the other host

**What's automatic (on the install host):**
- /etc/hosts entries for the cluster domains → VM IP

**What's manual (on the other host):**
- Add the printed /etc/hosts line
- Copy kubeconfig with the printed scp command

