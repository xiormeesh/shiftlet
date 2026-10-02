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

| Identifier | NAT mode | Shared network mode | Bridge mode |
|------------|----------|---------------------|-------------|
| Subnet | `192.168.(133+id).0/24` | same as parent cluster | First 3 octets of `BRIDGE_VM_IP` |
| VM IP | `192.168.(133+id).80` | next available on parent subnet (.81, .82, ...) | `BRIDGE_VM_IP` (from env file) |
| VM MAC | `52:54:00:xx:xx:xx` (derived from hostname+id) | same | same |
| libvirt network | `shiftlet-<name>` | parent's network (e.g. `shiftlet-hub`) | not created |
| VM hostname | `shiftlet-<name>` | same | same |
| Domain | `<name>.shiftlet.local` | same | same |
| Kubeconfig | `/var/lib/shiftlet/<name>/kubeconfig` | same | same |
| Install assets | `/tmp/shiftlet-<name>/` (install-time only) | same | same |

Up to 10 NAT clusters are supported per host (subnets `192.168.133.x` through `192.168.142.x`). Bridge mode clusters are limited by available LAN IPs.

## Networking

### Local access (default)

Each cluster lives inside an isolated libvirt NAT network. The host machine can reach the cluster; no other machine on the LAN can. All `*.shiftlet.local` DNS is handled by the shiftlet-dns service (see below) with systemd-resolved forwarding on the host.

```
other host   ✗
             \
host A ────── virbr-shlN (NAT) ── VM (192.168.13N.80)
             ✓
```

### Shared network (same-host multi-cluster)

Multiple clusters share the same libvirt NAT network. The recommended configuration for running hub + spoke on a single host. Works on WiFi or wired ethernet.

```
host A ────── virbr-shl0 (NAT) ─┬─ Hub VM  (192.168.133.80)
             ✓                  └─ Spoke VM (192.168.133.81)
```

**How it works:**
- First cluster creates a NAT network as usual
- Second cluster sets `SHARED_NETWORK=<first-cluster-name>` in its env file
- `join_shared_network()` adds a DHCP host reservation and DNS entries to the existing libvirt network via `virsh net-update`
- VM gets an IP via DHCP from the shared network's dnsmasq (next sequential IP after .80)
- virt-install uses `--network network=<parent-network-name>`
- Both VMs are on the same L2 bridge — direct communication, no firewall rules needed
- On delete, only the DHCP/DNS entries are removed; the parent network stays intact

**Persisted state:** `/var/lib/shiftlet/<name>/shared_network` stores the parent cluster name so delete knows to clean up entries rather than destroy the network.

### Cross-cluster DNS

Pods on one cluster often need to resolve hostnames on another cluster (e.g., `cluster-proxy-anp.apps.hub.shiftlet.local` from a spoke). Static `/etc/hosts` entries can't provide wildcard resolution, so shiftlet runs a lightweight dnsmasq on the host:

```
Pod → OCP CoreDNS → Node upstream DNS (libvirt dnsmasq :53)
     → server=/shiftlet.local/127.0.0.2#53  (forwarding rule)
       → shiftlet-dns dnsmasq (127.0.0.2:53)
         → address=/hub.shiftlet.local/192.168.133.80    (A wildcard)
         → address=/hub.shiftlet.local/::                (AAAA → immediate empty response)
         → address=/spoke.shiftlet.local/192.168.133.81  (A wildcard)
         → address=/spoke.shiftlet.local/::              (AAAA → immediate empty response)

Host → systemd-resolved → 127.0.0.2  (via Domains=~shiftlet.local)
```

**How it works:**
- A systemd service (`shiftlet-dns`) runs dnsmasq on `127.0.0.2:53`
- It reads wildcard entries from `/var/lib/shiftlet/dns/*.conf` — one file per cluster with `address=` lines for both A (IPv4) and AAAA (`::`)
- Each libvirt network's dnsmasq forwards `*.shiftlet.local` queries to it via a `server=` option in `<dnsmasq:options>`
- The `localOnly` attribute is not set on the `<domain>` element, allowing forwarding of unknown subdomains
- A systemd-resolved drop-in (`/etc/systemd/resolved.conf.d/shiftlet.conf`) forwards `~shiftlet.local` to `127.0.0.2`, giving the host full wildcard resolution (no `/etc/hosts` entries needed)
- `create.sh` writes the DNS entry and ensures both services are configured
- `delete.sh` removes the entry and stops the service when no clusters remain

**Why `address=/::/`?** dnsmasq's `address=` with an IPv4 address only creates A records. Without an explicit AAAA entry, AAAA queries are forwarded upstream. Since shiftlet-dns has `--no-resolv` (no upstreams), it returns `REFUSED`, which the bridge dnsmasq treats as an error and hangs on. The `::` entry ensures AAAA queries get an immediate response.

**Bridge mode limitation:** bridge mode does not create a libvirt network, so cross-cluster DNS forwarding to VMs is not available. The host still gets wildcard resolution via systemd-resolved.

**Migration:** existing clusters created before this feature can be patched in place with `./migrate-dns.sh` (no redeploy needed).

### LAN access (bridge mode)

See bridge mode section below.

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
- Add `/etc/hosts` entries (printed at end of install — remote hosts lack shiftlet-dns)
- Copy kubeconfig via scp (printed at end of install)


## Install flow

```
./create.sh dev.env
    │
    ├─ resolve latest OCP version via cincinnati-graph-data (gh CLI)
    ├─ assign cluster ID → derive all identifiers
    ├─ register cluster in /var/lib/shiftlet/clusters  ← safe to 'delete' from here
    ├─ extract openshift-install from the release payload (oc adm release extract)
    ├─ NAT mode:     define + start libvirt NAT network (with autostart)
    │  shared mode:  add DHCP reservation + DNS entries to parent network
    │  bridge mode:  validate br0 exists and is UP
    ├─ write DNS entry + ensure shiftlet-dns + systemd-resolved forwarding
    ├─ write agent-config.yaml + install-config.yaml
    │  bridge mode: agent-config.yaml includes NMState static IP config
    ├─ build agent ISO  (openshift-install agent create image)
    ├─ NAT/shared:   virt-install --network network=shiftlet-<name>
    │  bridge mode:  virt-install --network bridge=br0
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
    vmip                   # VM IP address
    network_mode           # NAT or bridge
    shared_network         # (optional) parent cluster name for shared network mode
  hub/
    kubeconfig
    ...
  dns/
    hub.conf               # wildcard DNS: address=/hub.shiftlet.local/192.168.133.80
    spoke.conf             # one file per cluster, read by shiftlet-dns service

/tmp/shiftlet-<name>/      # install-time working directory; not needed after install
```

## Prerequisites

- Linux host with libvirt/KVM (`virt-install`, `virsh`, `qemu-kvm`)
  - Fedora: `sudo dnf install @virtualization virt-install`
- `sudo` access (for virsh, systemd-resolved, iptables, /var/lib/shiftlet)
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
