#!/usr/bin/env bash
#
# proxmox_backup_s3.sh
# Full backup: VMs + host network config + firewall + NAT + DNS + SDN
# Process: backup VM → upload → next VM → then upload host network bundle

set -euo pipefail

# ─── Load config ───
CONFIG_FILE="/etc/proxmox-backup-s3.conf"
[[ -f "$CONFIG_FILE" ]] && { set -a; source "$CONFIG_FILE"; set +a; }

# ─── Defaults ───
S3_BUCKET="${S3_BUCKET:-s3://my-proxmox-backups}"
S3_ENDPOINT="${S3_ENDPOINT:-}"  # e.g. https://s3.wasabisys.com, https://s3.us-east-1.wasabisys.com
S3_PREFIX="${S3_PREFIX:-backups/$(hostname)/$(date +%Y/%m/%d)}"
BACKUP_DIR="${BACKUP_DIR:-/var/tmp/proxmox-backups}"
BACKUP_MODE="${BACKUP_MODE:-snapshot}"
COMPRESS="${COMPRESS:-zstd}"
STORAGE="${STORAGE:-}"
KEEP_LOCAL="${KEEP_LOCAL:-false}"
LOG_DIR="${LOG_DIR:-/var/log/proxmox-backup-s3}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOGFILE="${LOG_DIR}/backup-${TIMESTAMP}.log"
NETWORK_BUNDLE_DIR="${BACKUP_DIR}/network-config-${TIMESTAMP}"

mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$NETWORK_BUNDLE_DIR"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ok()   { log "✅  $*"; }
warn() { log "⚠️  $*"; }
fail() { log "❌  $*"; }

# ─── S3 endpoint helper ───
# Builds endpoint args for S3-compatible providers (Wasabi, MinIO, Backblaze B2, etc.)
S3_ENDPOINT_ARGS=()
[[ -n "$S3_ENDPOINT" ]] && S3_ENDPOINT_ARGS=(--endpoint-url "$S3_ENDPOINT")

aws_s3() { aws s3 "${S3_ENDPOINT_ARGS[@]}" "$@"; }

# ─── Preflight ───
for cmd in vzdump pvesh aws; do
    command -v "$cmd" &>/dev/null || { fail "Missing: $cmd"; exit 1; }
done
aws_s3 ls "${S3_BUCKET}" &>/dev/null || { fail "Cannot access ${S3_BUCKET}"; exit 1; }
ok "S3 access verified${S3_ENDPOINT:+ (endpoint: $S3_ENDPOINT)}"

# Clean old logs
[[ "$LOG_RETENTION_DAYS" -gt 0 ]] && \
    find "$LOG_DIR" -name "backup-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════
#  PHASE 1: Backup Host Network Configuration (IPv4, IPv6, NAT, FW)
# ══════════════════════════════════════════════════════════════════════

backup_host_network() {
    log "════════════════════════════════════════════"
    log "  PHASE 1: Host Network & Firewall Config"
    log "════════════════════════════════════════════"

    local NET_DIR="$NETWORK_BUNDLE_DIR"
    mkdir -p "${NET_DIR}/firewall" "${NET_DIR}/vm-configs" "${NET_DIR}/sdn" "${NET_DIR}/cluster"

    # ── 1. Network interfaces (bridges, bonds, VLANs, IPv4/IPv6) ──
    log "Backing up network interfaces..."
    cp -a /etc/network/interfaces "${NET_DIR}/" 2>/dev/null || true
    [[ -d /etc/network/interfaces.d ]] && cp -a /etc/network/interfaces.d "${NET_DIR}/" 2>/dev/null || true
    ok "Network interfaces saved"

    # ── 2. iptables rules (IPv4 NAT, MASQUERADE, port forwards) ──
    log "Backing up iptables (IPv4) rules..."
    iptables-save  > "${NET_DIR}/iptables-v4.rules"  2>/dev/null || true
    ok "IPv4 iptables saved"

    # ── 3. ip6tables rules (IPv6 firewall) ──
    log "Backing up ip6tables (IPv6) rules..."
    ip6tables-save > "${NET_DIR}/iptables-v6.rules"  2>/dev/null || true
    ok "IPv6 ip6tables saved"

    # ── 4. nftables (if used) ──
    if command -v nft &>/dev/null; then
        log "Backing up nftables ruleset..."
        nft list ruleset > "${NET_DIR}/nftables.rules" 2>/dev/null || true
        [[ -f /etc/nftables.conf ]] && cp /etc/nftables.conf "${NET_DIR}/" 2>/dev/null || true
        ok "nftables saved"
    fi

    # ── 5. Proxmox firewall configs ──
    log "Backing up Proxmox firewall configs..."
    [[ -f /etc/pve/firewall/cluster.fw ]] && \
        cp /etc/pve/firewall/cluster.fw "${NET_DIR}/firewall/" 2>/dev/null || true
    # Per-VM firewall files
    for fw in /etc/pve/firewall/*.fw; do
        [[ -f "$fw" ]] && cp "$fw" "${NET_DIR}/firewall/" 2>/dev/null || true
    done
    # Per-node firewall
    [[ -f /etc/pve/local/host.fw ]] && \
        cp /etc/pve/local/host.fw "${NET_DIR}/firewall/" 2>/dev/null || true
    ok "Proxmox firewall configs saved"

    # ── 6. All VM/CT configuration files (NIC, IP, bridge, VLAN, MAC) ──
    log "Backing up all VM/CT config files..."
    for conf in /etc/pve/qemu-server/*.conf; do
        [[ -f "$conf" ]] && cp "$conf" "${NET_DIR}/vm-configs/" 2>/dev/null || true
    done
    for conf in /etc/pve/lxc/*.conf; do
        [[ -f "$conf" ]] && cp "$conf" "${NET_DIR}/vm-configs/" 2>/dev/null || true
    done
    ok "VM/CT configs saved ($(ls "${NET_DIR}/vm-configs/" 2>/dev/null | wc -l) files)"

    # ── 7. DNS configuration ──
    log "Backing up DNS..."
    cp /etc/resolv.conf "${NET_DIR}/" 2>/dev/null || true
    cp /etc/hosts       "${NET_DIR}/" 2>/dev/null || true
    [[ -f /etc/hostname ]] && cp /etc/hostname "${NET_DIR}/" 2>/dev/null || true
    ok "DNS config saved"

    # ── 8. sysctl network settings (ip_forward, IPv6 forwarding, etc.) ──
    log "Backing up sysctl network settings..."
    sysctl -a 2>/dev/null | grep -E '^net\.' > "${NET_DIR}/sysctl-net.conf" || true
    [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "${NET_DIR}/" 2>/dev/null || true
    [[ -d /etc/sysctl.d ]] && cp -a /etc/sysctl.d "${NET_DIR}/" 2>/dev/null || true
    ok "sysctl saved"

    # ── 9. Proxmox SDN config (zones, vnets, subnets) ──
    log "Backing up SDN config..."
    [[ -f /etc/pve/sdn/zones.cfg ]]   && cp /etc/pve/sdn/zones.cfg   "${NET_DIR}/sdn/" 2>/dev/null || true
    [[ -f /etc/pve/sdn/vnets.cfg ]]   && cp /etc/pve/sdn/vnets.cfg   "${NET_DIR}/sdn/" 2>/dev/null || true
    [[ -f /etc/pve/sdn/subnets.cfg ]] && cp /etc/pve/sdn/subnets.cfg "${NET_DIR}/sdn/" 2>/dev/null || true
    [[ -f /etc/pve/sdn/.running-config ]] && cp /etc/pve/sdn/.running-config "${NET_DIR}/sdn/" 2>/dev/null || true
    ok "SDN config saved"

    # ── 10. Proxmox storage config ──
    log "Backing up storage config..."
    [[ -f /etc/pve/storage.cfg ]] && cp /etc/pve/storage.cfg "${NET_DIR}/" 2>/dev/null || true
    ok "Storage config saved"

    # ── 11. Cluster config (if clustered) ──
    log "Backing up cluster config..."
    [[ -f /etc/pve/corosync.conf ]] && cp /etc/pve/corosync.conf "${NET_DIR}/cluster/" 2>/dev/null || true
    [[ -f /etc/pve/datacenter.cfg ]] && cp /etc/pve/datacenter.cfg "${NET_DIR}/cluster/" 2>/dev/null || true
    [[ -f /etc/pve/ha/groups.cfg ]] && cp /etc/pve/ha/groups.cfg "${NET_DIR}/cluster/" 2>/dev/null || true
    [[ -f /etc/pve/ha/resources.cfg ]] && cp /etc/pve/ha/resources.cfg "${NET_DIR}/cluster/" 2>/dev/null || true
    ok "Cluster config saved"

    # ── 12. WireGuard / VPN configs (if any) ──
    if [[ -d /etc/wireguard ]]; then
        log "Backing up WireGuard configs..."
        cp -a /etc/wireguard "${NET_DIR}/" 2>/dev/null || true
        ok "WireGuard saved"
    fi

    # ── 13. Network state snapshot ──
    log "Capturing live network state for reference..."
    {
        echo "=== DATE ==="
        date
        echo ""
        echo "=== IP ADDRESSES (all) ==="
        ip -4 addr show 2>/dev/null || true
        echo ""
        ip -6 addr show 2>/dev/null || true
        echo ""
        echo "=== IP ROUTES (IPv4) ==="
        ip -4 route show 2>/dev/null || true
        echo ""
        echo "=== IP ROUTES (IPv6) ==="
        ip -6 route show 2>/dev/null || true
        echo ""
        echo "=== BRIDGES ==="
        brctl show 2>/dev/null || bridge link show 2>/dev/null || true
        echo ""
        echo "=== IPTABLES NAT TABLE ==="
        iptables -t nat -L -n -v 2>/dev/null || true
        echo ""
        echo "=== IP6TABLES FILTER ==="
        ip6tables -L -n -v 2>/dev/null || true
        echo ""
        echo "=== LISTENING PORTS ==="
        ss -tlnp 2>/dev/null || true
        echo ""
        echo "=== LINK STATUS ==="
        ip link show 2>/dev/null || true
    } > "${NET_DIR}/network-state-snapshot.txt"
    ok "Live network state captured"

    # ── 14. Generate restore script ──
    log "Generating restore script..."
    generate_restore_script "${NET_DIR}"
    ok "Restore script created"

    # ── Package it all up ──
    local BUNDLE_FILE="${BACKUP_DIR}/proxmox-host-config-${TIMESTAMP}.tar.gz"
    tar -czf "$BUNDLE_FILE" -C "$(dirname "$NET_DIR")" "$(basename "$NET_DIR")"
    ok "Host config bundle: ${BUNDLE_FILE} ($(du -h "$BUNDLE_FILE" | cut -f1))"

    # Upload to S3
    local s3_dest="${S3_BUCKET}/${S3_PREFIX}/proxmox-host-config-${TIMESTAMP}.tar.gz"
    log "Uploading host config → ${s3_dest}"
    aws_s3 cp "$BUNDLE_FILE" "$s3_dest" --only-show-errors
    ok "Host config uploaded to S3"

    # Verify
    if aws_s3 ls "$s3_dest" &>/dev/null; then
        ok "S3 verify passed for host config"
    else
        warn "S3 verify failed for host config — keeping local"
        return
    fi

    # Cleanup
    [[ "$KEEP_LOCAL" != "true" ]] && rm -rf "$NET_DIR" "$BUNDLE_FILE"
}

# ══════════════════════════════════════════════════════════════════════
#  RESTORE SCRIPT GENERATOR
# ══════════════════════════════════════════════════════════════════════

generate_restore_script() {
    local DIR="$1"

    cat > "${DIR}/RESTORE.sh" << 'RESTORESCRIPT'
#!/usr/bin/env bash
#
# RESTORE.sh — Restore Proxmox host network + firewall + VMs
#
# Usage on a NEW Proxmox machine:
#   1. Install fresh Proxmox VE
#   2. Download the backup bundle from S3:
#      aws s3 cp s3://bucket/path/proxmox-host-config-*.tar.gz /tmp/
#   3. Extract:
#      tar xzf /tmp/proxmox-host-config-*.tar.gz -C /tmp/
#   4. Run this script:
#      sudo bash /tmp/network-config-*/RESTORE.sh
#   5. Restore VMs with:
#      qmrestore /path/to/vzdump-qemu-VMID-*.vma.zst VMID
#
# The script will restore all networking so VMs come up with correct IPs.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
ask()  { echo -en "${CYAN}$* ${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Proxmox Network & Firewall Restore                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show what was backed up
info "Backup contents:"
echo "  Network interfaces:  $(ls "${SCRIPT_DIR}/interfaces" 2>/dev/null && echo 'YES' || echo 'NO')"
echo "  IPv4 iptables:       $(ls "${SCRIPT_DIR}/iptables-v4.rules" 2>/dev/null && echo 'YES' || echo 'NO')"
echo "  IPv6 ip6tables:      $(ls "${SCRIPT_DIR}/iptables-v6.rules" 2>/dev/null && echo 'YES' || echo 'NO')"
echo "  nftables:            $(ls "${SCRIPT_DIR}/nftables.rules" 2>/dev/null && echo 'YES' || echo 'NO')"
echo "  PVE firewall:        $(ls "${SCRIPT_DIR}/firewall/"*.fw 2>/dev/null | wc -l) files"
echo "  VM/CT configs:       $(ls "${SCRIPT_DIR}/vm-configs/"*.conf 2>/dev/null | wc -l) files"
echo "  SDN config:          $(ls "${SCRIPT_DIR}/sdn/"*.cfg 2>/dev/null | wc -l) files"
echo "  sysctl settings:     $(ls "${SCRIPT_DIR}/sysctl-net.conf" 2>/dev/null && echo 'YES' || echo 'NO')"
echo "  WireGuard:           $([[ -d "${SCRIPT_DIR}/wireguard" ]] && echo 'YES' || echo 'NO')"
echo ""

# Reference snapshot
if [[ -f "${SCRIPT_DIR}/network-state-snapshot.txt" ]]; then
    info "Original network state saved in: network-state-snapshot.txt"
    info "Review it to verify IPs, routes, and bridges before restoring."
    echo ""
fi

ask "Proceed with restore? [y/N]:"; read -r CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

# ── Create backups of CURRENT config before overwriting ──
BACKUP_CURRENT="/root/pre-restore-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_CURRENT"
cp /etc/network/interfaces "$BACKUP_CURRENT/" 2>/dev/null || true
iptables-save  > "$BACKUP_CURRENT/iptables-v4-current.rules" 2>/dev/null || true
ip6tables-save > "$BACKUP_CURRENT/iptables-v6-current.rules" 2>/dev/null || true
log "Current config backed up → ${BACKUP_CURRENT}"

# ── 1. Restore /etc/network/interfaces ──
echo ""
info "--- Restoring Network Interfaces ---"
if [[ -f "${SCRIPT_DIR}/interfaces" ]]; then
    ask "Restore /etc/network/interfaces? (bridges, bonds, IPs) [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        cp "${SCRIPT_DIR}/interfaces" /etc/network/interfaces
        if [[ -d "${SCRIPT_DIR}/interfaces.d" ]]; then
            mkdir -p /etc/network/interfaces.d
            cp -a "${SCRIPT_DIR}/interfaces.d/"* /etc/network/interfaces.d/ 2>/dev/null || true
        fi
        log "Network interfaces restored"
        warn "Run 'ifreload -a' or reboot to apply"
    fi
fi

# ── 2. Restore sysctl (IP forwarding for NAT) ──
echo ""
info "--- Restoring sysctl (IP forwarding) ---"
if [[ -f "${SCRIPT_DIR}/sysctl.conf" ]]; then
    ask "Restore /etc/sysctl.conf? (IPv4/IPv6 forwarding, etc.) [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        cp "${SCRIPT_DIR}/sysctl.conf" /etc/sysctl.conf
        [[ -d "${SCRIPT_DIR}/sysctl.d" ]] && cp -a "${SCRIPT_DIR}/sysctl.d/"* /etc/sysctl.d/ 2>/dev/null || true
        sysctl -p 2>/dev/null || true
        log "sysctl restored and applied"
    fi
else
    # At minimum enable IP forwarding for NAT
    ask "Enable IPv4+IPv6 forwarding (needed for NAT)? [Y/n]:"; read -r R
    if [[ "${R,,}" != "n" ]]; then
        cat >> /etc/sysctl.conf <<EOF

# Proxmox restore - IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
        sysctl -p 2>/dev/null || true
        log "IP forwarding enabled"
    fi
fi

# ── 3. Restore iptables (IPv4 NAT / MASQUERADE / port forwards) ──
echo ""
info "--- Restoring IPv4 Firewall (iptables) ---"
if [[ -f "${SCRIPT_DIR}/iptables-v4.rules" ]]; then
    info "IPv4 rules contain:"
    grep -cE "^-A" "${SCRIPT_DIR}/iptables-v4.rules" 2>/dev/null && \
        echo "  $(grep -cE '^-A' "${SCRIPT_DIR}/iptables-v4.rules") rules total"
    grep -c "MASQUERADE" "${SCRIPT_DIR}/iptables-v4.rules" 2>/dev/null && \
        echo "  $(grep -c 'MASQUERADE' "${SCRIPT_DIR}/iptables-v4.rules") NAT/MASQUERADE rules"
    grep -c "DNAT" "${SCRIPT_DIR}/iptables-v4.rules" 2>/dev/null && \
        echo "  $(grep -c 'DNAT' "${SCRIPT_DIR}/iptables-v4.rules") DNAT/port-forward rules"
    ask "Restore IPv4 iptables rules? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        iptables-restore < "${SCRIPT_DIR}/iptables-v4.rules"
        # Make persistent
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
        else
            apt-get install -y -qq iptables-persistent 2>/dev/null || true
            mkdir -p /etc/iptables
            cp "${SCRIPT_DIR}/iptables-v4.rules" /etc/iptables/rules.v4
        fi
        log "IPv4 iptables restored and saved"
    fi
fi

# ── 4. Restore ip6tables (IPv6 firewall) ──
echo ""
info "--- Restoring IPv6 Firewall (ip6tables) ---"
if [[ -f "${SCRIPT_DIR}/iptables-v6.rules" ]]; then
    ask "Restore IPv6 ip6tables rules? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        ip6tables-restore < "${SCRIPT_DIR}/iptables-v6.rules"
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
        else
            mkdir -p /etc/iptables
            cp "${SCRIPT_DIR}/iptables-v6.rules" /etc/iptables/rules.v6
        fi
        log "IPv6 ip6tables restored and saved"
    fi
fi

# ── 5. Restore nftables (if used) ──
if [[ -f "${SCRIPT_DIR}/nftables.rules" ]]; then
    echo ""
    info "--- Restoring nftables ---"
    ask "Restore nftables ruleset? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        nft flush ruleset 2>/dev/null || true
        nft -f "${SCRIPT_DIR}/nftables.rules" 2>/dev/null || warn "nftables restore had warnings"
        [[ -f "${SCRIPT_DIR}/nftables.conf" ]] && cp "${SCRIPT_DIR}/nftables.conf" /etc/nftables.conf
        log "nftables restored"
    fi
fi

# ── 6. Restore Proxmox firewall ──
echo ""
info "--- Restoring Proxmox Firewall ---"
FW_COUNT=$(ls "${SCRIPT_DIR}/firewall/"*.fw 2>/dev/null | wc -l)
if [[ "$FW_COUNT" -gt 0 ]]; then
    ask "Restore ${FW_COUNT} Proxmox firewall config files? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        mkdir -p /etc/pve/firewall
        cp "${SCRIPT_DIR}/firewall/"*.fw /etc/pve/firewall/ 2>/dev/null || true
        log "Proxmox firewall configs restored"
    fi
fi

# ── 7. Restore DNS ──
echo ""
info "--- Restoring DNS ---"
if [[ -f "${SCRIPT_DIR}/resolv.conf" ]]; then
    ask "Restore /etc/resolv.conf and /etc/hosts? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        cp "${SCRIPT_DIR}/resolv.conf" /etc/resolv.conf 2>/dev/null || true
        cp "${SCRIPT_DIR}/hosts" /etc/hosts 2>/dev/null || true
        log "DNS config restored"
    fi
fi

# ── 8. Restore SDN ──
if [[ -d "${SCRIPT_DIR}/sdn" ]] && ls "${SCRIPT_DIR}/sdn/"*.cfg &>/dev/null 2>&1; then
    echo ""
    info "--- Restoring Proxmox SDN ---"
    ask "Restore SDN config (zones, vnets, subnets)? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        mkdir -p /etc/pve/sdn
        cp "${SCRIPT_DIR}/sdn/"* /etc/pve/sdn/ 2>/dev/null || true
        log "SDN config restored"
    fi
fi

# ── 9. Restore storage config ──
if [[ -f "${SCRIPT_DIR}/storage.cfg" ]]; then
    echo ""
    info "--- Restoring Storage Config ---"
    ask "Restore /etc/pve/storage.cfg? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        cp "${SCRIPT_DIR}/storage.cfg" /etc/pve/storage.cfg
        log "Storage config restored"
    fi
fi

# ── 10. Restore WireGuard ──
if [[ -d "${SCRIPT_DIR}/wireguard" ]]; then
    echo ""
    info "--- Restoring WireGuard ---"
    ask "Restore WireGuard configs? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        cp -a "${SCRIPT_DIR}/wireguard/"* /etc/wireguard/ 2>/dev/null || true
        chmod 600 /etc/wireguard/*.conf 2>/dev/null || true
        log "WireGuard configs restored"
    fi
fi

# ── 11. Restore VM configs (for reference) ──
echo ""
info "--- VM/CT Configuration Files ---"
VM_COUNT=$(ls "${SCRIPT_DIR}/vm-configs/"*.conf 2>/dev/null | wc -l)
if [[ "$VM_COUNT" -gt 0 ]]; then
    info "Found ${VM_COUNT} VM/CT config files."
    info "These are placed automatically when you restore VMs with qmrestore/pct restore."
    info "They're included here as a reference for network settings."
    ask "Copy VM configs to /etc/pve for reference? [y/N]:"; read -r R
    if [[ "${R,,}" == "y" ]]; then
        for conf in "${SCRIPT_DIR}/vm-configs/"*.conf; do
            local fname=$(basename "$conf")
            if [[ "$fname" == *"qemu"* ]] || echo "$conf" | grep -q "^[0-9]"; then
                # Determine if QEMU or LXC by checking content
                if grep -q "^ostype:" "$conf" 2>/dev/null; then
                    mkdir -p /etc/pve/lxc
                    cp "$conf" /etc/pve/lxc/ 2>/dev/null || true
                else
                    mkdir -p /etc/pve/qemu-server
                    cp "$conf" /etc/pve/qemu-server/ 2>/dev/null || true
                fi
            fi
        done
        log "VM/CT configs copied"
    fi
fi

# ── Summary ──
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                  Restore Complete!                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Pre-restore backup saved at: ${BACKUP_CURRENT}"
echo ""
warn "NEXT STEPS:"
echo "  1. Apply network changes:  ifreload -a  (or reboot)"
echo "  2. Restore VMs from vzdump files:"
echo "     qmrestore vzdump-qemu-VMID-*.vma.zst VMID --storage local-lvm"
echo "     pct restore VMID vzdump-lxc-VMID-*.tar.zst --storage local-lvm"
echo "  3. Start VMs:  qm start VMID  /  pct start VMID"
echo ""
info "VMs will come up with the same IPs, bridges, VLANs, and firewall rules."
RESTORESCRIPT

    chmod +x "${DIR}/RESTORE.sh"
}

# ══════════════════════════════════════════════════════════════════════
#  PHASE 2: Backup VMs (one at a time → S3)
# ══════════════════════════════════════════════════════════════════════

get_all_vmids() {
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r.get('status') == 'running':
        print(r['vmid'])
" 2>/dev/null | sort -n | uniq || true
}

backup_vm() {
    local vmid="$1"
    local cmd=(vzdump "$vmid" --mode "$BACKUP_MODE" --compress "$COMPRESS")
    [[ -n "$STORAGE" ]] && cmd+=(--storage "$STORAGE") || cmd+=(--dumpdir "$BACKUP_DIR")
    log "Running: ${cmd[*]}"
    "${cmd[@]}"
}

find_latest_backup() {
    local vmid="$1"
    ls -1t "${BACKUP_DIR}"/vzdump-*-"${vmid}"-*.vma* 2>/dev/null | head -1 || \
    ls -1t "${BACKUP_DIR}"/vzdump-*-"${vmid}"-*.tar* 2>/dev/null | head -1 || true
}

upload_to_s3() {
    local filepath="$1" vmid="$2"
    local filename; filename=$(basename "$filepath")
    local filesize; filesize=$(du -h "$filepath" | cut -f1)
    local s3_dest="${S3_BUCKET}/${S3_PREFIX}/${filename}"
    log "Uploading ${filename} (${filesize}) → ${s3_dest}"
    local start=$SECONDS
    aws_s3 cp "$filepath" "$s3_dest" --only-show-errors --expected-size "$(stat -c%s "$filepath")"
    ok "Upload done for VMID ${vmid} in $(( SECONDS - start ))s"
}

cleanup_local() {
    local filepath="$1"
    [[ "$KEEP_LOCAL" == "true" ]] && return
    local logfile="${filepath%.vma*}.log"
    [[ "$logfile" == "$filepath" ]] && logfile="${filepath%.tar*}.log"
    rm -f "$filepath"
    [[ -f "$logfile" ]] && rm -f "$logfile"
}

process_vm() {
    local vmid="$1"
    log "════════════════════════════════════════════"
    log "  Processing VMID ${vmid}"
    log "════════════════════════════════════════════"
    local vm_start=$SECONDS

    if ! backup_vm "$vmid"; then
        fail "Backup FAILED for VMID ${vmid}"; FAILED+=("$vmid (backup)"); return 1
    fi
    ok "Backup done for VMID ${vmid}"

    local backup_file; backup_file=$(find_latest_backup "$vmid")
    [[ -z "$backup_file" || ! -f "$backup_file" ]] && {
        fail "File not found for VMID ${vmid}"; FAILED+=("$vmid (missing)"); return 1
    }

    if ! upload_to_s3 "$backup_file" "$vmid"; then
        fail "Upload FAILED for VMID ${vmid}"; FAILED+=("$vmid (upload)"); return 1
    fi

    local fname; fname=$(basename "$backup_file")
    if aws_s3 ls "${S3_BUCKET}/${S3_PREFIX}/${fname}" &>/dev/null; then
        ok "S3 verify OK for VMID ${vmid}"
    else
        warn "S3 verify FAILED for VMID ${vmid}"; FAILED+=("$vmid (verify)"); return 1
    fi

    cleanup_local "$backup_file"
    ok "VMID ${vmid} done in $(( SECONDS - vm_start ))s"
    SUCCESS+=("$vmid")
}

# ══════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════

main() {
    log "════════════════════════════════════════════"
    log "  Proxmox FULL Backup → S3"
    log "  Host:     $(hostname)"
    log "  Date:     $(date)"
    log "  Bucket:   ${S3_BUCKET}/${S3_PREFIX}"
    log "  Mode:     ${BACKUP_MODE} | Compress: ${COMPRESS}"
    log "════════════════════════════════════════════"

    # Phase 1: Host network config
    backup_host_network

    # Phase 2: VM backups
    log ""
    log "════════════════════════════════════════════"
    log "  PHASE 2: VM/CT Backups"
    log "════════════════════════════════════════════"

    local vmids=()
    if (( $# > 0 )); then
        vmids=("$@")
    else
        mapfile -t vmids < <(get_all_vmids)
    fi

    if (( ${#vmids[@]} == 0 )); then
        warn "No VMs to backup"; return
    fi

    log "VMs: ${vmids[*]}"
    SUCCESS=(); FAILED=()
    local total_start=$SECONDS

    for vmid in "${vmids[@]}"; do
        [[ -z "$vmid" ]] && continue
        process_vm "$vmid" || true
    done

    # Summary
    log ""
    log "════════════════════════════════════════════"
    log "  BACKUP COMPLETE — $(( SECONDS - total_start ))s"
    log "  ✅ VMs OK (${#SUCCESS[@]}):     ${SUCCESS[*]:-none}"
    log "  ❌ VMs Failed (${#FAILED[@]}):  ${FAILED[*]:-none}"
    log "  📦 Host config:              uploaded"
    log "  📄 Log: ${LOGFILE}"
    log "════════════════════════════════════════════"
    log ""
    log "  TO RESTORE ON NEW PROXMOX:"
    log "  1. aws s3${S3_ENDPOINT:+ --endpoint-url $S3_ENDPOINT} cp ${S3_BUCKET}/${S3_PREFIX}/ /tmp/restore/ --recursive"
    log "  2. tar xzf /tmp/restore/proxmox-host-config-*.tar.gz -C /tmp/"
    log "  3. sudo bash /tmp/network-config-*/RESTORE.sh"
    log "  4. qmrestore /tmp/restore/vzdump-qemu-VMID-*.vma.zst VMID"
    log "  5. qm start VMID"
    log "════════════════════════════════════════════"

    (( ${#FAILED[@]} > 0 )) && exit 1 || exit 0
}

main "$@"
