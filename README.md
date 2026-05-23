# 💾 Auto Extend Root Disk

Automatically extends the root partition and LVM logical volume after expanding a virtual disk (VMware / Proxmox / cloud).

## Usage

```bash
bash auto_extend_root_disk.sh
```

No parameters needed — detects the root disk, partition, and LVM layout automatically.

## What It Does

1. Detects the root disk and partition
2. Runs `growpart` to extend the partition
3. Runs `pvresize` + `lvextend` + `resize2fs` / `xfs_growfs` to expand the filesystem

## Requirements

- Ubuntu / Debian
- `cloud-guest-utils`, `lvm2` (auto-installed if missing)

## License

MIT
