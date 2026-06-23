# Shiftlet v2 — Design Spec

## Problem

Shiftlet v1 creates and manages local SNO clusters for development. It needs to support the multicluster agentic OLS architecture, which requires:

- A hub cluster (full OLS + agentic stack + lightspeed-hub) that can reach spoke cluster APIs
- One or more spoke clusters (barebones) whose APIs are reachable from the hub
- Primary path: hub on one laptop, spoke on another, connected via ethernet
- Fallback path: hub + spoke on the same laptop (requires sufficient RAM for both)

## Scope

Shiftlet is a **cluster lifecycle tool**. It creates, exposes, and deletes local SNO clusters. It does NOT handle multicluster OLS registration — that's the job of `ols-hub register cluster`. Shiftlet makes clusters exist and makes their APIs reachable; OLS tooling connects them.

## What stays the same

- **Slot system** — numeric slots (0–9) derive all identifiers: subnet `192.168.(133+slot).0/24`, VM IP `.80`, MACs, bridge name. Registry at `/var/lib/shiftlet/slots`.
- **Isolated NAT per cluster** — each cluster gets its own libvirt NAT network. No shared bridges.
- **Env files as profiles** — `hub.env`, `spoke.env`, `dev.env` are the cluster config. Editable on disk, not generated.
- **Capabilities mechanism** — `CAPABILITIES` env var controls `baselineCapabilitySet: None` + `additionalEnabledCapabilities`.
- **Version resolution** — `latest`, `X.Y`, `X.Y.Z` via Cincinnati graph data + `gh` CLI.
- **State layout** — `/var/lib/shiftlet/<name>/` for persistent state, `/tmp/shiftlet-<name>/` for install-time assets.
- **common.sh as the engine** — all logic lives here. Wrapper scripts are thin entry points.

## What changes

### 1. Rename wrapper scripts

| Old | New | Reason |
|-----|-----|--------|
| `setup.sh` | `create.sh` | Matches cloud CLI conventions (AWS, GCP, Azure, ROSA) |
| `cleanup.sh` | `delete.sh` | Same |

`expose.sh`, `list.sh`, `latest.sh` keep their names.

### 2. Save kubeadmin password

After install, copy `<assets>/auth/kubeadmin-password` alongside the kubeconfig:

```
/var/lib/shiftlet/<name>/
  kubeconfig
  kubeadmin-password
```

Print the password in the post-create connection info. Include it in `list.sh` output.

### 3. Same-host inter-cluster connectivity

**Problem:** When two clusters exist on the same host, their VMs are in separate libvirt NAT networks. Libvirt's default iptables rules REJECT forwarding between bridges, so the VMs can't reach each other — even though the host has interfaces on both subnets.

**Solution:** When creating a cluster, if other shiftlet clusters already exist on the host, add iptables FORWARD ACCEPT rules between all shiftlet bridge pairs:

```bash
iptables -I FORWARD -i virbr-shl0 -o virbr-shl1 -j ACCEPT
iptables -I FORWARD -i virbr-shl1 -o virbr-shl0 -j ACCEPT
```

Also enable `ip_forward=1` (already done by `expose`; move to `create` so it's always set when multiple clusters exist).

This is automatic — no new commands needed. When a cluster is deleted, its rules are removed.

**Why this works:** Each VM's default gateway is the host's bridge interface (e.g., `192.168.133.1`). With ip_forward and ACCEPT rules, the host routes traffic between bridges. VM at `192.168.133.80` can reach `192.168.134.80` through the host transparently.

### 4. Improved `expose.sh` output

After setting up port forwarding, print complete cross-host setup instructions:

```
------------------------------------------------------------
Cluster 'hub' exposed on LAN

  This host: workstation (192.168.1.100)

  To reach this cluster from another machine, add to /etc/hosts:
    192.168.1.100  api.hub.shiftlet.local
    192.168.1.100  console-openshift-console.apps.hub.shiftlet.local
    192.168.1.100  oauth-openshift.apps.hub.shiftlet.local

  Kubeconfig (copy to remote machine for oc access):
    /var/lib/shiftlet/hub/kubeconfig

  Console:
    https://console-openshift-console.apps.hub.shiftlet.local
    Login: kubeadmin / <password>

  Note: iptables rules do not survive reboots.
        Re-apply with: ./expose.sh hub
------------------------------------------------------------
```

### 5. Always apply port forwarding after create

Currently `create_cluster()` unconditionally calls `apply_fw_rules`. Keep this behavior — clusters are always exposed on the LAN by default. This supports the primary cross-host path without an extra step.

If a user only wants local access, they can skip this or we can add an env var (`EXPOSE=false`) later. Not needed now.

## File structure (after changes)

```
src/shiftlet/
  common.sh          # all logic: slot mgmt, networking, lifecycle, version resolution
  create.sh          # ./create.sh <cluster.env>
  delete.sh          # ./delete.sh <cluster.env|name>
  expose.sh          # ./expose.sh <cluster.env|name>  (re-apply after reboot)
  list.sh            # ./list.sh
  latest.sh          # ./latest.sh [X.Y|latest]
  hub.env            # hub profile: 20GB RAM, full capabilities
  spoke.env          # spoke profile: 12GB RAM, minimal capabilities
  dev.env            # generic dev profile
  DESIGN.md          # this document's predecessor (update or replace)
  .gitignore         # excludes *.env
```

## Env file format (unchanged)

```bash
NAME=hub
VERSION=4.21.5
MEMORY_GB=20
PULL_SECRET=~/.config/openshift/pull-secret
CAPABILITIES="Ingress OperatorLifecycleManager marketplace Console MachineAPI Storage"
```

Capabilities differ per profile:
- **hub.env**: `Ingress OperatorLifecycleManager marketplace Console MachineAPI Storage` — enough for MCE/ACM and the OLS hub layer
- **spoke.env**: `Ingress OperatorLifecycleManager` — minimal, just needs a working API server
- **dev.env**: empty string (absolute minimum, `baselineCapabilitySet: None` with no additions)

## Networking scenarios

### Scenario 1: Single cluster, local development

```
./create.sh dev.env
export KUBECONFIG=/var/lib/shiftlet/dev/kubeconfig
oc get nodes
```

Host can reach the cluster. No other machines can (unless exposed).

### Scenario 2: Hub + spoke on same host (fallback)

```
./create.sh hub.env      # slot 0, subnet 192.168.133.0/24
./create.sh spoke.env    # slot 1, subnet 192.168.134.0/24
                         # inter-bridge forwarding added automatically
```

Hub VM (192.168.133.80) can reach spoke VM (192.168.134.80) and vice versa through the host. No expose needed for inter-cluster communication on the same host.

```
laptop
├── virbr-shl0 (192.168.133.1) ── hub VM (192.168.133.80)
│         ↕  iptables FORWARD ACCEPT
├── virbr-shl1 (192.168.134.1) ── spoke VM (192.168.134.80)
```

### Scenario 3: Hub + spoke on different hosts (primary)

```
# Laptop A (192.168.1.100):
./create.sh hub.env      # creates + exposes on LAN automatically

# Laptop B (192.168.1.101):
./create.sh spoke.env    # creates + exposes on LAN automatically
```

Both clusters are reachable from both laptops via their LAN IPs.

Setup on laptop A (to reach spoke on laptop B):
```
# Add to /etc/hosts on laptop A:
192.168.1.101  api.spoke.shiftlet.local
```

Setup on laptop B (to reach hub on laptop A):
```
# Add to /etc/hosts on laptop B:
192.168.1.100  api.hub.shiftlet.local
```

Then register via OLS tooling:
```
ols-hub register cluster \
    --name spoke \
    --api-server https://api.spoke.shiftlet.local:6443 \
    --kubeconfig <spoke-kubeconfig>
```

```
host A (LAN IP A)                           host B (LAN IP B)
├── virbr-shl0 ── hub VM                   ├── virbr-shl0 ── spoke VM
│   (192.168.133.80)                        │   (192.168.133.80)
│                                           │
├── LAN:6443 ─DNAT─► hub:6443              ├── LAN:6443 ─DNAT─► spoke:6443
│              ▲                            │              ▲
│              │         ethernet           │              │
└──────────────┼────────────────────────────┼──────────────┘
               └────── both reachable ──────┘
```

## Changes to common.sh

### New function: `sync_inter_bridge_rules()`

Called after creating or deleting a cluster. Reads all active slots, generates FORWARD ACCEPT rules for every bridge pair, and applies them idempotently (tagged with `shiftlet-interbridge` comment for easy removal).

```bash
sync_inter_bridge_rules() {
    # Remove all existing inter-bridge rules
    local tmp=$(mktemp)
    sudo iptables-save | grep -v "shiftlet-interbridge" > "$tmp"
    sudo iptables-restore < "$tmp"
    rm -f "$tmp"

    # Collect active bridges
    local bridges=()
    while IFS='=' read -r slot name; do
        [[ -n "$slot" && -n "$name" ]] || continue
        bridges+=("$(bridge_for "$slot")")
    done < "$SLOTS_FILE"

    # If 2+ clusters, enable ip_forward and add pairwise ACCEPT rules
    if [[ ${#bridges[@]} -ge 2 ]]; then
        echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-shiftlet.conf >/dev/null
        sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
        for (( i=0; i<${#bridges[@]}; i++ )); do
            for (( j=i+1; j<${#bridges[@]}; j++ )); do
                sudo iptables -I FORWARD \
                    -i "${bridges[$i]}" -o "${bridges[$j]}" \
                    -m comment --comment "shiftlet-interbridge" -j ACCEPT
                sudo iptables -I FORWARD \
                    -i "${bridges[$j]}" -o "${bridges[$i]}" \
                    -m comment --comment "shiftlet-interbridge" -j ACCEPT
            done
        done
    fi
}
```

### New: sudo keepalive

The install wait (`openshift-install agent wait-for install-complete`) takes ~40 minutes. Sudo credentials expire after 5 minutes by default, which would cause post-install sudo calls to hang waiting for a password. A background loop refreshes the credential:

```bash
while true; do sudo -n -v 2>/dev/null; sleep 240; done &
SUDO_KEEPER_PID=$!
trap "kill $SUDO_KEEPER_PID 2>/dev/null" EXIT
```

Started at the beginning of `create_cluster()`, killed on exit (success or failure).

### Modified: `create_cluster()`

- Start sudo keepalive before the long install wait
- Copy `kubeadmin-password` alongside kubeconfig
- Call `sync_inter_bridge_rules()` after VM is running

### Modified: `delete_cluster()`

- Call `sync_inter_bridge_rules()` after removing the cluster's slot

### Modified: `print_connection_info()`

- Include kubeadmin password
- Improve cross-host /etc/hosts instructions

### Modified: `list_clusters()`

- Add kubeadmin password column (or print it on a second line per cluster)

## Out of scope

- Multicluster OLS registration (`ols-hub register`) — OLS tooling's job
- Automating /etc/hosts on remote machines — print instructions, user does it
- Persisting iptables rules across reboots — `expose.sh` is idempotent, re-run after reboot
- Image mirroring / offline installs
- Non-Linux hosts
- Local image mirror registry to speed up reinstalls (likely future work)
- `shiftlet ssh <name>` — future work
- `shiftlet status <name>` — future work
