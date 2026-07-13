#!/usr/bin/env bash
# Shared functions and logic. Sourced by the other scripts, not run directly.

# ── state ─────────────────────────────────────────────────────────────────────
DATA_DIR="/var/lib/shiftlet"
REGISTRY_FILE="${DATA_DIR}/clusters"

# ── network constants ─────────────────────────────────────────────────────────
SUBNET_BASE="192.168"
SUBNET_THIRD_BASE=133   # id 0 → .133.x, id 1 → .134.x, …
VM_IP_SUFFIX=80
MAX_CLUSTERS=10
OCP_RELEASE_BASE="quay.io/openshift-release-dev/ocp-release"

# ── architecture ──────────────────────────────────────────────────────────────
_arch() {
    case $(uname -m) in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

_ocp_arch() {
    case $(uname -m) in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo "[$(date '+%H:%M:%S')] error: $*" >&2; exit 1; }
info() { echo "[$(date '+%H:%M:%S')] $*"; }

# Load cluster configuration from a .env file.
# Sets NAME, VERSION, MEMORY_GB, PULL_SECRET in the caller's environment.
load_env() {
    local envfile=$1
    [[ -f "$envfile" ]] || die "env file not found: ${envfile}"
    set -a
    # shellcheck source=/dev/null
    source "$envfile"
    set +a
    PULL_SECRET="${PULL_SECRET/#~/$HOME}"   # expand leading ~
    [[ -n "${NAME:-}"        ]] || die "NAME not set in ${envfile}"
    [[ -n "${VERSION:-}"     ]] || die "VERSION not set in ${envfile}"
    [[ -n "${MEMORY_GB:-}"   ]] || die "MEMORY_GB not set in ${envfile}"
    [[ -n "${PULL_SECRET:-}" ]] || die "PULL_SECRET not set in ${envfile}"
    [[ -f "${PULL_SECRET}"   ]] || die "pull secret file not found: ${PULL_SECRET}"

    # Default NETWORK_MODE to NAT if unset
    NETWORK_MODE="${NETWORK_MODE:-NAT}"

    # Validate network mode
    if [[ ! "$NETWORK_MODE" =~ ^(NAT|bridge)$ ]]; then
        die "NETWORK_MODE must be 'NAT' or 'bridge', got: ${NETWORK_MODE}"
    fi

    # Bridge mode validation
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        [[ -n "${BRIDGE_VM_IP:-}" ]] || die "BRIDGE_VM_IP must be set in the env file when using bridge mode (e.g. BRIDGE_VM_IP=192.168.1.80)"
        command -v nmstatectl &>/dev/null \
            || die "bridge mode requires nmstate package: sudo dnf install nmstate"
        validate_bridge_mode >/dev/null
    fi
}

# ── cluster registry ──────────────────────────────────────────────────────────
get_cluster_id() {
    [[ -f "$REGISTRY_FILE" ]] || return 0
    grep -m1 "^[0-9]\+=${1}$" "$REGISTRY_FILE" 2>/dev/null | cut -d= -f1 || true
}

next_cluster_id() {
    [[ -f "$REGISTRY_FILE" ]] || { echo 0; return; }
    local i=0
    while grep -q "^${i}=" "$REGISTRY_FILE" 2>/dev/null; do (( i++ )); done
    [[ $i -lt $MAX_CLUSTERS ]] || die "maximum of ${MAX_CLUSTERS} simultaneous clusters reached"
    echo "$i"
}

# ── identifier derivations ────────────────────────────────────────────────────
subnet_for()   { echo "${SUBNET_BASE}.$(( SUBNET_THIRD_BASE + $1 ))"; }
vm_ip_for()    { echo "$(subnet_for "$1").${VM_IP_SUFFIX}"; }
vm_mac_for()   { printf "52:54:00:93:72:%02x" $(( 0x25 + $1 )); }
net_mac_for()  { printf "52:54:00:94:43:%02x" $(( 0x21 + $1 )); }
bridge_for()   { printf "virbr-shl%d" "$1"; }
net_name()     { echo "shiftlet-${1}"; }
vm_hostname()  { echo "shiftlet-${1}"; }
domain_for()   { echo "${1}.shiftlet.local"; }
assets_dir()   { echo "/tmp/shiftlet-${1}"; }
kubeconfig()   { echo "${DATA_DIR}/${1}/kubeconfig"; }

lan_ip() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' \
        || hostname -I | awk '{print $1}'
}

# ── bridge mode validation ────────────────────────────────────────────────────
validate_bridge_mode() {
    # Check if br0 exists
    if ! ip link show br0 &>/dev/null; then
        die "bridge mode requires bridge device 'br0' but it was not found

Create the bridge first (see README.md - Bridge Setup section):
  sudo nmcli connection add type bridge ifname br0 con-name br0
  sudo nmcli connection add type ethernet slave-type bridge \\
      master br0 ifname <your-eth-interface> con-name bridge-slave-eth0
  sudo nmcli connection up br0"
    fi

    # Check bridge is UP
    if ! ip link show br0 | grep -q "state UP"; then
        die "bridge device br0 exists but is not UP
Activate it with: sudo nmcli connection up br0"
    fi

    # Verify bridge has an enslaved interface
    local bridge_ports
    bridge_ports=$(ip link show type bridge_slave 2>/dev/null | grep -oP '^\d+: \K\w+' | head -1)
    if [[ -z "$bridge_ports" ]]; then
        die "bridge br0 has no enslaved interfaces
Add your wired interface to the bridge (see README.md)"
    fi

    echo "br0"
}

find_iso() {
    local assets=$1
    local iso
    iso=$(ls "${assets}"/agent.*.iso 2>/dev/null | head -1)
    [[ -n "$iso" ]] || die "install ISO not found in ${assets}"
    echo "$iso"
}


# ── connection instructions ───────────────────────────────────────────────────
print_connection_info() {
    local name=$1
    local domain lanIP vmIP kc password cid
    domain=$(domain_for "$name")
    lanIP=$(lan_ip)
    cid=$(get_cluster_id "$name")
    kc=$(kubeconfig "$name")
    password="<not yet available>"
    [[ -f "${DATA_DIR}/${name}/kubeadmin-password" ]] \
        && password=$(sudo cat "${DATA_DIR}/${name}/kubeadmin-password")

    echo ""
    echo "------------------------------------------------------------"
    echo "Cluster '${name}' is ready"
    echo ""
    echo "  Kubeconfig:"
    echo "    export KUBECONFIG=${kc}"
    echo ""
    echo "  Console:"
    echo "    https://console-openshift-console.apps.${domain}"
    echo "    Login: kubeadmin / ${password}"
    echo ""

    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        local vmIP="${BRIDGE_VM_IP}"
        echo "  VM IP on LAN: ${vmIP}"
        echo ""
        echo "  To access this cluster from another host on the LAN:"
        echo "    1. Add to /etc/hosts on the other host:"
        echo "         ${vmIP}  api.${domain} console-openshift-console.apps.${domain} oauth-openshift.apps.${domain}"
        echo ""
        echo "    2. Copy kubeconfig to the other host:"
        echo "         scp ${kc} <user>@<other-host>:~/${name}-kubeconfig"
        echo "         export KUBECONFIG=~/${name}-kubeconfig"
        echo "         # To persist across shell sessions:"
        echo "         echo 'export KUBECONFIG=~/${name}-kubeconfig' >> ~/.bashrc"
        echo "         source ~/.bashrc"
    else
        echo "  Cluster is accessible from this host only (NAT mode)."
    fi
    echo "------------------------------------------------------------"
}

# ── capabilities ─────────────────────────────────────────────────────────────
# Known capabilities (stable since OCP 4.14). Verify with:
#   openshift-install explain installconfig.capabilities.additionalEnabledCapabilities
# baremetal marketplace openshift-samples Console Insights Storage CSISnapshot
# NodeTuning MachineAPI Build DeploymentConfig ImageRegistry
# OperatorLifecycleManager CloudCredential Ingress
#
# CAPABILITIES env var: space-separated list; unset = default dev set below.
_capabilities_yaml() {
    local caps="${CAPABILITIES:-Ingress OperatorLifecycleManager marketplace Console}"
    if [[ -z "$caps" ]]; then
        echo "capabilities:
  baselineCapabilitySet: None"
        return
    fi
    local yaml
    yaml="capabilities:
  baselineCapabilitySet: None
  additionalEnabledCapabilities:"
    for cap in $caps; do
        yaml+="
    - ${cap}"
    done
    echo "$yaml"
}

# ── version resolution ────────────────────────────────────────────────────────
# Accepts "latest", "X.Y", or a full "X.Y.Z" version string.
# Returns just the version number, e.g. "4.21.18".
resolve_version() {
    local ver=$1

    if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ver"
        return
    fi

    command -v gh &>/dev/null \
        || die "'gh' CLI required for version lookup (install from https://cli.github.com)"

    local channel version
    if [[ "$ver" == "latest" ]]; then
        channel=$(gh api repos/openshift/cincinnati-graph-data/contents/channels \
            --jq '[.[].name | select(startswith("stable-"))] | .[]' \
            | tr -d '"' | sort -V | tail -1)
    elif [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
        channel="stable-${ver}.yaml"
    else
        die "unsupported version format '${ver}' — use X.Y.Z, X.Y, or 'latest'"
    fi

    version=$(gh api "repos/openshift/cincinnati-graph-data/contents/channels/${channel}" \
        --jq '.content' | base64 -d \
        | grep -E '^\s*-\s+[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | tr -d ' -')

    [[ -n "$version" ]] || die "could not resolve version from channel: ${channel}"
    echo "$version"
}

# Returns the full release image reference, e.g. "quay.io/…:4.21.18-x86_64".
resolve_release_image() {
    echo "${OCP_RELEASE_BASE}:$(resolve_version "$1")-$(_arch)"
}

# ── network creation ─────────────────────────────────────────────────────────
create_nat_network() {
    local name=$1 network=$2 subnet=$3 vmIP=$4 vmMAC=$5 netMAC=$6
    local bridge domain assets

    # Derive identifiers from name
    local cid
    cid=$(get_cluster_id "$name")
    bridge=$(bridge_for "$cid")
    domain=$(domain_for "$name")
    assets=$(assets_dir "$name")

    info "Creating libvirt network ${network} (${subnet}.0/24)"
    cat > "${assets}/${network}.xml" << NETXML
<network>
  <name>${network}</name>
  <forward mode="nat">
    <nat>
      <port start="1024" end="65535"/>
    </nat>
  </forward>
  <bridge name="${bridge}" stp="on" delay="0"/>
  <mac address="${netMAC}"/>
  <domain name="${domain}" localOnly="yes"/>
  <dns>
    <host ip="${vmIP}">
      <hostname>master-0.${domain}</hostname>
      <hostname>api.${domain}</hostname>
    </host>
  </dns>
  <ip address="${subnet}.1" netmask="255.255.255.0">
    <dhcp>
      <range start="${subnet}.80" end="${subnet}.254"/>
      <host mac="${vmMAC}" name="master-0" ip="${vmIP}"/>
    </dhcp>
  </ip>
</network>
NETXML

    sudo virsh net-define "${assets}/${network}.xml"
    sudo virsh net-start "$network"
    sudo virsh net-autostart "$network"

    info "Adding DNS entries to /etc/hosts"
    echo "${vmIP} api.${domain} console-openshift-console.apps.${domain} oauth-openshift.apps.${domain}" \
        | sudo tee -a /etc/hosts >/dev/null
}

create_bridge_network() {
    local name=$1 vmIP=$2 vmMAC=$3 bridge=$4
    local domain lanIP lanSubnet

    domain=$(domain_for "$name")

    # Get LAN subnet from host IP (first 3 octets)
    lanIP=$(lan_ip)
    lanSubnet=$(echo "$lanIP" | cut -d. -f1-3)

    info "Using bridge ${bridge} for VM networking"
    info "VM will use IP: ${vmIP} (LAN subnet: ${lanSubnet}.0/24)"

    # No libvirt network creation needed - virt-install will use bridge directly

    info "Adding DNS entries to /etc/hosts"
    echo "${vmIP} api.${domain} console-openshift-console.apps.${domain} oauth-openshift.apps.${domain}" \
        | sudo tee -a /etc/hosts >/dev/null
}

# ── create ────────────────────────────────────────────────────────────────────
create_cluster() {
    local name=$1 releaseImage=$2 memoryMB=$3 pullSecretFile=$4

    [[ -z "$(get_cluster_id "$name")" ]] || die "cluster '${name}' already exists; run ./delete.sh first"

    [[ $memoryMB -ge 16384 ]] \
        || die "minimum 16 GB RAM required for master nodes (got $(( memoryMB / 1024 )) GB)"

    for cmd in virsh virt-install qemu-kvm; do
        command -v "$cmd" &>/dev/null \
            || die "'${cmd}' not found — install with: sudo dnf install @virtualization"
    done

    local sshKeyFile=""
    if   [[ -f ~/.ssh/id_ed25519.pub ]]; then sshKeyFile=~/.ssh/id_ed25519.pub
    elif [[ -f ~/.ssh/id_rsa.pub     ]]; then sshKeyFile=~/.ssh/id_rsa.pub
    else
        info "Generating SSH key"
        ssh-keygen -N "" -t rsa -f ~/.ssh/id_rsa < /dev/null
        sshKeyFile=~/.ssh/id_rsa.pub
    fi

    local cid subnet vmIP vmMAC netMAC bridge network hostname domain assets baseDomain ocp_arch
    cid=$(next_cluster_id)
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        # Bridge mode: use explicit VM IP from env file
        vmIP="$BRIDGE_VM_IP"
        subnet=$(echo "$vmIP" | cut -d. -f1-3)
    else
        # NAT mode: isolated subnet
        subnet=$(subnet_for "$cid")
        vmIP=$(vm_ip_for "$cid")
    fi
    vmMAC=$(vm_mac_for "$cid")
    netMAC=$(net_mac_for "$cid")
    bridge=$(bridge_for "$cid")
    network=$(net_name "$name")
    hostname=$(vm_hostname "$name")
    domain=$(domain_for "$name")
    assets=$(assets_dir "$name")
    baseDomain="shiftlet.local"
    ocp_arch=$(_ocp_arch)

    if [[ -d "$assets" ]] \
        || [[ -d "${DATA_DIR}/${name}" ]] \
        || sudo virsh list --all --name 2>/dev/null | grep -q "^${hostname}$" \
        || sudo virsh net-list --all --name 2>/dev/null | grep -q "^${network}$"; then
        die "stale resources found for '${name}'; run: ./delete.sh ${name}"
    fi

    local start
    start=$(date +%s)

    # Keep sudo credentials alive during the long install wait (~40 min).
    # Default sudo timeout is 5 minutes; without this, post-install sudo
    # calls would hang waiting for a password.
    while true; do sudo -n -v 2>/dev/null; sleep 240; done &
    SUDO_KEEPER_PID=$!
    trap "kill $SUDO_KEEPER_PID 2>/dev/null" EXIT

    sudo mkdir -p "${DATA_DIR}/${name}"
    echo "${cid}=${name}" | sudo tee -a "$REGISTRY_FILE" >/dev/null
    mkdir "$assets"

    if ! command -v oc &>/dev/null; then
        info "Installing oc client"
        curl -sL "https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/stable/openshift-client-linux.tar.gz" \
            | sudo tar -U -C /usr/local/bin -xzf -
    fi

    info "Extracting openshift-install from release payload"
    oc adm release extract \
        --registry-config="$pullSecretFile" \
        --command=openshift-install \
        --to="$assets" \
        "$releaseImage"

    local bridge_device=""
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        bridge_device=$(validate_bridge_mode)
        create_bridge_network "$name" "$vmIP" "$vmMAC" "$bridge_device"
    else
        create_nat_network "$name" "$network" "$subnet" "$vmIP" "$vmMAC" "$netMAC"
    fi

    info "Writing install configs"

    # Build agent-config with NMState for static IP in bridge mode
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        cat > "${assets}/agent-config.yaml" << EOF
apiVersion: v1alpha1
metadata:
  name: ${name}
  namespace: shiftlet
rendezvousIP: ${vmIP}
hosts:
  - hostname: ${hostname}
    interfaces:
      - name: enp1s0
        macAddress: ${vmMAC}
    networkConfig:
      interfaces:
        - name: enp1s0
          type: ethernet
          state: up
          mac-address: ${vmMAC}
          ipv4:
            enabled: true
            address:
              - ip: ${vmIP}
                prefix-length: 24
            dhcp: false
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - ${subnet}.1
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${subnet}.1
            next-hop-interface: enp1s0
            table-id: 254
EOF
    else
        cat > "${assets}/agent-config.yaml" << EOF
apiVersion: v1alpha1
metadata:
  name: ${name}
  namespace: shiftlet
rendezvousIP: ${vmIP}
EOF
    fi

    local pullSecret sshKey capYaml
    pullSecret=$(cat "$pullSecretFile")
    sshKey=$(cat "$sshKeyFile")
    capYaml=$(_capabilities_yaml)

    cat > "${assets}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ${baseDomain}
metadata:
  name: ${name}
  namespace: shiftlet
controlPlane:
  architecture: ${ocp_arch}
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 1
compute:
  - architecture: ${ocp_arch}
    hyperthreading: Enabled
    name: worker
    platform: {}
    replicas: 0
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: ${subnet}.0/24
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
    none: {}
${capYaml}
pullSecret: '${pullSecret}'
sshKey: ${sshKey}
EOF

    info "Building install ISO"
    "${assets}/openshift-install" agent create image --dir="$assets" --log-level=debug

    local iso
    iso=$(find_iso "$assets")

    info "Starting VM"
    sudo chmod a+x "$assets"

    # Choose network parameter based on mode
    local network_param
    if [[ "$NETWORK_MODE" == "bridge" ]]; then
        network_param="bridge=${bridge_device},mac=${vmMAC}"
    else
        network_param="network=${network},mac=${vmMAC}"
    fi

    sudo virt-install \
        --connect qemu:///system \
        --name "$hostname" \
        --vcpus 8 \
        --memory "$memoryMB" \
        --disk path=/var/lib/libvirt/images/${hostname}.qcow2,size=100,bus=virtio,cache=none,io=native \
        --disk "path=${iso},device=cdrom,bus=sata" \
        --boot hd,cdrom \
        --import \
        --network "$network_param" \
        --os-variant rhel9-unknown \
        --noautoconsole

    sudo virsh autostart "$hostname"

    local attempt=1
    while ! "${assets}/openshift-install" agent wait-for install-complete \
        --dir="$assets" --log-level=debug; do
        (( attempt++ ))
        if [[ $attempt -gt 3 ]]; then
            die "install did not complete after 3 attempts"
        fi
        info "Install not yet complete, retrying (attempt ${attempt}/3)..."
    done

    info "Saving kubeconfig"
    sudo cp "${assets}/auth/kubeconfig" "${DATA_DIR}/${name}/kubeconfig"
    sudo chmod 644 "${DATA_DIR}/${name}/kubeconfig"

    info "Saving kubeadmin password"
    sudo cp "${assets}/auth/kubeadmin-password" "${DATA_DIR}/${name}/kubeadmin-password"
    sudo chmod 644 "${DATA_DIR}/${name}/kubeadmin-password"

    info "Detaching install ISO"
    sudo virsh detach-disk "$hostname" "$iso" --config

    local elapsed=$(( ($(date +%s) - start) / 60 ))
    echo ""
    echo "Installed in ${elapsed} minutes"

    print_connection_info "$name"
}

# ── delete ────────────────────────────────────────────────────────────────────
delete_cluster() {
    local name=$1

    local cid
    cid=$(get_cluster_id "$name")

    local network hostname domain assets
    network=$(net_name "$name")
    hostname=$(vm_hostname "$name")
    domain=$(domain_for "$name")
    assets=$(assets_dir "$name")

    # Check that at least something exists to clean up
    if [[ -z "$cid" ]] \
        && ! sudo virsh list --all --name 2>/dev/null | grep -q "^${hostname}$" \
        && ! sudo virsh net-list --all --name 2>/dev/null | grep -q "^${network}$" \
        && [[ ! -d "$assets" ]] \
        && [[ ! -d "${DATA_DIR}/${name}" ]]; then
        die "cluster '${name}' not found"
    fi

    if sudo virsh list --all --name 2>/dev/null | grep -q "^${hostname}$"; then
        info "Destroying VM ${hostname}"
        sudo virsh list --name 2>/dev/null | grep -q "^${hostname}$" \
            && sudo virsh destroy "$hostname" || true
        sudo virsh undefine "$hostname" --remove-all-storage
    fi

    if sudo virsh net-list --all --name 2>/dev/null | grep -q "^${network}$"; then
        info "Destroying network ${network}"
        sudo virsh net-list --name 2>/dev/null | grep -q "^${network}$" \
            && sudo virsh net-destroy "$network" || true
        sudo virsh net-undefine "$network"
    fi

    info "Removing DNS entries for ${domain} from /etc/hosts"
    sudo sed -i "/${domain}/d" /etc/hosts
    [[ -d "$assets" && "$assets" == *"shiftlet-"* ]] && rm -rf "$assets" || true
    sudo rm -rf "${DATA_DIR}/${name}"
    [[ -n "$cid" ]] && sudo sed -i "/^${cid}=${name}$/d" "$REGISTRY_FILE"

    info "Cluster '${name}' deleted"
}

# ── list ──────────────────────────────────────────────────────────────────────
list_clusters() {
    if [[ ! -f "$REGISTRY_FILE" ]] || [[ ! -s "$REGISTRY_FILE" ]]; then
        echo "no clusters"
        return
    fi

    printf "%-15s  %-3s  %-22s  %-45s  %s\n" NAME ID SUBNET KUBECONFIG PASSWORD
    while IFS='=' read -r cid name; do
        [[ -n "$cid" && -n "$name" ]] || continue
        local password="-"
        [[ -f "${DATA_DIR}/${name}/kubeadmin-password" ]] \
            && password=$(sudo cat "${DATA_DIR}/${name}/kubeadmin-password")
        printf "%-15s  %-3s  %-22s  %-45s  %s\n" \
            "$name" "$cid" "$(subnet_for "$cid").0/24" "$(kubeconfig "$name")" "$password"
    done < "$REGISTRY_FILE"
}
