# shiftlet design

shiftlet deploys and manages local Single Node OpenShift (SNO) clusters for development and testing. It wraps the [agent-based installer](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) and libvirt/KVM into a single command with a clean lifecycle.

## Goals

1. **Multi-cluster** — run more than one SNO cluster on the same host without conflict
2. **LAN access** — expose a cluster running on a remote machine to other machines on the local network
3. **Simple lifecycle** — one command to create, one to delete, clusters survive host reboots by default

## Non-goals

- High availability (SNO is single-node by design)
- Image mirroring / offline installs (future work)
- Non-Linux hosts
- Production use

## Cluster identity

Every cluster gets a **name** (e.g. `hub`, `spoke`, `dev`). A slot registry at `/var/lib/shiftlet/slots` maps slot numbers to names. All cluster identifiers are derived from the slot:

| Identifier | Derivation |
|------------|-----------|
| Subnet | `192.168.(133+slot).0/24` |
| VM IP | `192.168.(133+slot).80` |
| VM MAC | `52:54:00:93:72:(0x25+slot)` |
| libvirt network | `shiftlet-<name>` |
| VM hostname | `shiftlet-<name>` |
| Domain | `<name>.shiftlet.local` |
| Kubeconfig | `/var/lib/shiftlet/<name>/kubeconfig` |
| Install assets | `/tmp/shiftlet-<name>/` (install-time only) |

Up to 10 slots are supported (subnets `192.168.133.x` through `192.168.142.x`).

## Networking

### Local access (default)

Each cluster lives inside an isolated libvirt NAT network. The host machine can reach the cluster; no other machine on the LAN can. DNS for `<name>.shiftlet.local` is handled via `/etc/hosts` on the host — the libvirt domain DNS is `localOnly="yes"`.

```
other laptop   ✗
               \
work laptop ── virbr-shlN (NAT) ── VM (192.168.13N.80)
               ✓
```

### LAN access via port forwarding (`--expose`)

The `expose` command adds iptables DNAT rules that forward ports 80, 443, and 6443 from the host's LAN IP to the VM. A POSTROUTING MASQUERADE rule ensures the VM can route responses back through the host.

```
other laptop ── (LAN) ── work laptop:6443 ─DNAT─► VM:6443
```

Port forwarding is tracked via a flag file at `/var/lib/shiftlet/<name>/exposed`. The `delete` command removes rules automatically. Rules are applied immediately but **do not survive reboots** without additional configuration — see [Persistence](#persistence) below.

For the remote machine to resolve the cluster's domain names, add the host's LAN IP to `/etc/hosts` on the remote machine (shiftlet prints the exact lines to add after `expose`).

Bridge networking is intentionally not used: on WiFi (802.11 infrastructure mode), the AP rejects frames whose source MAC has not authenticated — bridging a VM tap device to a wireless interface silently drops all VM traffic. NAT + port forwarding works on both wired and wireless hosts.

### Persistence

IP forwarding (`net.ipv4.ip_forward=1`) is persisted to `/etc/sysctl.d/99-shiftlet.conf` on first `expose`. The iptables rules themselves are not automatically persisted across reboots.

Options to persist iptables rules:
- **iptables-save / restore service** — `sudo iptables-save > /etc/sysconfig/iptables` and enable `iptables.service`
- **firewalld** — re-add as `firewall-cmd --permanent --direct` rules (note: shiftlet warns if firewalld is active, as it may flush iptables rules on reload)
- **Re-run `shiftlet expose <name>`** — idempotent, safe to run again after reboot

## Install flow

```
shiftlet create dev --version latest
    │
    ├─ resolve latest OCP version via cincinnati-graph-data (gh CLI)
    ├─ assign slot → derive all identifiers
    ├─ register slot in /var/lib/shiftlet/slots  ← safe to 'delete' from here
    ├─ extract openshift-install from the release payload (oc adm release extract)
    ├─ define + start libvirt NAT network (with autostart)
    ├─ add /etc/hosts entries
    ├─ write agent-config.yaml + install-config.yaml
    ├─ build agent ISO  (openshift-install agent create image)
    ├─ launch VM via virt-install (with autostart)
    ├─ wait for OCP install  (openshift-install agent wait-for install-complete)
    ├─ copy kubeconfig → /var/lib/shiftlet/dev/kubeconfig
    └─ detach ISO from VM
```

The slot is registered before any external resources are created. If `create` fails at any point, `shiftlet delete <name>` can fully clean up.

## Version selection

`--version` queries the [cincinnati-graph-data](https://github.com/openshift/cincinnati-graph-data) repository via the `gh` CLI to find the latest stable release:

- `--version latest` — absolute latest stable Z across all Y-streams
- `--version 4.21` — latest Z in the 4.21 Y-stream
- `--release <image>` — use an explicit release image reference (no network lookup)

## State layout

```
/var/lib/shiftlet/
  slots                    # registry: one "slot=name" line per cluster
  dev/
    kubeconfig             # cluster kubeconfig (readable by installing user)
    exposed                # flag file: present if port forwarding is active
  hub/
    kubeconfig
    ...

/tmp/shiftlet-<name>/      # install-time working directory; not needed after install
```

## Prerequisites

- Linux host with libvirt/KVM (`virt-install`, `virsh`, `qemu-kvm`)
  - Fedora: `sudo dnf install @virtualization`
- `sudo` access (for virsh, /etc/hosts, iptables, /var/lib/shiftlet)
- A valid [OpenShift pull secret](https://console.redhat.com/openshift/install/pull-secret)
  - Set `REGISTRY_AUTH_FILE` to its path, or place it at `~/.docker/config.json`
- `oc` client (auto-installed if missing)
- `gh` CLI — only for `--version` flag (install from https://cli.github.com)
- Sufficient resources per cluster:
  - 8 vCPUs, 20 GB RAM, 100 GB disk (full cluster with operators)
  - 8 vCPUs, 12 GB RAM, 100 GB disk (plain OCP, no heavy operators)

## Installation

`shiftlet.sh` is a self-contained shell script with no build step. Copy or symlink it somewhere on your `$PATH`:

```bash
ln -s /path/to/shiftlet.sh ~/.local/bin/shiftlet
```

## Future work

- Local image mirror registry to speed up reinstalls
- ARM64 virt-install profile (`--os-variant` selection)
- `shiftlet status <name>` — cluster health check
- `shiftlet ssh <name>` — SSH into the node
