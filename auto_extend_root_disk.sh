#!/bin/bash
set -e

LOG_FILE="/var/log/auto_extend_disk.log"

log() {
  echo "[$(date '+%Y-%m-%d_%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

require_root() {
  if [ "$EUID" -ne 0 ]; then
    log "❌ 請以 root 權限執行此腳本"
    exit 1
  fi
}

detect_os() {
  if ! command -v lsb_release &> /dev/null; then
    log "⚠️ 找不到 lsb_release 指令，嘗試安裝..."
    apt-get update -qq && apt-get install -qq -y lsb-release || {
      log "❌ 無法安裝 lsb-release，使用默認方法繼續"
      if [ -f /etc/os-release ]; then
        OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2)
      else
        log "❌ 無法確定 OS 版本"
        exit 1
      fi
    }
  else
    OS_VERSION=$(lsb_release -rs)
  fi
  
  case "$OS_VERSION" in
    22.04)
      OS_TAG="ubuntu2204"
      ;;
    24.04)
      OS_TAG="ubuntu2404"
      ;;
    *)
      log "⚠️ 不完全支援的 Ubuntu 版本：$OS_VERSION，將使用基本方法"
      if [[ "$OS_VERSION" == 22* ]]; then
        OS_TAG="ubuntu2204"
      elif [[ "$OS_VERSION" == 24* ]]; then
        OS_TAG="ubuntu2404"
      else
        OS_TAG="ubuntu_other"
      fi
      ;;
  esac
  log "✅ 偵測到作業系統版本：$OS_TAG"
}

ensure_tools() {
  local tools_needed=("parted" "lsblk" "pvs" "lvs" "pvresize" "lvextend" "resize2fs" "xfs_growfs")
  local missing_tools=()
  
  for tool in "${tools_needed[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      missing_tools+=("$tool")
    fi
  done
  
  if [ ${#missing_tools[@]} -gt 0 ]; then
    log "⚠️ 缺少必要工具：${missing_tools[*]}"
    log "🔧 嘗試安裝..."
    apt-get update -qq && apt-get install -qq -y lvm2 xfsprogs parted gdisk cloud-guest-utils || {
      log "❌ 無法安裝必要工具"
      exit 1
    }
  fi
}

scsi_rescan_all() {
  log "🔄 執行 SCSI 裝置重新掃描..."
  
  # 方法1：SCSI主機掃描（所有Ubuntu都支援）
  if ls /sys/class/scsi_host/*/scan &>/dev/null; then
    log "🔄 掃描所有 SCSI 主機..."
    for host in /sys/class/scsi_host/*/scan; do
      if [ -w "$host" ]; then
        log "📌 掃描 SCSI 主機: $host"
        echo "- - -" > "$host" 2>/dev/null || log "⚠️ 無法寫入 $host"
      fi
    done
    sleep 2
  else
    log "⚠️ 未找到任何 SCSI 主機掃描路徑"
  fi
  
  # 方法2：磁碟重新掃描（更可靠）
  log "🔄 刷新所有磁碟設備..."
  for disk in $(lsblk -dnp -o NAME | grep -v loop); do
    log "📌 重新讀取磁碟: $disk"
    blockdev --rereadpt "$disk" 2>/dev/null || log "⚠️ 無法重新讀取分區表: $disk"
  done
  
  # 方法3：特定設備掃描
  if [ -d /sys/class/scsi_disk ]; then
    log "🔄 掃描所有 SCSI 磁碟設備..."
    for dev in /sys/class/scsi_disk/*/device/rescan; do
      if [ -e "$dev" ]; then
        log "📌 掃描 SCSI 設備: $dev"
        echo 1 > "$dev" 2>/dev/null || log "⚠️ 無法寫入 $dev"
      fi
    done
    sleep 2
  fi
  
  # 刷新內核的設備映射表
  log "🔄 刷新設備映射..."
  if command -v partprobe &>/dev/null; then
    partprobe 2>/dev/null || log "⚠️ partprobe 失敗"
  fi
  
  sleep 3
}

get_lvm_info() {
  log "🔍 獲取 LVM 信息..."
  
  # 直接從 df 命令獲取根分區的設備路徑
  ROOT_MOUNT=$(df / | awk 'NR==2 {print $1}')
  if [ -z "$ROOT_MOUNT" ]; then
    log "⚠️ 無法從 df 獲取根分區設備，嘗試 findmnt..."
    ROOT_MOUNT=$(findmnt -n -o SOURCE / | head -1)
    if [ -z "$ROOT_MOUNT" ]; then
      log "❌ 無法確定根分區的設備路徑"
      exit 1
    fi
  fi
  
  log "📌 根分區掛載點：$ROOT_MOUNT"
  
  # 檢查是否為 LVM 邏輯卷
  if [[ "$ROOT_MOUNT" == "/dev/mapper/"* ]]; then
    # 是 LVM 邏輯卷
    log "📌 根分區是 LVM 邏輯卷"
    
    # 從 lvdisplay 獲取 LVM 信息
    ROOT_LV=$ROOT_MOUNT
    lvs_output=$(lvs --noheadings -o lv_name,vg_name,lv_path | grep "$ROOT_MOUNT" || true)
    
    if [ -n "$lvs_output" ]; then
      # 從 lvs 輸出中提取信息
      LV_NAME=$(echo "$lvs_output" | awk '{print $1}')
      VG_NAME=$(echo "$lvs_output" | awk '{print $2}')
      log "📌 邏輯卷名稱：$LV_NAME"
      log "📌 卷組名稱：$VG_NAME"
    else
      # 嘗試從路徑解析
      log "⚠️ 無法從 lvs 獲取 LVM 信息，嘗試解析路徑..."
      
      # 解析 /dev/mapper/vg-lv 格式
      if [[ "$ROOT_MOUNT" =~ /dev/mapper/([^-]+)-([^-]+) ]]; then
        VG_NAME="${BASH_REMATCH[1]}"
        LV_NAME="${BASH_REMATCH[2]}"
      # 解析 /dev/mapper/vg--lv 格式 (Ubuntu 標準)
      elif [[ "$ROOT_MOUNT" =~ /dev/mapper/([^-]+)--([^-]+) ]]; then
        VG_NAME="${BASH_REMATCH[1]}"
        LV_NAME="${BASH_REMATCH[2]}"
      else
        log "❌ 無法解析邏輯卷路徑：$ROOT_MOUNT"
        exit 1
      fi
      
      log "📌 邏輯卷名稱（從路徑解析）：$LV_NAME"
      log "📌 卷組名稱（從路徑解析）：$VG_NAME"
    fi
    
    # 獲取物理卷信息
    pvs_output=$(pvs --noheadings -o pv_name,vg_name | grep -w "$VG_NAME" || true)
    if [ -n "$pvs_output" ]; then
      PV_PATH=$(echo "$pvs_output" | awk '{print $1}' | head -1)
      log "📌 物理卷路徑：$PV_PATH"
    else
      log "❌ 無法找到卷組 $VG_NAME 的物理卷"
      
      # 顯示系統中所有物理卷信息用於調試
      log "📊 系統中的物理卷信息："
      pvs | tee -a "$LOG_FILE" || true
      
      log "📊 系統中的邏輯卷信息："
      lvs | tee -a "$LOG_FILE" || true
      
      exit 1
    fi
  else
    # 非 LVM 分區
    log "❌ 根分區不是 LVM 邏輯卷，此腳本僅支持 LVM 分區"
    exit 1
  fi
  
  # 獲取磁碟和分區信息
  PART_NAME=$(basename "$PV_PATH")
  DISK_NAME=$(lsblk -dno pkname "$PV_PATH" 2>/dev/null)
  
  if [ -z "$DISK_NAME" ]; then
    log "⚠️ 無法通過 lsblk 獲取磁碟名稱，嘗試解析路徑..."
    DISK_NAME=$(echo "$PV_PATH" | sed 's/[0-9]*$//' | sed 's|/dev/||')
    if [ -z "$DISK_NAME" ]; then
      log "❌ 無法確定分區所在的磁碟"
      exit 1
    fi
  fi
  
  log "📌 磁碟：/dev/$DISK_NAME"
  log "📌 分區：$PART_NAME"
  
  # 顯示更多當前分區信息
  log "📊 當前分區信息："
  fdisk -l "/dev/$DISK_NAME" | tee -a "$LOG_FILE" || true
}

get_partition_number() {
  if [[ "$PART_NAME" =~ [0-9]+$ ]]; then
    PART_NUM=$(echo "$PART_NAME" | grep -oE '[0-9]+$')
    log "📌 分區號碼：$PART_NUM"
  else
    log "⚠️ 無法直接解析分區號碼，嘗試從設備名稱中提取..."
    PART_NUM=$(echo "$PV_PATH" | grep -oE '[0-9]+$')
    if [ -z "$PART_NUM" ]; then
      log "❌ 無法確定分區號碼"
      exit 1
    fi
    log "📌 分區號碼 (從路徑解析)：$PART_NUM"
  fi
}

check_expand_needed() {
  log "🔍 檢查是否需要擴展分區..."
  
  # 獲取磁碟和分區大小
  DISK_SIZE=$(lsblk -bdn -o SIZE "/dev/$DISK_NAME" 2>/dev/null)
  PART_SIZE=$(lsblk -bdn -o SIZE "$PV_PATH" 2>/dev/null)
  
  # 如果大小檢測失敗，嘗試多次
  if [[ -z "$DISK_SIZE" || -z "$PART_SIZE" || "$DISK_SIZE" == "0" || "$PART_SIZE" == "0" ]]; then
    log "⚠️ 磁碟大小檢測失敗，嘗試重新掃描..."
    
    # 重新掃描分區表
    partprobe "/dev/$DISK_NAME" 2>/dev/null || true
    blockdev --rereadpt "/dev/$DISK_NAME" 2>/dev/null || true
    sleep 2
    
    # 再次嘗試獲取大小
    DISK_SIZE=$(lsblk -bdn -o SIZE "/dev/$DISK_NAME" 2>/dev/null)
    PART_SIZE=$(lsblk -bdn -o SIZE "$PV_PATH" 2>/dev/null)
    
    if [[ -z "$DISK_SIZE" || -z "$PART_SIZE" || "$DISK_SIZE" == "0" || "$PART_SIZE" == "0" ]]; then
      log "❌ 無法獲取磁碟或分區大小"
      log "📊 調試信息："
      lsblk -a | tee -a "$LOG_FILE"
      return 1
    fi
  fi
  
  # 顯示磁碟和分區大小
  log "📏 磁碟大小：$((DISK_SIZE / 1024 / 1024 / 1024)) GB"
  log "📏 分區大小：$((PART_SIZE / 1024 / 1024 / 1024)) GB"
  
  # 設置一個1MB的容忍差異
  local tolerance=$((1024*1024))
  
  # 檢查是否需要擴展
  if (( PART_SIZE + tolerance >= DISK_SIZE )); then
    log "✅ 分區已使用完整磁碟空間，無需擴容"
    return 1
  else
    local diff_gb=$(( (DISK_SIZE - PART_SIZE) / 1024 / 1024 / 1024 ))
    log "🔍 檢測到可擴容空間：約 $diff_gb GB"
    return 0
  fi
}

resize_partition() {
  log "📦 執行分區擴展 /dev/$DISK_NAME 第 $PART_NUM 區段..."
  
  # 顯示分區調整前狀態
  log "📊 分區調整前狀態："
  lsblk "/dev/$DISK_NAME" | tee -a "$LOG_FILE"
  
  local resize_success=false
  
  # 嘗試使用 parted 調整分區大小（適用於大多數 Ubuntu 版本）
  if command -v parted &>/dev/null; then
    log "🔧 使用 parted 擴展分區..."
    if parted -s "/dev/$DISK_NAME" resizepart "$PART_NUM" 100% 2>>$LOG_FILE; then
      resize_success=true
      log "✅ parted 分區調整成功"
    else
      log "⚠️ parted 分區調整失敗，將嘗試其他方法"
    fi
  fi
  
  # 如果 parted 失敗，嘗試 growpart
  if [ "$resize_success" != "true" ] && command -v growpart &>/dev/null; then
    log "🔧 使用 growpart 擴展分區..."
    if growpart "/dev/$DISK_NAME" "$PART_NUM" 2>>$LOG_FILE; then
      resize_success=true
      log "✅ growpart 分區調整成功"
    else
      log "⚠️ growpart 分區調整失敗"
    fi
  fi
  
  # 刷新分區表
  log "🔄 刷新分區表..."
  partprobe "/dev/$DISK_NAME" 2>/dev/null || true
  blockdev --rereadpt "/dev/$DISK_NAME" 2>/dev/null || true
  sleep 3
  
  # 顯示分區調整後狀態
  log "📊 分區調整後狀態："
  lsblk "/dev/$DISK_NAME" | tee -a "$LOG_FILE"
  
  if [ "$resize_success" != "true" ]; then
    log "❌ 所有分區調整方法都失敗了"
    return 1
  fi
  
  return 0
}

do_extend() {
  # 擴展分區
  resize_partition || {
    log "❌ 分區調整失敗，無法繼續"
    return 1
  }
  
  # 擴展物理卷
  log "🔧 擴展 PV: $PV_PATH"
  if ! pvresize "$PV_PATH"; then
    log "❌ pvresize 失敗"
    return 1
  fi
  
  # 顯示 PV 擴展後狀態
  pvdisplay "$PV_PATH" | tee -a "$LOG_FILE"
  
  # 擴展邏輯卷
  log "🔧 擴展 LV: $ROOT_LV"
  if ! lvextend -l +100%FREE "$ROOT_LV"; then
    log "❌ lvextend 失敗"
    return 1
  fi
  
  # 顯示 LV 擴展後狀態
  lvdisplay "$ROOT_LV" | tee -a "$LOG_FILE"
  
  # 擴展檔案系統
  FS_TYPE=$(df -T / | awk 'NR==2 {print $2}')
  log "📁 檔案系統類型：$FS_TYPE"
  
  if [[ "$FS_TYPE" =~ ext[234] ]]; then
    log "🔧 擴展 ext 檔案系統..."
    if ! resize2fs -f "$ROOT_LV"; then
      log "❌ resize2fs 失敗"
      return 1
    fi
  elif [[ "$FS_TYPE" == "xfs" ]]; then
    log "🔧 擴展 XFS 檔案系統..."
    if ! xfs_growfs "$ROOT_LV"; then
      log "❌ xfs_growfs 失敗"
      return 1
    fi
  else
    log "❌ 不支援的檔案系統：$FS_TYPE"
    return 1
  fi
  
  # 驗證擴容結果
  log "📊 擴容後磁碟使用狀況："
  df -h / | tee -a "$LOG_FILE"
  
  log "✅ 根磁碟擴容完成！"
  return 0
}

create_systemd_service() {
  log "🔧 創建開機自動檢查磁碟擴容需求的 systemd 服務..."
  
  local service_file="/etc/systemd/system/auto-extend-root-disk.service"
  local script_path="$(readlink -f "$0")"
  
  cat > "$service_file" << EOF
[Unit]
Description=Automatically extend root disk if needed
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$script_path
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF
  
  log "📦 啟用 systemd 服務..."
  systemctl daemon-reload
  systemctl enable auto-extend-root-disk.service
  
  log "✅ 系統將在每次啟動時自動檢查並擴展磁碟"
}

### 主程式執行 ###
log "🚀 開始執行自動根磁碟擴容腳本"
require_root
detect_os
ensure_tools
scsi_rescan_all
get_lvm_info
get_partition_number

if check_expand_needed; then
  log "🚀 開始擴展磁碟..."
  do_extend
  exit_code=$?
  
  if [ $exit_code -eq 0 ]; then
    log "🎉 擴容成功完成"
    
    # 創建 systemd 服務
    if [ ! -f "/etc/systemd/system/auto-extend-root-disk.service" ]; then
      log "📌 創建 systemd 服務，以便系統每次啟動時自動檢查擴容需求"
      create_systemd_service
    fi
  else
    log "❌ 擴容過程中出現錯誤，退出碼 $exit_code"
    exit $exit_code
  fi
else
  log "🛑 結束：未偵測到擴容需求"
fi

exit 0