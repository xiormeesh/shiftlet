# shiftlet design

shiftlet creates and deletes local Single Node OpenShift (SNO) clusters for development and testing. It wraps the [agent-based installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) and libvirt/KVM into a single command with a clean lifecycle.

shiftlet only provisions clusters. Any post-install configuration (operators, multi-cluster management, etc.) is out of scope.

## Goals

1. **Simple lifecycle** — one command to create, one to delete, clusters survive host reboots by default
2. **LAN access** — reach a cluster from any device on the local network (bridge mode)
3. **Multiple clusters** — run several independent clusters, on the same host or across hosts

## Non-goals

- Post-install configuration (operators, MCE/ACM setup, etc.)
- High availability (SNO is single-node by design)
- Image mirroring / offline installs (future work)
- Non-Linux hosts
- Production use

## Cluster identity

Every cluster gets a **name** (e.g. `hub`, `spoke`, `dev`). A cluster registry at `/var/lib/shiftlet/clusters` maps cluster IDs to names. All cluster identifiers are derived from the ID:

| Identifier | NAT mode | Bridge mode |
|------------|----------|-------------|
| Subnet | `192.168.(133+id).0/24` | First 3 octets of `BRIDGE_VM_IP` |
| VM IP | `192.168.(133+id).80` | `BRIDGE_VM_IP` (from env file) |
| VM MAC | `52:54:00:93:72:(0x25+id)` | same |
| libvirt network | `shiftlet-<name>` | not created |
| VM hostname | `shiftlet-<name>` | same |
| Domain | `<name>.shiftlet.local` | same |
| Kubeconfig | `/var/lib/shiftlet/<name>/kubeconfig` | same |
| Install assets | `/tmp/shiftlet-<name>/` (install-time only) | same |

Up to 10 NAT clusters are supported per host (subnets `192.168.133.x` through `192.168.142.x`). Bridge mode clusters are limited by available LAN IPs.

## Networking

### Local access (default)

Each cluster lives inside an isolated libvirt NAT network. The host machine can reach the cluster; no other machine on the LAN can. DNS for `<name>.shiftlet.local` is handled via `/etc/hosts` on the host — the libvirt domain DNS is `localOnly="yes"`.

```
other host   ✗
             \
host A ────── virbr-shlN (NAT) ── VM (192.168.13N.80)
             ✓
```

### LAN access (bridge mode)

See bridge mode section below. NAT mode is single-host only.

### Bridge mode (experimental)

Alternative to NAT + port forwarding for cross-host multi-cluster. Attaches VMs directly to the physical LAN via a Linux bridge (br0).

```
host B ── (LAN) ── br0 ── VM (192.168.1.80)
                   │
                  eth0
```

**How it works:**
- User creates a Linux bridge (br0) with their wired interface enslaved to it (one-time setup, see README)
- VM IP is set explicitly via `BRIDGE_VM_IP` in the env file
- Static IP is configured via NMState in agent-config.yaml — the VM configures itself with the specified IP at boot
- VM appears as a separate LAN device with its own MAC address
- Router learns VM's MAC via ARP, forwards traffic normally
- virt-install uses `--network bridge=br0` — no libvirt network is created

**Example:**
- Host A: bridge br0 → Hub VM at `BRIDGE_VM_IP=192.168.1.80`
- Host B: bridge br0 → Spoke VM at `BRIDGE_VM_IP=192.168.1.81`
- Both VMs reachable from any LAN device

**Requirements:**
- Wired ethernet (WiFi APs reject bridged traffic)
- Linux bridge br0 set up on host (see README)
- `nmstate` package installed (used by openshift-install to validate NMState config)
- `BRIDGE_VM_IP` set in env file — must be unique across all hosts on the LAN

**Assumptions (not validated):**
- Gateway is `<first 3 octets of BRIDGE_VM_IP>.1` (e.g. 192.168.1.1)
- DNS server is the gateway
- Subnet is /24 — prefix-length 24 is hardcoded in NMState config
- VM network interface name is `enp1s0` (default for KVM virtio)

**Post-install (manual on other hosts):**
- Add /etc/hosts entries (printed at end of install)
- Copy kubeconfig via scp (printed at end of install)


## Install flow

```
./create.sh dev.env
    │
    ├─ resolve latest OCP version via cincinnati-graph-data (gh CLI)
    ├─ assign cluster ID → derive all identifiers
    ├─ register cluster in /var/lib/shiftlet/clusters  ← safe to 'delete' from here
    ├─ extract openshift-install from the release payload (oc adm release extract)
    ├─ NAT mode:  define + start libvirt NAT network (with autostart)
    │  bridge mode: validate br0 exists and is UP
    ├─ add /etc/hosts entries (VM IP → cluster domains)
    ├─ write agent-config.yaml + install-config.yaml
    │  bridge mode: agent-config.yaml includes NMState static IP config
    ├─ build agent ISO  (openshift-install agent create image)
    ├─ NAT mode:  virt-install --network network=shiftlet-<name>
    │  bridge mode: virt-install --network bridge=br0
    ├─ launch VM via virt-install (with autostart)
    ├─ wait for OCP install  (openshift-install agent wait-for install-complete)
    ├─ copy kubeconfig → /var/lib/shiftlet/<name>/kubeconfig
    ├─ extract + store kubeadmin-password
    └─ detach ISO from VM
```

The cluster ID is registered before any external resources are created. If `create` fails at any point, `shiftlet delete <name>` can fully clean up.

## Version selection

`--version` queries the [cincinnati-graph-data](https://github.com/openshift/cincinnati-graph-data) repository via the `gh` CLI to find the latest stable release:

- `--version latest` — absolute latest stable Z across all Y-streams
- `--version 4.21` — latest Z in the 4.21 Y-stream
- `--release <image>` — use an explicit release image reference (no network lookup)

## State layout

```
/var/lib/shiftlet/
  clusters                 # registry: one "id=name" line per cluster
  dev/
    kubeconfig             # cluster kubeconfig (readable by installing user)
    kubeadmin-password     # kubeadmin login password
  hub/
    kubeconfig
    ...

/tmp/shiftlet-<name>/      # install-time working directory; not needed after install
```

## Prerequisites

- Linux host with libvirt/KVM (`virt-install`, `virsh`, `qemu-kvm`)
  - Fedora: `sudo dnf install @virtualization virt-install`
- `sudo` access (for virsh, /etc/hosts, iptables, /var/lib/shiftlet)
- A valid [OpenShift pull secret](https://console.redhat.com/openshift/install/pull-secret) — path set via `PULL_SECRET` in env file
- `oc` client (auto-installed if missing)
- `gh` CLI — only for version resolution (install from https://cli.github.com)
- Sufficient resources per cluster:
  - 8 vCPUs, 25 GB RAM, 100 GB disk (hub with MCE/ACM operators)
  - 8 vCPUs, 16 GB RAM, 100 GB disk (spoke / plain OCP)
- **Bridge mode only**: `nmstate` package, Linux bridge `br0` — see README

## Future work

- Local image mirror registry to speed up reinstalls
- ARM64 virt-install profile (`--os-variant` selection)
- `shiftlet status <name>` — cluster health check
- `shiftlet ssh <name>` — SSH into the node
