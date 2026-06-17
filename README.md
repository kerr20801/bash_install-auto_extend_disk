# Auto Extend Root Disk

Automatically extends the root partition and LVM logical volume after expanding a virtual disk in VMware / Proxmox / cloud.

One script, no parameters required — detects disk, partition, VG, LV, and filesystem type automatically.

## Usage

```bash
# Extend root disk + install systemd service (runs once on boot)
sudo bash auto_extend_root_disk.sh

# Dry-run: detect layout and show what would be done (no changes)
sudo bash auto_extend_root_disk.sh --check

# Extend without installing the systemd service
sudo bash auto_extend_root_disk.sh --no-service
```

## What It Does

1. Rescans SCSI hosts so the kernel sees the expanded disk
2. Detects root device → partition → PV → VG → LV automatically
3. Extends the partition to 100% of the disk (`parted` → `growpart` fallback)
4. Runs `pvresize` + `lvextend --resizefs` (expands LV and filesystem in one step)
5. Installs a systemd service so future VM disk expansions are handled automatically on next boot

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (Debian compatible)
- Root partition must be LVM — for plain partitions run `growpart` + `resize2fs` manually
- Tools auto-installed if missing: `lvm2`, `xfsprogs`, `parted`, `cloud-guest-utils`

## Typical VMware Workflow

```
1. Expand disk in vSphere console
2. SSH into VM
3. sudo bash auto_extend_root_disk.sh
4. df -h /   ← verify
```

The systemd service (installed on first run) means step 3 is automatic on subsequent expansions — just reboot after expanding the disk in vSphere.

## License

MIT
