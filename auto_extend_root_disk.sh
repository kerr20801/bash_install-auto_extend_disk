#!/bin/bash
# auto_extend_root_disk.sh — extend root LVM partition after VM disk expansion
# Supports: VMware / Proxmox / cloud (Ubuntu / Debian, LVM required)
#
# Usage:
#   bash auto_extend_root_disk.sh            # extend + install systemd service
#   bash auto_extend_root_disk.sh --check    # dry-run: show what would happen
#   bash auto_extend_root_disk.sh --no-service  # extend without installing service

set -euo pipefail

LOG_FILE="/var/log/auto_extend_disk.log"
SCRIPT_INSTALL_PATH="/usr/local/sbin/auto_extend_root_disk.sh"
DRY_RUN=false
INSTALL_SERVICE=true

log() {
  echo "[$(date '+%Y-%m-%d_%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

die() {
  log "❌ $1"
  exit 1
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --check|--dry-run) DRY_RUN=true ;;
      --no-service)      INSTALL_SERVICE=false ;;
      -h|--help)
        echo "Usage: $0 [--check] [--no-service]"
        echo "  --check       Dry-run: detect layout and show what would be done"
        echo "  --no-service  Skip systemd service installation"
        exit 0 ;;
      *) die "Unknown option: $arg" ;;
    esac
  done
}

require_root() {
  [ "$EUID" -eq 0 ] || die "Run as root"
}

ensure_tools() {
  local missing=()
  for t in parted lsblk pvs lvs pvresize lvextend resize2fs xfs_growfs blockdev; do
    command -v "$t" &>/dev/null || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "Installing missing tools: ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq lvm2 xfsprogs parted cloud-guest-utils
  fi
}

scsi_rescan() {
  log "Rescanning SCSI hosts for new disk size..."
  for host in /sys/class/scsi_host/*/scan; do
    [ -w "$host" ] && echo "- - -" > "$host" 2>/dev/null || true
  done
  sleep 2
  # Re-read partition tables on all block devices
  while IFS= read -r disk; do
    blockdev --rereadpt "$disk" 2>/dev/null || true
  done < <(lsblk -dnp -o NAME | grep -v loop)
}

get_lvm_info() {
  log "Detecting root partition layout..."

  ROOT_MOUNT=$(findmnt -n -o SOURCE / | head -1)
  [ -n "$ROOT_MOUNT" ] || die "Cannot determine root device"
  log "Root device: $ROOT_MOUNT"

  [[ "$ROOT_MOUNT" == /dev/mapper/* ]] \
    || die "Root is not an LVM logical volume ($ROOT_MOUNT). For plain partitions use: growpart + resize2fs."

  # Resolve LV → VG → PV
  LV_PATH=$(lvs --noheadings -o lv_path "$ROOT_MOUNT" 2>/dev/null | tr -d ' ') \
    || true
  [ -n "$LV_PATH" ] && ROOT_LV="$LV_PATH" || ROOT_LV="$ROOT_MOUNT"

  VG_NAME=$(lvs --noheadings -o vg_name "$ROOT_MOUNT" 2>/dev/null | tr -d ' ') \
    || die "Cannot determine VG for $ROOT_MOUNT"

  PV_PATH=$(pvs --noheadings -o pv_name --select "vg_name=${VG_NAME}" 2>/dev/null \
    | tr -d ' ' | head -1) \
    || die "Cannot find PV for VG ${VG_NAME}"

  DISK_NAME=$(lsblk -dno pkname "$PV_PATH" 2>/dev/null) \
    || die "Cannot determine parent disk for $PV_PATH"

  PART_NUM=$(echo "$PV_PATH" | grep -oE '[0-9]+$') \
    || die "Cannot parse partition number from $PV_PATH"

  log "Layout: disk=/dev/${DISK_NAME}  partition=${PV_PATH}  VG=${VG_NAME}  LV=${ROOT_LV}"
}

check_expand_needed() {
  DISK_SIZE=$(lsblk -bdn -o SIZE "/dev/$DISK_NAME")
  PART_SIZE=$(lsblk -bdn -o SIZE "$PV_PATH")
  local tolerance=$(( 1024 * 1024 ))  # 1 MB

  log "Disk: $(( DISK_SIZE / 1024 / 1024 / 1024 )) GB  |  Partition: $(( PART_SIZE / 1024 / 1024 / 1024 )) GB"

  if (( PART_SIZE + tolerance >= DISK_SIZE )); then
    log "Partition already uses full disk — nothing to do."
    return 1
  fi
  log "Unallocated: $(( (DISK_SIZE - PART_SIZE) / 1024 / 1024 / 1024 )) GB available"
  return 0
}

do_extend() {
  if $DRY_RUN; then
    log "[DRY-RUN] Would run: parted -s /dev/${DISK_NAME} resizepart ${PART_NUM} 100%"
    log "[DRY-RUN] Would run: pvresize ${PV_PATH}"
    log "[DRY-RUN] Would run: lvextend -l +100%FREE --resizefs ${ROOT_LV}"
    return 0
  fi

  # 1. Extend partition
  log "Extending partition /dev/${DISK_NAME} part ${PART_NUM}..."
  if parted -s "/dev/$DISK_NAME" resizepart "$PART_NUM" 100% 2>>"$LOG_FILE"; then
    log "parted succeeded"
  elif growpart "/dev/$DISK_NAME" "$PART_NUM" 2>>"$LOG_FILE"; then
    log "growpart succeeded"
  else
    die "Both parted and growpart failed"
  fi

  partprobe "/dev/$DISK_NAME" 2>/dev/null || true
  sleep 2

  # 2. Resize PV
  log "Resizing PV ${PV_PATH}..."
  pvresize "$PV_PATH"

  # 3. Extend LV + filesystem in one step
  log "Extending LV ${ROOT_LV} and filesystem..."
  lvextend -l +100%FREE --resizefs "$ROOT_LV"

  log "Result:"
  df -h / | tee -a "$LOG_FILE"
  log "✅ Root disk extended successfully"
}

install_service() {
  $INSTALL_SERVICE || return 0
  [ -f "/etc/systemd/system/auto-extend-root-disk.service" ] && return 0

  # Install script to a permanent location so systemd can find it after reboot
  if [ "$(readlink -f "$0")" != "$SCRIPT_INSTALL_PATH" ]; then
    log "Installing script to ${SCRIPT_INSTALL_PATH}..."
    cp "$(readlink -f "$0")" "$SCRIPT_INSTALL_PATH"
    chmod 755 "$SCRIPT_INSTALL_PATH"
  fi

  log "Installing systemd service..."
  cat > /etc/systemd/system/auto-extend-root-disk.service <<EOF
[Unit]
Description=Auto-extend root disk after VM disk resize
After=local-fs.target
ConditionPathExists=/usr/local/sbin/auto_extend_root_disk.sh

[Service]
Type=oneshot
ExecStart=${SCRIPT_INSTALL_PATH} --no-service
TimeoutSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable auto-extend-root-disk.service
  log "Systemd service installed — will auto-run on next boot if disk was expanded"
}

### Main ###
parse_args "$@"
log "=== auto_extend_root_disk start (dry-run=${DRY_RUN}) ==="
require_root
ensure_tools

$DRY_RUN || scsi_rescan

get_lvm_info

if check_expand_needed; then
  do_extend
  install_service
else
  log "=== Nothing to do ==="
fi
