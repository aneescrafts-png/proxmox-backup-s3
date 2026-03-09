# Proxmox Full Backup to S3

Automated backup solution for Proxmox VE that backs up **VMs + full host network configuration** to Amazon S3. Designed for seamless restore on a brand new Proxmox machine.

## What Gets Backed Up

### Per VM/CT
- Full disk image via `vzdump`
- VM/CT configuration file (`.conf`)

### Host Network Bundle
| Component | Details |
|---|---|
| Network interfaces | Bridges, bonds, VLANs, IPv4, IPv6 |
| IPv4 firewall | iptables — NAT, MASQUERADE, port forwards |
| IPv6 firewall | ip6tables rules |
| nftables | Full ruleset (if used) |
| Proxmox firewall | Cluster-wide + per-VM `.fw` files |
| DNS | `/etc/resolv.conf`, `/etc/hosts` |
| sysctl | IP forwarding, IPv6 forwarding |
| SDN | Zones, vnets, subnets |
| Storage | `/etc/pve/storage.cfg` |
| Cluster | Corosync, datacenter, HA config |
| VPN | WireGuard configs (if present) |
| Restore script | Auto-generated `RESTORE.sh` |

## How It Works

```
For each VM:
  1. vzdump backup (snapshot mode, no downtime)
  2. Upload .vma.zst to S3
  3. Verify upload in S3
  4. Delete local copy → next VM

Then:
  5. Bundle all host network/firewall/NAT configs
  6. Upload bundle to S3
```

## Quick Start

```bash
# One-command interactive setup on your Proxmox host:
sudo bash proxmox_full_backup_s3_setup.sh
```

The installer handles AWS CLI, credentials, S3 bucket, backup preferences, and cron setup.

## Manual Setup

```bash
# 1. Install AWS CLI & configure
apt install awscli -y && aws configure

# 2. Install scripts
cp proxmox_backup_s3.sh /usr/local/bin/ && chmod +x /usr/local/bin/proxmox_backup_s3.sh

# 3. Create config
cp examples/proxmox-backup-s3.conf.example /etc/proxmox-backup-s3.conf
nano /etc/proxmox-backup-s3.conf

# 4. Test
sudo /usr/local/bin/proxmox_backup_s3.sh

# 5. Enable weekly cron
cp cron/proxmox-backup-s3 /etc/cron.d/
```

## Configuration

Edit `/etc/proxmox-backup-s3.conf`:

```bash
S3_BUCKET="s3://your-bucket-name"
BACKUP_MODE="snapshot"    # snapshot | suspend | stop
COMPRESS="zstd"           # zstd | gzip | lzo | none
VMIDS=""                  # empty = all running VMs, or "100 101 205"
KEEP_LOCAL="false"
LOG_RETENTION_DAYS=30
```

## Usage

```bash
sudo proxmox_backup_s3.sh              # All running VMs
sudo proxmox_backup_s3.sh 100 101      # Specific VMs
```

## Restore on New Proxmox Host

```bash
# 1. Download from S3
aws s3 cp s3://bucket/backups/host/2025/01/15/ /tmp/restore/ --recursive

# 2. Restore host networking (interactive)
tar xzf /tmp/restore/proxmox-host-config-*.tar.gz -C /tmp/
sudo bash /tmp/network-config-*/RESTORE.sh

# 3. Restore & start VMs
qmrestore /tmp/restore/vzdump-qemu-100-*.vma.zst 100 --storage local-lvm
qm start 100    # comes up with correct IPs, bridges, NAT
```

## S3 Bucket Structure

```
s3://your-bucket/backups/hostname/2025/01/15/
  ├── proxmox-host-config-20250115-020000.tar.gz
  ├── vzdump-qemu-100-2025_01_15-02_05_30.vma.zst
  ├── vzdump-qemu-101-2025_01_15-02_15_45.vma.zst
  └── vzdump-lxc-200-2025_01_15-02_20_10.tar.zst
```

## AWS IAM Policy (Minimum Permissions)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
    "Resource": ["arn:aws:s3:::your-bucket", "arn:aws:s3:::your-bucket/*"]
  }]
}
```

## Requirements

- Proxmox VE 7.x / 8.x
- AWS CLI
- IAM credentials with S3 access

## License

MIT
