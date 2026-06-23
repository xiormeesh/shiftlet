#!/usr/bin/env bash
# Shared functions and logic. Sourced by the other scripts, not run directly.

# ── state ─────────────────────────────────────────────────────────────────────
DATA_DIR="/var/lib/shiftlet"
SLOTS_FILE="${DATA_DIR}/slots"

# ── network constants ─────────────────────────────────────────────────────────
SUBNET_BASE="192.168"
SUBNET_THIRD_BASE=133   # slot 0 → .133.x, slot 1 → .134.x, …
VM_IP_SUFFIX=80
MAX_SLOTS=10
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
die()  { echo "error: $*" >&2; exit 1; }
info() { echo "* $*"; }

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
}

# ── slot management ───────────────────────────────────────────────────────────
get_slot() {
    [[ -f "$SLOTS_FILE" ]] || return 0
    grep -m1 "^[0-9]\+=${1}$" "$SLOTS_FILE" 2>/dev/null | cut -d= -f1 || true
}

next_slot() {
    [[ -f "$SLOTS_FILE" ]] || { echo 0; return; }
    local i=0
    while grep -q "^${i}=" "$SLOTS_FILE" 2>/dev/null; do (( i++ )); done
    [[ $i -lt $MAX_SLOTS ]] || die "maximum of ${MAX_SLOTS} simultaneous clusters reached"
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

find_iso() {
    local assets=$1
    local iso
    iso=$(ls "${assets}"/agent.*.iso 2>/dev/null | head -1)
    [[ -n "$iso" ]] || die "install ISO not found in ${assets}"
    echo "$iso"
}

# ── port forwarding ───────────────────────────────────────────────────────────
apply_fw_rules() {
    local name=$1 vmIP=$2

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "warning: firewalld is active — iptables rules may be flushed on reload" >&2
        echo "         consider stopping firewalld or adding equivalent firewall-cmd rules" >&2
    fi

    info "Setting up port forwarding: LAN -> ${vmIP}"

    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-shiftlet.conf >/dev/null
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

    local tag="shiftlet-${name}"
    for port in 80 443 6443; do
        sudo iptables -t nat -A PREROUTING \
            -p tcp --dport "$port" \
            -m comment --comment "$tag" \
            -j DNAT --to-destination "${vmIP}:${port}"
        sudo iptables -t nat -A POSTROUTING \
            -d "$vmIP" -p tcp --dport "$port" \
            -m comment --comment "$tag" \
            -j MASQUERADE
        sudo iptables -A FORWARD \
            -d "$vmIP" -p tcp --dport "$port" \
            -m comment --comment "$tag" \
            -j ACCEPT
    done
}

remove_fw_rules() {
    local name=$1
    info "Removing port forwarding for '${name}'"
    local tmp
    tmp=$(mktemp)
    sudo iptables-save | grep -v -- "shiftlet-${name}" > "$tmp"
    sudo iptables-restore < "$tmp"
    rm -f "$tmp"
}

# ── connection instructions ───────────────────────────────────────────────────
print_connection_info() {
    local name=$1
    local domain lanIP hostname_fqdn kc
    domain=$(domain_for "$name")
    lanIP=$(lan_ip)
    hostname_fqdn=$(hostname)
    kc=$(kubeconfig "$name")

    echo ""
    echo "------------------------------------------------------------"
    echo "Cluster '${name}' is ready"
    echo ""
    echo "  Host: ${hostname_fqdn}  (${lanIP})"
    echo ""
    echo "  Add to /etc/hosts on the remote machine:"
    echo "    ${lanIP}  api.${domain}"
    echo "    ${lanIP}  console-openshift-console.apps.${domain}"
    echo "    ${lanIP}  oauth-openshift.apps.${domain}"
    echo ""
    echo "  Kubeconfig:"
    echo "    export KUBECONFIG=${kc}"
    echo ""
    echo "  Console:"
    echo "    https://console-openshift-console.apps.${domain}"
    echo ""
    echo "  Note: iptables rules do not survive reboots."
    echo "        Re-apply after reboot with: ./expose.sh <name>"
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

# ── create ────────────────────────────────────────────────────────────────────
create_cluster() {
    local name=$1 releaseImage=$2 memoryMB=$3 pullSecretFile=$4

    [[ -z "$(get_slot "$name")" ]] || die "cluster '${name}' already exists; run ./delete.sh first"

    local sshKeyFile=""
    if   [[ -f ~/.ssh/id_ed25519.pub ]]; then sshKeyFile=~/.ssh/id_ed25519.pub
    elif [[ -f ~/.ssh/id_rsa.pub     ]]; then sshKeyFile=~/.ssh/id_rsa.pub
    else
        info "Generating SSH key"
        ssh-keygen -N "" -t rsa -f ~/.ssh/id_rsa < /dev/null
        sshKeyFile=~/.ssh/id_rsa.pub
    fi

    local slot subnet vmIP vmMAC netMAC bridge network hostname domain assets baseDomain ocp_arch
    slot=$(next_slot)
    subnet=$(subnet_for "$slot")
    vmIP=$(vm_ip_for "$slot")
    vmMAC=$(vm_mac_for "$slot")
    netMAC=$(net_mac_for "$slot")
    bridge=$(bridge_for "$slot")
    network=$(net_name "$name")
    hostname=$(vm_hostname "$name")
    domain=$(domain_for "$name")
    assets=$(assets_dir "$name")
    baseDomain="shiftlet.local"
    ocp_arch=$(_ocp_arch)

    if [[ -d "$assets" ]] \
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

    # Register the slot before touching any external resource so a failed
    # install can always be cleaned up with ./delete.sh
    sudo mkdir -p "${DATA_DIR}/${name}"
    echo "${slot}=${name}" | sudo tee -a "$SLOTS_FILE" >/dev/null
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

    info "Writing install configs"
    cat > "${assets}/agent-config.yaml" << EOF
apiVersion: v1alpha1
metadata:
  name: ${name}
  namespace: shiftlet
rendezvousIP: ${vmIP}
EOF

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
    sudo virt-install \
        --connect qemu:///system \
        --name "$hostname" \
        --vcpus 8 \
        --memory "$memoryMB" \
        --disk size=100,bus=virtio,cache=none,io=native \
        --disk "path=${iso},device=cdrom,bus=sata" \
        --boot hd,cdrom \
        --import \
        --network "network=${network},mac=${vmMAC}" \
        --os-variant rhel9-unknown \
        --noautoconsole &

    while ! sudo virsh list --all 2>/dev/null | grep -q "[[:space:]]${hostname}[[:space:]].*running"; do
        echo "  waiting for VM to start..."
        sleep 5
    done

    sudo virsh autostart "$hostname"

    "${assets}/openshift-install" agent wait-for install-complete \
        --dir="$assets" --log-level=debug

    info "Saving kubeconfig"
    sudo cp "${assets}/auth/kubeconfig" "${DATA_DIR}/${name}/kubeconfig"
    sudo chmod 644 "${DATA_DIR}/${name}/kubeconfig"

    info "Saving kubeadmin password"
    sudo cp "${assets}/auth/kubeadmin-password" "${DATA_DIR}/${name}/kubeadmin-password"
    sudo chmod 644 "${DATA_DIR}/${name}/kubeadmin-password"

    info "Detaching install ISO"
    sudo virsh detach-disk "$hostname" "$iso" --config

    apply_fw_rules "$name" "$vmIP"

    local elapsed=$(( ($(date +%s) - start) / 60 ))
    echo ""
    echo "Installed in ${elapsed} minutes"
    print_connection_info "$name"
}

# ── delete ────────────────────────────────────────────────────────────────────
delete_cluster() {
    local name=$1

    local slot
    slot=$(get_slot "$name")
    [[ -n "$slot" ]] || die "cluster '${name}' not found"

    local network hostname domain assets
    network=$(net_name "$name")
    hostname=$(vm_hostname "$name")
    domain=$(domain_for "$name")
    assets=$(assets_dir "$name")

    remove_fw_rules "$name"

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

    sudo sed -i "/${domain}/d" /etc/hosts
    [[ -d "$assets" && "$assets" == *"shiftlet-"* ]] && rm -rf "$assets" || true
    sudo rm -rf "${DATA_DIR}/${name}"
    sudo sed -i "/^${slot}=${name}$/d" "$SLOTS_FILE"

    info "Cluster '${name}' deleted"
}

# ── list ──────────────────────────────────────────────────────────────────────
list_clusters() {
    if [[ ! -f "$SLOTS_FILE" ]] || [[ ! -s "$SLOTS_FILE" ]]; then
        echo "no clusters"
        return
    fi

    printf "%-15s  %-5s  %-22s  %s\n" NAME SLOT SUBNET KUBECONFIG
    while IFS='=' read -r slot name; do
        [[ -n "$slot" && -n "$name" ]] || continue
        printf "%-15s  %-5s  %-22s  %s\n" \
            "$name" "$slot" "$(subnet_for "$slot").0/24" "$(kubeconfig "$name")"
    done < "$SLOTS_FILE"
}
